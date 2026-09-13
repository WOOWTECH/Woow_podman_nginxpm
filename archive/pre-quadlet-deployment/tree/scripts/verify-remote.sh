#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
die() { echo "ERROR: $*" >&2; exit 1; }
for name in TAILNET_TEST_SSH LAN_TEST_SSH TAILSCALE_GATEWAY_HOST LAN_TARGET_HOST; do [[ -n ${!name:-} ]] || die "$name is required"; done
[[ $TAILNET_TEST_SSH =~ ^[A-Za-z0-9_.@:-]+$ && $LAN_TEST_SSH =~ ^[A-Za-z0-9_.@:-]+$ ]] || die 'unsafe SSH destination'
[[ $TAILSCALE_GATEWAY_HOST =~ ^[A-Za-z0-9_.:-]+$ && $LAN_TARGET_HOST =~ ^[A-Za-z0-9_.:-]+$ ]] || die 'unsafe target host'
command -v timeout >/dev/null || die 'timeout command unavailable'
command -v python3 >/dev/null || die 'python3 unavailable'
command -v tailscale >/dev/null || die 'tailscale CLI unavailable on deployment host'
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=8 -o ConnectionAttempts=1)
remote() { timeout 25 ssh "${ssh_opts[@]}" "$@"; }
client_identity() {
  local value
  value=$(remote "$1" 'cat /etc/machine-id') || die "cannot establish stable identity for SSH client $1"
  value=${value//$'\r'/}; value=${value//$'\n'/}
  [[ $value =~ ^[0-9a-fA-F]{32}$ ]] || die "SSH client $1 returned an invalid stable identity"
  printf '%s\n' "${value,,}"
}
resolve_target() {
  local output
  output=$(remote "$1" getent ahosts "$2") || die "target $2 cannot be resolved from SSH client $1"
  [[ -n $output ]] || die "target $2 resolved to no addresses from SSH client $1"
  printf '%s\n' "$output" | awk '{print $1}' | sort -u
}
local_identity=$(cat /etc/machine-id 2>/dev/null) || die 'cannot establish deployment host stable identity'
local_identity=${local_identity//$'\r'/}; local_identity=${local_identity//$'\n'/}
[[ $local_identity =~ ^[0-9a-fA-F]{32}$ ]] || die 'deployment host stable identity is invalid'
tail_client_identity=$(client_identity "$TAILNET_TEST_SSH")
lan_client_identity=$(client_identity "$LAN_TEST_SSH")
[[ $tail_client_identity != "${local_identity,,}" && $lan_client_identity != "${local_identity,,}" ]] || die 'remote checks require clients other than the deployment host'
[[ $tail_client_identity != "$lan_client_identity" ]] || die 'tailnet and LAN SSH aliases resolve to the same client host'
tail_addresses=$(resolve_target "$TAILNET_TEST_SSH" "$TAILSCALE_GATEWAY_HOST")
lan_addresses=$(resolve_target "$LAN_TEST_SSH" "$LAN_TARGET_HOST")
TAIL_ADDRESSES=$tail_addresses LAN_ADDRESSES=$lan_addresses python3 - <<'PY' || die 'target aliases resolve unsafely or to the same address'
import ipaddress, os

def values(name):
    result=set()
    for raw in os.environ[name].splitlines():
        try: address=ipaddress.ip_address(raw)
        except ValueError: raise SystemExit(1)
        if address.is_loopback or address.is_unspecified: raise SystemExit(1)
        result.add(address)
    if not result: raise SystemExit(1)
    return result
raise SystemExit(1 if values('TAIL_ADDRESSES') & values('LAN_ADDRESSES') else 0)
PY
status=$(tailscale serve status --json 2>/dev/null) || die 'cannot read Tailscale Serve status'
STATUS_JSON=$status python3 - <<'PY' || die 'Tailscale TCP 18081 is not forwarded exclusively to loopback 18081'
import json,os
v=json.loads(os.environ['STATUS_JSON']); pairs=[]
def walk(x,path=''):
 if isinstance(x,dict):
  for k,v in x.items(): walk(v,path+'/'+str(k))
 elif isinstance(x,list):
  for i,v in enumerate(x): walk(v,path+'/'+str(i))
 elif isinstance(x,str): pairs.append((path,x))
walk(v)
allowed={'tcp://127.0.0.1:18081','127.0.0.1:18081'}
good=any('18081' in p and x in allowed for p,x in pairs)
bad=any('18081' in p and (x.startswith('tcp://') or ':18081' in x) and x not in allowed for p,x in pairs)
raise SystemExit(0 if good and not bad else 1)
PY
remote "$TAILNET_TEST_SSH" curl --silent --show-error --fail --max-time 10 "http://$TAILSCALE_GATEWAY_HOST:18081/api/" >/dev/null
if remote "$LAN_TEST_SSH" curl --silent --show-error --fail --max-time 5 "http://$LAN_TARGET_HOST:18081/api/" >/dev/null 2>&1; then
  die 'LAN client unexpectedly reached administration port'
else
  rc=$?
  [[ $rc -eq 7 ]] || die "LAN administration probe failed ambiguously (curl/SSH status $rc)"
fi
remote "$LAN_TEST_SSH" curl --silent --show-error --fail --max-time 10 -o /dev/null "http://$LAN_TARGET_HOST:80/"
remote "$LAN_TEST_SSH" curl --insecure --silent --show-error --fail --max-time 10 -o /dev/null "https://$LAN_TARGET_HOST:443/"
echo 'PASS: separate-client tailnet/LAN boundary verification'
