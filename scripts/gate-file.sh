#!/usr/bin/env bash
# Run both gate reviewers on a single file; exit 1 if either fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GATE_FASTEST="${GATE_FASTEST:-$HOME/.cursor/cursor_gate_fastest.py}"
GATE_FULL="${GATE_FULL:-$HOME/.cursor/cursor_gate.py}"
[[ -f "$GATE_FASTEST" ]] || GATE_FASTEST="$ROOT/cursor_gate_fastest.py"
[[ -f "$GATE_FULL" ]] || GATE_FULL="$ROOT/cursor_gate.py"

REGION="${GATE_REGION:-us-west-2}"
ITERATIONS="${GATE_ITERATIONS:-3}"

usage() {
  cat <<EOF
Usage: gate-file.sh --file PATH

Runs cursor_gate_fastest.py and cursor_gate.py with --region $REGION.
Exits 1 if either reviewer returns status FAIL.
EOF
}

FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      FILE="${2:-}"
      shift 2
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

if [[ -z "$FILE" ]]; then
  echo "Error: --file is required" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$FILE" ]]; then
  echo "Error: file not found: $FILE" >&2
  exit 2
fi

read_gate_result() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
status = data.get("status", "FAIL")
gates = data.get("gates", {})
failed = [name for name, passed in gates.items() if not passed]
print(status)
print(", ".join(failed) if failed else "none")
PY
}

run_reviewer() {
  local label="$1"
  local script="$2"
  shift 2
  local out rc=0 status failed

  out="$(mktemp)"
  trap 'rm -f "$out"' RETURN

  echo "==> $label: $script --file $FILE --region $REGION $*"
  set +e
  python3 "$script" --file "$FILE" --region "$REGION" --no-cache --output "$out" "$@" >/dev/null 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 && ! -s "$out" ]]; then
    echo "  ERROR: reviewer exited $rc with no JSON output" >&2
    return 1
  fi

  mapfile -t result < <(read_gate_result "$out")
  status="${result[0]:-FAIL}"
  failed="${result[1]:-unknown}"

  echo "  status: $status"
  if [[ "$status" != "PASS" ]]; then
    echo "  failed gates: $failed"
    return 1
  fi
  return 0
}

FASTEST_OK=1
FULL_OK=1

if run_reviewer "cursor_gate_fastest" "$GATE_FASTEST"; then
  FASTEST_OK=0
fi

if run_reviewer "cursor_gate" "$GATE_FULL" --iterations "$ITERATIONS"; then
  FULL_OK=0
fi

echo
echo "Gate summary for $FILE"
echo "  cursor_gate_fastest: $([[ $FASTEST_OK -eq 0 ]] && echo PASS || echo FAIL)"
echo "  cursor_gate:         $([[ $FULL_OK -eq 0 ]] && echo PASS || echo FAIL)"

if [[ $FASTEST_OK -ne 0 || $FULL_OK -ne 0 ]]; then
  exit 1
fi

exit 0
