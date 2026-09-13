#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
TMP=$(mktemp -d); server=''; helper=''; trap '[[ -z $helper ]] || kill "$helper" 2>/dev/null; [[ -z $server ]] || kill "$server" 2>/dev/null; rm -rf "$TMP"' EXIT
old_email='old-canary@example.test'; old_password='OldCanary-7RzPW!'; new_email='new-canary@example.test'; new_password='NewCanary-9QxVt!'
for pair in "email:$old_email" "old:$old_password" "newemail:$new_email" "new:$new_password"; do name=${pair%%:*}; value=${pair#*:}; printf '%s\n' "$value" >"$TMP/$name"; chmod 600 "$TMP/$name"; done
: >"$TMP/server.log"; FAKE_EMAIL="$old_email" FAKE_PASSWORD="$old_password" FAKE_LOG="$TMP/server.log" FAKE_DELAY_FILE="$TMP/delay" python3 "$ROOT/tests/fixtures/npm_api_server.py" >"$TMP/server.out" 2>"$TMP/server.err" & server=$!
for _ in $(seq 1 30); do python3 "$ROOT/scripts/lib/npm_api.py" ready --url http://127.0.0.1:18081 >/dev/null 2>&1 && break; sleep .1; done
out=$(python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/email" --password-file "$TMP/old" 2>"$TMP/err"); rc=$?
[[ $rc -eq 0 && $out == OK && ! -s $TMP/err ]] && ok 'authentication succeeds with machine-safe output' || not_ok 'authentication succeeds with machine-safe output'
: >"$TMP/delay"
python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/email" --password-file "$TMP/old" >"$TMP/helper.out" 2>"$TMP/helper.err" & helper=$!
cmdline=''
for _ in $(seq 1 30); do
  [[ -r /proc/$helper/cmdline ]] || break
  cmdline=$(tr '\0' ' ' <"/proc/$helper/cmdline")
  grep -q 'POST /api/tokens' "$TMP/server.log" && break
  sleep .05
done
argv_safe=1
for canary in "$old_email" "$old_password" "$new_email" "$new_password" fixture-token; do [[ $cmdline != *"$canary"* ]] || argv_safe=0; done
[[ -n $cmdline && $argv_safe -eq 1 && -e /proc/$helper/cmdline ]] && ok 'actual long-running helper process command line contains no credential or token canary' || not_ok 'actual long-running helper process command line contains no credential or token canary'
wait "$helper"; rc=$?; helper=''; rm -f "$TMP/delay"
[[ $rc -eq 0 ]] && ok 'controlled helper completes after command-line inspection' || not_ok 'controlled helper completes after command-line inspection'
printf wrong >"$TMP/old"; chmod 600 "$TMP/old"
if python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/email" --password-file "$TMP/old" >"$TMP/out" 2>"$TMP/err"; then not_ok 'rejected credentials fail'; else ok 'rejected credentials fail'; fi
leak=$(cat "$TMP/out" "$TMP/err"); [[ $leak != *wrong* && $leak != *"$old_email"* ]] && ok 'errors do not reflect secrets' || not_ok 'errors do not reflect secrets'
printf '%s\n' "$old_password" >"$TMP/old"; chmod 600 "$TMP/old"
assert_success 'password and identity rotation succeeds' python3 "$ROOT/scripts/lib/npm_api.py" change-password --url http://127.0.0.1:18081 --identity-file "$TMP/email" --current-file "$TMP/old" --new-file "$TMP/new" --new-identity-file "$TMP/newemail"
assert_success 'new credentials authenticate' python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/newemail" --password-file "$TMP/new"
printf '%s\n' 'finished-canary@example.test' >"$TMP/finished-email"; chmod 600 "$TMP/finished-email"
assert_success 'interrupted identity-only transition can finish safely' python3 "$ROOT/scripts/lib/npm_api.py" change-password --url http://127.0.0.1:18081 --identity-file "$TMP/newemail" --current-file "$TMP/new" --new-file "$TMP/new" --new-identity-file "$TMP/finished-email"
assert_success 'finished transitional identity authenticates' python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/finished-email" --password-file "$TMP/new"
chmod 644 "$TMP/new"; assert_failure 'non-private secret file rejected' python3 "$ROOT/scripts/lib/npm_api.py" auth --url http://127.0.0.1:18081 --identity-file "$TMP/finished-email" --password-file "$TMP/new"
allout=$(cat "$TMP/server.out" "$TMP/server.err" "$TMP/out" "$TMP/err"); [[ $allout != *"$old_password"* && $allout != *"$new_password"* ]] && ok 'local output contains no password canary' || not_ok 'local output contains no password canary'
grep -q "$new_password" "$TMP/server.log" && ok 'secret reached only server request fixture' || not_ok 'secret reached only server request fixture'
[[ ! -e "$TMP/token" ]] && ok 'no token file persisted' || not_ok 'no token file persisted'
finish
