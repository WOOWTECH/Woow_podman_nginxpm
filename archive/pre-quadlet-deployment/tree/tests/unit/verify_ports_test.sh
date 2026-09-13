#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
# shellcheck source=../testlib.sh
source "$ROOT/tests/testlib.sh"
# shellcheck source=../../scripts/verify.sh
source "$ROOT/scripts/verify.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir "$BIN"
cat >"$BIN/ss" <<'SH'
#!/usr/bin/env bash
cat "${LISTENER_FIXTURE:?}"
SH
chmod +x "$BIN/ss"
PATH="$BIN:$PATH"
PORT_BINDINGS_FIXTURE=
_resource_inspect() {
  case ${3:-} in
    '{{json .HostConfig.PortBindings}}') cat "$PORT_BINDINGS_FIXTURE";;
    '{{range .Mounts}}{{println .Name "|" .Destination}}{{end}}')
      printf 'npm-app-data | /data\nnpm-letsencrypt | /etc/letsencrypt\n';;
    *) return 2;;
  esac
}
python_cmd() { printf 'python3\n'; }
run_ports() {
  PORT_BINDINGS_FIXTURE=$1 verify_ports_and_mounts >"$TMP/out" 2>"$TMP/err"
}
run_listeners() {
  LISTENER_FIXTURE=$1 verify_listeners >"$TMP/out" 2>"$TMP/err"
}
fixtures="$ROOT/tests/fixtures/verify"

assert_success 'Podman 4.9 empty public HostIp bindings are accepted as IPv4 wildcards' run_ports "$fixtures/podman-4.9-port-bindings.json"
assert_success 'explicit IPv4 wildcard inspect bindings remain accepted' run_ports "$fixtures/standard-port-bindings.json"
assert_failure 'IPv6-only public inspect binding is rejected' run_ports "$fixtures/unsafe-ipv6-port-bindings.json"
error=$(cat "$TMP/err"); assert_contains 'IPv6 inspect rejection identifies the exact public binding requirement' "$error" '80/tcp must use IPv4 wildcard HostIp'
assert_failure 'an additional public inspect binding is rejected' run_ports "$fixtures/unsafe-extra-port-bindings.json"
error=$(cat "$TMP/err"); assert_contains 'additional inspect binding error identifies the exact allowed container ports' "$error" 'expected only container ports 80/tcp, 443/tcp, and 81/tcp'
assert_failure 'non-loopback administration inspect binding is rejected' run_ports "$fixtures/unsafe-admin-port-bindings.json"
error=$(cat "$TMP/err"); assert_contains 'administration inspect rejection identifies the exact safe endpoint' "$error" '81/tcp must bind only to 127.0.0.1:18081'

assert_success 'observed ss star wildcards satisfy both public listeners' run_listeners "$fixtures/podman-4.9-listeners.ss"
assert_failure 'IPv6-only public listeners are rejected' run_listeners "$fixtures/unsafe-ipv6-only-listeners.ss"
error=$(cat "$TMP/err"); assert_contains 'IPv6-only listener error identifies the unsafe endpoint' "$error" 'unsafe public listener at [::]:443'
assert_failure 'an additional IPv6 public listener is rejected' run_listeners "$fixtures/unsafe-extra-public-listeners.ss"
error=$(cat "$TMP/err"); assert_contains 'additional public listener error identifies the unsafe endpoint' "$error" 'unsafe public listener at [::]:443'
assert_failure 'missing public listener is rejected' run_listeners "$fixtures/missing-public-listener.ss"
error=$(cat "$TMP/err"); assert_contains 'missing public listener error identifies port 443' "$error" 'public IPv4 wildcard listener missing on TCP port 443'
assert_failure 'any additional administration listener is rejected' run_listeners "$fixtures/unsafe-admin-listeners.ss"
error=$(cat "$TMP/err"); assert_contains 'unsafe administration error reports the outside endpoint' "$error" 'unsafe administration listener at *:18081'
assert_failure 'missing exact loopback administration listener is rejected' run_listeners "$fixtures/missing-admin-listener.ss"
error=$(cat "$TMP/err"); assert_contains 'missing administration error identifies the exact required endpoint' "$error" 'administration listener missing at exact endpoint 127.0.0.1:18081'
finish
