#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
pin='docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb'
for doc in "$ROOT/docs/operations.md" "$ROOT/docs/operations.zh-TW.md"; do
 text=$(cat "$doc"); name=${doc##*/}
 for token in '4.9.3' '1.0.6' 'image-pin.md' 'chmod 600 .env' '0.0.0.0:80' '0.0.0.0:443' '127.0.0.1:18081' 'npm-app' 'npm-network' 'npm-app-data' 'npm-letsencrypt' './scripts/deploy.sh' './scripts/verify.sh' './scripts/backup.sh' './scripts/restore.sh' './scripts/remove.sh' '--purge-data --yes' './scripts/install-systemd.sh' 'ip_unprivileged_port_start' 'lingering' 'data/' 'letsencrypt/' 'rollback' 'RUN_REMOTE_LIVE_TESTS=1' 'tcp://127.0.0.1:18081'; do assert_contains "$name contains $token" "$text" "$token"; done
 [[ $text == *'credentials'* || $text == *'憑證'* ]] && ok "$name warns about credentials" || not_ok "$name warns about credentials"
done
prod=$(find "$ROOT" -path "$ROOT/docs/plans" -prune -o -path "$ROOT/tests" -prune -o -type f \( -name '*.md' -o -name '*.yml' \) -print0 | xargs -0 cat)
! grep -Eq 'nginx-proxy-manager:latest|0\.0\.0\.0:81|docker compose|podman compose|tar xzf' <<<"$prod" && ok 'no legacy deployment guidance remains' || not_ok 'no legacy deployment guidance remains'
grep -Fq "$pin" "$ROOT/.env.example" && grep -Fq "$pin" "$ROOT/docs/image-pin.md" && ok 'reviewed pin is consistent' || not_ok 'reviewed pin is consistent'
finish
