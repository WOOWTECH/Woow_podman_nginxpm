#!/usr/bin/env bash
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
tier=${1:-unit}
run_dir() {
  local f failures=0 found=0
  for f in "$ROOT"/tests/unit/*_test.sh; do
    [[ -f $f ]] || continue; found=1
    printf '\n==> %s\n' "${f#$ROOT/}"
    bash "$f" || failures=$((failures+1))
  done
  ((found==1)) || { echo 'No unit tests found' >&2; return 1; }
  ((failures==0))
}
case $tier in
  unit) run_dir;;
  gates)
    bash "$ROOT/tests/live/local_test.sh"
    bash "$ROOT/tests/live/remote_test.sh";;
  live) bash "$ROOT/tests/live/local_test.sh";;
  remote) bash "$ROOT/tests/live/remote_test.sh";;
  *) echo "Usage: $0 {unit|gates|live|remote}" >&2; exit 2;;
esac
