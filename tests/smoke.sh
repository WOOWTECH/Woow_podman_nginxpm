#!/usr/bin/env bash
# tests/smoke.sh: post-install checks for Nginx Proxy Manager on this host. Read-only apart
# from one `podman healthcheck run`. scripts/install.sh, upgrade.sh and migrate-legacy.sh
# run it after every (re)start.
#
#   tests/smoke.sh [--pi-host HOST] [--pi-port PORT]
#
#   --pi-host HOST  with the pi-web front: send 20 requests with this Host header through
#                   the HTTP listener and fail on any 502 (default: no sweep)
#   --pi-port PORT  port for that sweep (default NPM_HTTP_PORT)
#
# With ~/.config/npm/smoke-pi.netrc (0600, operator-created: machine HOST login U password P)
# and --pi-host, it also asserts that an authenticated /api/models answers 200, not 403
# (403 means the Host/Origin rewrite did not apply). Credentials are never printed.
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"

pi_host='' pi_port=''
while (($#)); do
  case $1 in
    --pi-host) pi_host=${2:?}; shift ;;
    --pi-port) pi_port=${2:?}; shift ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift
done
http=$(npm_env_value NPM_HTTP_PORT 80)
https=$(npm_env_value NPM_HTTPS_PORT 443)
admin=$(npm_env_value NPM_ADMIN_PORT 81)
read -ra extra <<<"$(npm_env_value NPM_EXTRA_HTTP_PORTS)"
front=$(npm_env_value NPM_PI_WEB_FRONT false)
INSTALLED=$HOME/.config/containers/systemd/npm-app.container
fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

# 1. unit
if [[ $(systemctl --user is-active "$NPM_UNIT" 2>/dev/null) == active ]]; then pass "$NPM_UNIT is active"; else fail "$NPM_UNIT is not active"; fi
frag=$(systemctl --user show -p FragmentPath --value "$NPM_UNIT" 2>/dev/null)
if [[ $frag == */systemd/generator/* ]]; then pass "$NPM_UNIT comes from the Quadlet generator"; else fail "$NPM_UNIT is loaded from '$frag' (shadowed?)"; fi

# 2. health and admin API
if podman healthcheck run "$NPM_CONTAINER" >/dev/null 2>&1; then pass "npm-app healthcheck passes"; else fail "npm-app healthcheck fails"; fi
api=$(curl -s -m 10 "http://127.0.0.1:$admin/api/" 2>/dev/null || true)
if [[ $api == *'"status":"OK"'* ]]; then pass "admin API on 127.0.0.1:$admin says OK"; else fail "admin API on 127.0.0.1:$admin: '${api:0:80}'"; fi

# 3. listeners: HTTP/HTTPS/extra on every interface, the admin UI on loopback only
listeners=$(ss -tlnH 2>/dev/null | awk '{print $4}' | sort -u)
for p in "$http" "$https" "${extra[@]}"; do
  if grep -qE "^(\*|0\.0\.0\.0|\[::\]):$p\$" <<<"$listeners"; then pass "port $p listens on all interfaces"; else fail "port $p is not listening on all interfaces"; fi
done
if grep -qxF "127.0.0.1:$admin" <<<"$listeners"; then pass "admin port $admin listens on 127.0.0.1"; else fail "admin port $admin is not listening on 127.0.0.1"; fi
if grep -qE "^(\*|0\.0\.0\.0|\[::\]):$admin\$" <<<"$listeners"; then fail "admin port $admin is exposed on all interfaces"; else pass "admin port $admin is not exposed beyond loopback"; fi

# 4. image = pinned tag and digest
pinned=$(npm_image_of "$INSTALLED" 2>/dev/null)
digest=$(sed -n 's/^#[[:space:]]*\(sha256:[0-9a-f]\{64\}\)[[:space:]]*$/\1/p' "$INSTALLED" 2>/dev/null | head -n1)
want=$(podman image inspect --format '{{.Id}}' "$pinned" 2>/dev/null || true)
have=$(podman container inspect --format '{{.Image}}' "$NPM_CONTAINER" 2>/dev/null || true)
if [[ -n $want && $want == "$have" ]]; then pass "running image is $pinned"; else fail "running image ${have:0:12} is not $pinned (${want:0:12})"; fi
if [[ -n $digest ]]; then
  if podman image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$pinned" 2>/dev/null | grep -qF "@$digest"; then
    pass "$pinned has the pinned digest ${digest:0:19}…"
  else
    fail "$pinned does not carry the pinned digest $digest"
  fi
fi

# 5. pi-web front
if [[ $front == true ]]; then
  nets=$(podman container inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$NPM_CONTAINER" 2>/dev/null || true)
  if [[ " $nets " == *" pi-agent "* ]]; then pass "npm-app is on the pi-agent network"; else fail "npm-app is not on the pi-agent network (networks: ${nets:-?})"; fi
  n=$(podman exec "$NPM_CONTAINER" nginx -T 2>/dev/null | grep -c 'woow_upstream_host' || true)
  if ((n >= 2)); then pass "nginx loaded the pi-web Host/Origin rewrite"; else fail "nginx -T shows no woow_upstream_host map"; fi
  if [[ -n $pi_host ]]; then
    port=${pi_port:-$http}
    codes=$(for _ in $(seq 20); do curl -s -o /dev/null -m 10 -w '%{http_code}\n' -H "Host: $pi_host" "http://127.0.0.1:$port/" 2>/dev/null || echo 000; done | sort | uniq -c | xargs)
    if [[ $codes == *502* || $codes == *000* ]]; then fail "pi route sweep via :$port: $codes"; else pass "pi route sweep via :$port: $codes"; fi
    netrc=$HOME/.config/npm/smoke-pi.netrc
    if [[ -r $netrc ]]; then
      code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --netrc-file "$netrc" --resolve "$pi_host:$port:127.0.0.1" "http://$pi_host:$port/api/models" 2>/dev/null || echo 000)
      if [[ $code == 200 ]]; then pass "authenticated /api/models -> 200"; else fail "authenticated /api/models -> $code (403 = rewrite not applied)"; fi
    fi
  fi
fi

if ((fails)); then
  echo "smoke: $fails check(s) failed"
  exit 1
fi
echo "smoke: PASS"
