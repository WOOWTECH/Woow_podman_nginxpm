#!/usr/bin/env bash
set -u
TESTS=0 FAILURES=0
ok() { TESTS=$((TESTS+1)); printf 'ok %d - %s\n' "$TESTS" "$1"; }
not_ok() { TESTS=$((TESTS+1)); FAILURES=$((FAILURES+1)); printf 'not ok %d - %s\n' "$TESTS" "$1"; }
assert_success() { local n=$1; shift; if "$@"; then ok "$n"; else not_ok "$n"; fi; }
assert_failure() { local n=$1; shift; if "$@"; then not_ok "$n"; else ok "$n"; fi; }
assert_contains() { local n=$1 hay=$2 needle=$3; [[ $hay == *"$needle"* ]] && ok "$n" || not_ok "$n"; }
finish() { printf '1..%d\n' "$TESTS"; ((FAILURES==0)); }
