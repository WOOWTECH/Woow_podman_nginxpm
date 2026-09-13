#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
# shellcheck source=../testlib.sh
source "$ROOT/tests/testlib.sh"
# shellcheck source=../../scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
valid="$TMP/valid"; cp "$ROOT/tests/fixtures/env.valid" "$valid"; chmod 600 "$valid"
assert_success 'valid strict configuration accepted' load_config "$valid"
for bad in \
  'TZ=Asia/Taipei' \
  'NPM_IMAGE=jc21/nginx-proxy-manager:latest|TZ=Asia/Taipei|NPM_ADMIN_EMAIL=a@b.com' \
  'NPM_IMAGE=docker.io/jc21/nginx-proxy-manager:2.15.1|TZ=Asia/Taipei|NPM_ADMIN_EMAIL=a@b.com' \
  'NPM_IMAGE=$(id)|TZ=Asia/Taipei|NPM_ADMIN_EMAIL=a@b.com' \
  'NPM_IMAGE =bad|TZ=Asia/Taipei|NPM_ADMIN_EMAIL=a@b.com' \
  'TZ=Asia/Taipei|TZ=UTC|NPM_IMAGE=x|NPM_ADMIN_EMAIL=a@b.com' \
  'NPM_HTTP_PORT=80|TZ=Asia/Taipei|NPM_IMAGE=x|NPM_ADMIN_EMAIL=a@b.com' \
  'NPM_ADMIN_PORT=81|TZ=Asia/Taipei|NPM_IMAGE=x|NPM_ADMIN_EMAIL=a@b.com'; do
  f="$TMP/bad"; printf '%s\n' "$bad" | tr '|' '\n' >"$f"; chmod 600 "$f"
  assert_failure "reject malformed config: $bad" load_config "$f"
done
f="$TMP/mode"; cp "$valid" "$f"; chmod 644 "$f"
assert_failure 'configuration must be private' load_config "$f"
D="$TMP/private"; assert_success 'create private directory' ensure_private_dir "$D"
[[ $(stat -c %a "$D") == 700 ]] && ok 'private directory is mode 700' || not_ok 'private directory is mode 700'
printf test | atomic_private_write "$D/file"
[[ $(stat -c %a "$D/file") == 600 ]] && ok 'atomic file is mode 600' || not_ok 'atomic file is mode 600'
mkdir "$TMP/bin"; cat >"$TMP/bin/podman" <<'SH'
#!/bin/sh
case $1 in
  info) echo true;;
  version) echo 4.9.3;;
esac
SH
cat >"$TMP/bin/podman-compose" <<'SH'
#!/bin/sh
printf '%s\n' "${COMPOSE_VERSION_OUTPUT:?}"
SH
chmod +x "$TMP/bin/podman" "$TMP/bin/podman-compose"; echo 80 >"$TMP/low"
TEST_MODE=1 PODMAN_BIN="$TMP/bin/podman" PODMAN_COMPOSE_BIN="$TMP/bin/podman-compose" PROC_LOW_PORT_PATH="$TMP/low"
export TEST_MODE PODMAN_BIN PODMAN_COMPOSE_BIN PROC_LOW_PORT_PATH
assert_success 'fixture rootless check accepted' check_rootless
assert_success 'fixture low-port check accepted' check_low_ports
echo 81 >"$TMP/low"; assert_failure 'high unprivileged-port threshold rejected' check_low_ports
COMPOSE_VERSION_OUTPUT='podman version 4.9.3
podman-compose version 1.0.6'; export COMPOSE_VERSION_OUTPUT
assert_success 'exact noisy podman-compose 1.0.6 output is accepted' check_versions
COMPOSE_VERSION_OUTPUT='podman version 4.9.3
podman-compose version 1.0.7'
assert_failure 'wrong explicit podman-compose version is rejected' check_versions
COMPOSE_VERSION_OUTPUT='podman-compose version 1.0.6
podman-compose version 1.0.6'
assert_failure 'ambiguous podman-compose version lines are rejected' check_versions
finish
