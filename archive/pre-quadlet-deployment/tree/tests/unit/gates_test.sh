#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
out=$(RUN_LIVE_TESTS=0 bash "$ROOT/tests/live/local_test.sh" 2>&1); rc=$?; [[ $rc -eq 0 && $out == SKIP:* ]] && ok 'local live tier explicitly skips by default' || not_ok 'local live tier explicitly skips by default'
out=$(RUN_LIVE_TESTS=1 RUN_REMOTE_LIVE_TESTS=0 bash "$ROOT/tests/live/remote_test.sh" 2>&1); rc=$?; [[ $rc -eq 0 && $out == SKIP:* ]] && ok 'remote tier requires both opt-ins' || not_ok 'remote tier requires both opt-ins'
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/timeout" <<'SH'
#!/usr/bin/env bash
shift; exec "$@"
SH
cat >"$TMP/cat" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == /etc/machine-id ]]; then printf 'cccccccccccccccccccccccccccccccc\n'; else exec /bin/cat "$@"; fi
SH
cat >"$TMP/tailscale" <<'SH'
#!/usr/bin/env bash
[[ $* == 'serve status --json' ]] || exit 2
printf '%s\n' '{"TCP":{"18081":{"TCPForward":"tcp://127.0.0.1:18081"}}}'
SH
cat >"$TMP/ssh" <<'SH'
#!/usr/bin/env bash
while [[ ${1:-} == -o ]]; do shift 2; done
dest=${1:-}; shift || true
[[ ${SSH_FAIL:-0} != 1 ]] || exit 255
case $1 in
  cat|'cat /etc/machine-id')
    if [[ $dest == tail-client ]]; then printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    elif [[ ${SAME_CLIENT:-0} == 1 ]]; then printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
    else printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'; fi;;
  getent)
    host=${3:-}
    if [[ ${DNS_FAIL:-0} == 1 ]]; then exit 2; fi
    if [[ $host == tail.gateway ]]; then printf '100.64.0.1 STREAM tail.gateway\n'
    elif [[ ${SAME_TARGET:-0} == 1 ]]; then printf '100.64.0.1 STREAM lan.host\n'
    else printf '192.168.1.10 STREAM lan.host\n'; fi;;
  curl)
    args=" $* "
    if [[ $args == *':18081/api/'* && $dest == lan-client ]]; then exit "${ADMIN_RC:-7}"; fi
    exit 0;;
  *) exit 3;;
esac
SH
chmod +x "$TMP/timeout" "$TMP/tailscale" "$TMP/ssh" "$TMP/cat"
run_gate() { PATH="$TMP:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$ROOT/scripts/verify-remote.sh" >/dev/null 2>"$TMP/gate.err"; }
assert_success 'remote gate accepts distinct stable clients and unambiguous refusal' run_gate
assert_failure 'remote gate rejects SSH aliases for the same stable client' env SAME_CLIENT=1 bash -c 'PATH="$1:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$2/scripts/verify-remote.sh" >/dev/null 2>&1' _ "$TMP" "$ROOT"
assert_failure 'remote gate rejects target aliases resolving to the same address' env SAME_TARGET=1 bash -c 'PATH="$1:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$2/scripts/verify-remote.sh" >/dev/null 2>&1' _ "$TMP" "$ROOT"
assert_failure 'remote gate treats LAN probe timeout as ambiguous failure' env ADMIN_RC=28 bash -c 'PATH="$1:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$2/scripts/verify-remote.sh" >/dev/null 2>&1' _ "$TMP" "$ROOT"
assert_failure 'remote gate propagates DNS failure' env DNS_FAIL=1 bash -c 'PATH="$1:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$2/scripts/verify-remote.sh" >/dev/null 2>&1' _ "$TMP" "$ROOT"
assert_failure 'remote gate propagates SSH failure' env SSH_FAIL=1 bash -c 'PATH="$1:$PATH" TAILNET_TEST_SSH=tail-client LAN_TEST_SSH=lan-client TAILSCALE_GATEWAY_HOST=tail.gateway LAN_TARGET_HOST=lan.host "$2/scripts/verify-remote.sh" >/dev/null 2>&1' _ "$TMP" "$ROOT"
! grep -Eq 'RUN_LIVE_TESTS|podman (pull|run|stop|rm)|ssh ' "$ROOT/tests/run.sh" && ok 'unit dispatcher contains no mutation or remote access' || not_ok 'unit dispatcher contains no mutation or remote access'
finish
