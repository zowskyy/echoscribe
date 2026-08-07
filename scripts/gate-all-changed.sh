#!/usr/bin/env bash
# Gate all changed .py/.ts/.js files (git diff HEAD) or explicit file args.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE_FILE="$ROOT/scripts/gate-file.sh"

usage() {
  cat <<EOF
Usage: gate-all-changed.sh [FILE ...]

With no arguments, gates changed .py/.ts/.js files from: git diff --name-only HEAD
With arguments, gates each listed file that exists.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mapfile -t FILES < <(
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
  else
    git -C "$ROOT" diff --name-only HEAD | grep -E '\.(py|ts|js)$' || true
  fi
)

if [[ ${#FILES[@]} -eq 0 || -z "${FILES[0]:-}" ]]; then
  echo "No files to gate."
  exit 0
fi

failures=0
gated=0

for rel in "${FILES[@]}"; do
  if [[ "$rel" == /* ]]; then
    path="$rel"
  else
    path="$ROOT/$rel"
  fi

  if [[ ! -f "$path" ]]; then
    echo "Skipping missing file: $rel"
    continue
  fi

  gated=$((gated + 1))
  echo
  echo "Gating ($gated): $rel"
  if ! bash "$GATE_FILE" --file "$path"; then
    failures=$((failures + 1))
  fi
done

echo
echo "Changed-files gate summary: $gated file(s), $failures failure(s)"
[[ $failures -eq 0 ]]
