#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
if [[ ${RUN_LIVE_TESTS:-0} != 1 ]]; then echo 'SKIP: local lifecycle test requires RUN_LIVE_TESTS=1 and mutates local owned Podman resources'; exit 0; fi
{ set +x; } 2>/dev/null
out=$(mktemp); cred_copy=$(mktemp); chmod 600 "$out" "$cred_copy"; installed=0
cleanup() { rc=$?; rm -f "$out" "$cred_copy"; if ((installed)); then systemctl --user disable --now nginx-proxy-manager-healthcheck.timer nginx-proxy-manager.service >/dev/null 2>&1 || true; rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager-healthcheck.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager-healthcheck.timer"; systemctl --user daemon-reload >/dev/null 2>&1 || true; fi; if [[ -f $ROOT/.env ]]; then "$ROOT/scripts/remove.sh" --purge-data --yes >/dev/null 2>&1 || true; fi; exit "$rc"; }; trap cleanup EXIT INT TERM HUP
"$ROOT/scripts/deploy.sh" >"$out" 2>&1
"$ROOT/scripts/deploy.sh" >>"$out" 2>&1
"$ROOT/scripts/verify.sh"
"$ROOT/scripts/install-systemd.sh"; installed=1
systemctl --user restart nginx-proxy-manager.service
"$ROOT/scripts/verify.sh"
podman exec npm-app sh -c 'printf before > /data/.woow-live-fixture'
"$ROOT/scripts/backup.sh"
archive=$(find "$ROOT/backups" -maxdepth 1 -name 'npm-backup-*.tar.gz' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
podman exec npm-app sh -c 'printf after > /data/.woow-live-fixture'
"$ROOT/scripts/restore.sh" "$archive"
[[ $(podman exec npm-app cat /data/.woow-live-fixture) == before ]]
"$ROOT/scripts/remove.sh"
"$ROOT/scripts/deploy.sh" >>"$out" 2>&1
cp "$ROOT/.secrets/npm-admin.env" "$cred_copy"; chmod 600 "$cred_copy"
"$ROOT/scripts/remove.sh" --purge-data --yes
"$ROOT/scripts/remove.sh" --purge-data --yes
python3 - "$out" "$cred_copy" <<'PY'
import sys
out=open(sys.argv[1],errors='replace').read(); values={}
if __import__('os').path.exists(sys.argv[2]):
 for line in open(sys.argv[2]):
  k,s,v=line.rstrip().partition('='); values[k]=v if s else ''
if values.get('PASSWORD') and values['PASSWORD'] in out: raise SystemExit(1)
PY
systemctl --user disable --now nginx-proxy-manager-healthcheck.timer nginx-proxy-manager.service >/dev/null; rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager-healthcheck.service" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/nginx-proxy-manager-healthcheck.timer"; systemctl --user daemon-reload; installed=0
echo 'PASS: local live deploy/lifecycle/convergence test'
trap - EXIT; rm -f "$out" "$cred_copy"
