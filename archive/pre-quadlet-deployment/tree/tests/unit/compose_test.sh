#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
file="$ROOT/docker-compose.yml"
pin='docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb'
text=$(cat "$file")
for required in '${NPM_IMAGE}' '0.0.0.0:80:80' '0.0.0.0:443:443' '127.0.0.1:18081:81' 'container_name: npm-app' 'name: npm-network' 'name: npm-app-data' 'name: npm-letsencrypt' 'npm-app-data:/data' 'npm-letsencrypt:/etc/letsencrypt' 'restart: unless-stopped' '/usr/bin/check-health' 'io.woow.nginxpm.managed' 'io.woow.nginxpm.owner'; do
  assert_contains "static topology contains $required" "$text" "$required"
done
[[ $(grep -cE '^      - "[^#]+:[0-9]+:[0-9]+"$' "$file") -eq 3 ]] && ok 'exactly three port mappings' || not_ok 'exactly three port mappings'
! grep -Eq '(^|[^0-9])81:81|0\.0\.0\.0:18081|\[::\].*18081|network_mode:|privileged:|INITIAL_ADMIN_(EMAIL|PASSWORD)' "$file" && ok 'no insecure topology or persistent bootstrap environment' || not_ok 'no insecure topology or persistent bootstrap environment'
if command -v podman-compose >/dev/null 2>&1; then
  version=$(podman-compose version 2>&1)
  if [[ $version == *1.0.6* ]]; then
    rendered=$(cd "$ROOT" && NPM_IMAGE="$pin" TZ=Asia/Taipei NPM_OWNER_ID=$(printf a%.0s {1..64}) COMPOSE_PROJECT_NAME=nginxpm podman-compose -f docker-compose.yml config 2>&1) && ok 'podman-compose 1.0.6 renders model' || not_ok 'podman-compose 1.0.6 renders model'
    assert_contains 'render retains loopback admin binding' "$rendered" '127.0.0.1'
    assert_contains 'render retains immutable image' "$rendered" "$pin"
  else
    printf 'SKIP: render requires exact podman-compose 1.0.6 (found %s)\n' "$version"
    ok 'static fallback enforced all security boundaries'
  fi
else
  echo 'SKIP: podman-compose 1.0.6 unavailable; strict static fallback executed'
  ok 'static fallback enforced all security boundaries'
fi
finish
