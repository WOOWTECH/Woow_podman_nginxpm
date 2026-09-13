#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"

verify_ports_and_mounts() {
  local bindings mounts
  bindings=$(_resource_inspect container "$CONTAINER_NAME" '{{json .HostConfig.PortBindings}}') || { die 'cannot inspect container port bindings'; return 1; }
  if ! BINDINGS_JSON=$bindings "$(python_cmd)" - <<'PY'
import json, os, sys

def reject(message):
    print(f'port binding error: {message}', file=sys.stderr)
    raise SystemExit(1)

try:
    bindings=json.loads(os.environ['BINDINGS_JSON'])
except Exception:
    reject('Podman inspect returned invalid JSON')
if not isinstance(bindings, dict):
    reject('Podman inspect did not return a port-binding object')
expected_ports={'80/tcp', '443/tcp', '81/tcp'}
if set(bindings) != expected_ports:
    reject('expected only container ports 80/tcp, 443/tcp, and 81/tcp')
for container_port, host_port in (('80/tcp', '80'), ('443/tcp', '443')):
    entries=bindings[container_port]
    if not isinstance(entries, list) or len(entries) != 1 or not isinstance(entries[0], dict):
        reject(f'{container_port} must have exactly one host binding')
    entry=entries[0]
    if set(entry) != {'HostIp', 'HostPort'} or entry['HostIp'] not in ('', '0.0.0.0') or entry['HostPort'] != host_port:
        reject(f'{container_port} must use IPv4 wildcard HostIp "" or "0.0.0.0" on host port {host_port}')
admin=bindings['81/tcp']
if admin != [{'HostIp':'127.0.0.1', 'HostPort':'18081'}]:
    reject('81/tcp must bind only to 127.0.0.1:18081')
PY
  then
    die 'container port binding verification failed'
    return 1
  fi
  mounts=$(_resource_inspect container "$CONTAINER_NAME" '{{range .Mounts}}{{println .Name "|" .Destination}}{{end}}') || return
  [[ $(printf '%s\n' "$mounts" | grep -Fx "$DATA_VOLUME | /data" | wc -l) -eq 1 ]] || die 'incorrect /data mount'
  [[ $(printf '%s\n' "$mounts" | grep -Fx "$LE_VOLUME | /etc/letsencrypt" | wc -l) -eq 1 ]] || die 'incorrect /etc/letsencrypt mount'
}
verify_listeners() {
  local listeners unsafe_public unsafe_admin
  require_command ss
  listeners=$(ss -H -ltn) || { die 'cannot inspect TCP listeners with ss'; return 1; }
  unsafe_public=$(printf '%s\n' "$listeners" | awk '
    $4 ~ /:80$/ && $4!="0.0.0.0:80" && $4!="*:80" {print $4; exit}
    $4 ~ /:443$/ && $4!="0.0.0.0:443" && $4!="*:443" {print $4; exit}
  ')
  if [[ -n $unsafe_public ]]; then
    die "unsafe public listener at $unsafe_public (only IPv4 wildcard endpoints 0.0.0.0:80, *:80, 0.0.0.0:443, and *:443 are allowed)"
    return 1
  fi
  if ! printf '%s\n' "$listeners" | awk '$4=="0.0.0.0:80" || $4=="*:80" {found=1} END{exit !found}'; then
    die 'public IPv4 wildcard listener missing on TCP port 80 (expected 0.0.0.0:80 or *:80)'
    return 1
  fi
  if ! printf '%s\n' "$listeners" | awk '$4=="0.0.0.0:443" || $4=="*:443" {found=1} END{exit !found}'; then
    die 'public IPv4 wildcard listener missing on TCP port 443 (expected 0.0.0.0:443 or *:443)'
    return 1
  fi
  unsafe_admin=$(printf '%s\n' "$listeners" | awk '$4 ~ /:(81|18081)$/ && $4!="127.0.0.1:18081" {print $4; exit}')
  if [[ -n $unsafe_admin ]]; then
    die "unsafe administration listener at $unsafe_admin (only 127.0.0.1:18081 is allowed)"
    return 1
  fi
  if ! printf '%s\n' "$listeners" | awk '$4=="127.0.0.1:18081" {found=1} END{exit !found}'; then
    die 'administration listener missing at exact endpoint 127.0.0.1:18081'
    return 1
  fi
}
verify_logs_redacted() {
  local p tmp creds
  p=$(podman_cmd); tmp=$(mktemp "$REPO_ROOT/.state/logs.XXXXXX"); chmod 600 "$tmp"
  "$p" logs "$CONTAINER_NAME" >"$tmp" 2>/dev/null || { rm -f "$tmp"; die 'cannot inspect container logs'; return 1; }
  creds=$(credentials_file)
  if ! "$(python_cmd)" - "$tmp" "$creds" <<'PY'
import sys
log=open(sys.argv[1],encoding='utf-8',errors='replace').read()
values={}
for line in open(sys.argv[2],encoding='utf-8'):
    k,sep,v=line.rstrip('\n').partition('=')
    if sep: values[k]=v
initial='change'+'me'
canaries=(initial, 'admin@example.com', values.get('NPM_ADMIN_EMAIL','\0'), values.get('PASSWORD','\0'))
if any(value in log for value in canaries):
    raise SystemExit(1)
PY
  then rm -f "$tmp"; die 'credential material found in container logs'; return 1
  fi
  rm -f "$tmp"
}
main() {
  local from_deploy=0
  case ${1:-} in --from-deploy) from_deploy=1;; '') ;; *) die 'unknown verify option'; exit 2;; esac
  load_config "$REPO_ROOT/.env"
  require_command "$(podman_cmd)"; require_command "$(compose_cmd)"; require_command "$(python_cmd)"; require_command curl
  check_versions; check_rootless; check_low_ports
  if ((from_deploy==0)); then
    ensure_private_dirs; exec 8>"$REPO_ROOT/.state/lifecycle.lock"; flock -s 8
  fi
  owner_id
  render_compose
  check_all_ownership
  resource_absent container "$CONTAINER_NAME" && { die 'owned container is absent'; return 1; }
  container_running || { die 'container is not running'; return 1; }
  require_owned_healthcheck
  verify_ports_and_mounts
  verify_steady_environment_redacted
  verify_listeners
  wait_http_ready
  api_helper ready --url "$ADMIN_URL" >/dev/null
  local generated_rc default_rc
  if credentials_auth_generated; then :
  else
    generated_rc=$?
    [[ $generated_rc -eq 10 ]] && { die 'generated credentials rejected'; return 1; }
    die 'generated credential authentication could not be evaluated'; return 1
  fi
  if default_auth; then die 'initial credentials still authenticate'; return 1; else default_rc=$?; fi
  [[ $default_rc -eq 10 ]] || { die 'initial credential rejection could not be proven'; return 1; }
  verify_logs_redacted
  log 'verify: all security invariants passed'
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
