#!/usr/bin/env bash
# Release audit — run AFTER gate-file.sh / gate-all-changed.sh PASS, before RELEASE_READY.
# Exits 1 if any release blockers are found.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BLOCKERS=0
WARNINGS=0

section() {
  echo
  echo "=== $1 ==="
}

blocker() {
  echo "BLOCKER: $*"
  BLOCKERS=$((BLOCKERS + 1))
}

warn() {
  echo "WARN: $*"
  WARNINGS=$((WARNINGS + 1))
}

usage() {
  cat <<EOF
Usage: release-audit.sh [--root PATH]

Audits the repository for release blockers:
  - README / package.json feature claims vs code reality
  - ROADMAP open P0/P1 items (non-deferred)
  - TODO/FIXME in src (excludes samples/)
  - "coming soon" / "scaffold" / "placeholder" in user-facing docs
  - empty or stub-only source modules

Run AFTER all gate reviewers PASS on shippable files.
Exits 1 if any blockers are found.

See .cursor/rules/architect-protocol.mdc — Workers implement all gaps; do not trim docs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      shift 2
      cd "$ROOT"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --- User-facing docs (exclude samples, node_modules, .git) ---
USER_DOCS=()
for candidate in README.md docs/*.md extension/README.md; do
  [[ -f "$candidate" ]] || continue
  case "$candidate" in
    docs/USER_RULES_PASTE.md|docs/REPO_MANAGERS.md|docs/ARCHITECT_PROTOCOL.md) continue ;;
  esac
  USER_DOCS+=("$candidate")
done

# --- ROADMAP P0/P1 open items ---
section "ROADMAP P0/P1"
ROADMAP_FILES=(ROADMAP.md docs/ROADMAP.md)
ROADMAP_FOUND=0
for rf in "${ROADMAP_FILES[@]}"; do
  [[ -f "$rf" ]] || continue
  ROADMAP_FOUND=1
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Skip explicitly deferred lines (Architect must defer in writing)
    if echo "$line" | grep -qiE 'defer(red)?|won.?t fix|post-release|out of scope'; then
      continue
    fi
    # Open P0/P1: checkbox unchecked or status open/in_progress/todo
    if echo "$line" | grep -qiE '\[ \].*P[01]|P[01].*\[ \]|P[01].*\b(open|in[_ ]progress|todo|pending|blocked)\b'; then
      blocker "$rf: $line"
    fi
    # ROADMAP says TODO for a shipped feature
    if echo "$line" | grep -qiE 'P[01].*TODO|TODO.*P[01]'; then
      blocker "$rf: shipped-feature TODO — $line"
    fi
  done < "$rf"
done
if [[ $ROADMAP_FOUND -eq 0 ]]; then
  echo "No ROADMAP.md found (OK if nothing tracked)."
fi

# --- TODO/FIXME in src (not samples) ---
section "TODO/FIXME in source"
SRC_DIRS=(src extension/src)
SRC_FOUND=0
for dir in "${SRC_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  SRC_FOUND=1
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    blocker "$hit"
  done < <(grep -rnE 'TODO|FIXME' "$dir" \
    --include='*.py' --include='*.ts' --include='*.js' --include='*.tsx' --include='*.jsx' \
    2>/dev/null || true)
done
if [[ $SRC_FOUND -eq 0 ]]; then
  echo "No src/ directories to scan (OK)."
fi

# --- User-facing doc red flags ---
section "User-facing doc red flags (coming soon / scaffold / placeholder)"
DOC_PATTERN='coming soon|scaffold|placeholder'
for doc in "${USER_DOCS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    # Allow protocol docs that discuss the rule itself
    if echo "$hit" | grep -qiE 'scaffold.*don.t count|placeholder.*don.t count'; then
      continue
    fi
    blocker "$hit"
  done < <(grep -niE "$DOC_PATTERN" "$doc" 2>/dev/null || true)
done
if [[ ${#USER_DOCS[@]} -eq 0 ]]; then
  echo "No user-facing docs found."
fi

# --- Empty or stub-only modules ---
section "Empty / stub-only modules"
check_empty_module() {
  local f="$1"
  local lines nonblank
  lines=$(wc -l < "$f" | tr -d ' ')
  nonblank=$(grep -cve '^\s*$' "$f" || true)
  if [[ "$lines" -le 1 && "$nonblank" -le 1 ]]; then
    blocker "empty module: $f ($lines lines)"
    return
  fi
  # Stub: only comments, pass, or raise NotImplementedError
  if python3 - "$f" <<'PY' 2>/dev/null; then
import ast, sys
from pathlib import Path

p = Path(sys.argv[1])
src = p.read_text(encoding="utf-8", errors="replace")
try:
    tree = ast.parse(src)
except SyntaxError:
    sys.exit(1)

body = getattr(tree, "body", [])
if not body:
    sys.exit(0)

if len(body) == 1:
    n = body[0]
    if isinstance(n, ast.Expr) and isinstance(getattr(n, "value", None), ast.Constant):
        sys.exit(0)  # docstring-only
    if isinstance(n, ast.FunctionDef) and len(n.body) == 1:
        s = n.body[0]
        if isinstance(s, ast.Pass):
            sys.exit(0)
        if isinstance(s, ast.Raise) and isinstance(getattr(s, "exc", None), ast.Call):
            fn = getattr(s.exc, "func", None)
            if isinstance(fn, ast.Name) and fn.id == "NotImplementedError":
                sys.exit(0)
        if isinstance(s, ast.Expr) and isinstance(getattr(s, "value", None), ast.Constant):
            sys.exit(0)

sys.exit(1)
PY
    blocker "stub-only module: $f"
  fi
}

for dir in src extension/src; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' f; do
    check_empty_module "$f"
  done < <(find "$dir" -type f \( -name '*.py' -o -name '*.ts' -o -name '*.js' \) ! -path '*/node_modules/*' -print0 2>/dev/null || true)
done

# --- README feature bullets vs code ---
section "README feature bullets"
README="${ROOT}/README.md"
if [[ -f "$README" ]]; then
  while IFS= read -r bullet; do
    [[ -z "$bullet" ]] && continue
    # Skip install/run/doc/meta bullets
    if echo "$bullet" | grep -qiE 'install|quick start|usage|see \[|project layout|configuration|logs|cache|rebuild|CI gate|agent completion|quarterback|paste|bootstrap|option [A-D]:'; then
      continue
    fi
    # Flag bullets that claim incomplete work
    if echo "$bullet" | grep -qiE 'coming soon|scaffold|placeholder|not implemented|WIP|work in progress|TODO'; then
      blocker "README claims incomplete feature: $bullet"
      continue
    fi
    # Check package.json command registration for extension commands mentioned in README
    if echo "$bullet" | grep -qiE 'review workspace|review with docker'; then
      cmd=""
      if echo "$bullet" | grep -qi 'workspace'; then cmd="cursorGate.reviewWorkspace"; fi
      if echo "$bullet" | grep -qi 'docker'; then cmd="cursorGate.reviewWithDocker"; fi
      if [[ -n "$cmd" ]] && [[ -f extension/package.json ]]; then
        if ! grep -q "\"command\": \"$cmd\"" extension/package.json; then
          blocker "README feature not registered in package.json: $cmd ($bullet)"
        fi
      fi
    fi
  done < <(grep -E '^[[:space:]]*[-*][[:space:]]' "$README" | sed 's/^[[:space:]]*[-*][[:space:]]*//' || true)
else
  warn "No README.md at repo root."
fi

# --- package.json contributes.commands vs implementation ---
section "package.json features vs code"
PKG="${ROOT}/extension/package.json"
EXT_SRC="${ROOT}/extension/src/extension.ts"
if [[ -f "$PKG" && -f "$EXT_SRC" ]]; then
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    # Each contributed command should be registered in extension.ts
    if ! grep -q "$cmd" "$EXT_SRC"; then
      blocker "package.json command not found in extension.ts: $cmd"
    fi
  done < <(python3 - "$PKG" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for c in data.get("contributes", {}).get("commands", []):
    cmd = c.get("command", "")
    if cmd:
        print(cmd)
PY
)
else
  echo "No extension/package.json + extension.ts pair to cross-check."
fi

# --- Summary ---
section "Release audit summary"
echo "Blockers: $BLOCKERS"
echo "Warnings: $WARNINGS"

if [[ $BLOCKERS -gt 0 ]]; then
  echo
  echo "RELEASE_READY: NO — Workers must IMPLEMENT remaining gaps (do not trim docs)."
  echo "Keep going until every listed feature works unless Architect explicitly defers."
  exit 1
fi

echo
echo "RELEASE_READY: entire product audit PASS (gates must also PASS separately)"
exit 0
