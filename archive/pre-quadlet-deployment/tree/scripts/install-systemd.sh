#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"
main() {
  local unit_dir linger i tmp
  local -a names=(
    nginx-proxy-manager.service
    nginx-proxy-manager-healthcheck.service
    nginx-proxy-manager-healthcheck.timer
  )
  local -a placeholder_counts=(2 1 0)
  local -a tmps=()
  [[ $# -eq 0 ]] || { die 'install-systemd.sh takes no arguments'; exit 2; }
  load_config "$REPO_ROOT/.env"
  require_command "$(podman_cmd)"; require_command "$(compose_cmd)"; require_command systemctl; require_command "$(python_cmd)"
  check_versions; check_rootless; check_low_ports
  [[ $REPO_ROOT != *$'\n'* && $REPO_ROOT != *$'\r'* ]] || { die 'checkout path contains a forbidden newline'; return 1; }
  unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
  ensure_private_dir "${unit_dir%/systemd/user}"
  mkdir -p "$unit_dir"; chmod 700 "$unit_dir"
  for i in "${!names[@]}"; do
    tmp=$(mktemp "$unit_dir/.${names[$i]}.XXXXXX")
    tmps+=("$tmp")
    "$(python_cmd)" - "$REPO_ROOT" "$REPO_ROOT/systemd/${names[$i]}" "$tmp" "${placeholder_counts[$i]}" <<'PY'
import sys
root, source, output, expected=sys.argv[1:]
escaped=root.replace('\\','\\\\').replace('"','\\"').replace('%','%%')
text=open(source,encoding='utf-8').read()
if text.count('@REPO_ROOT@') != int(expected): raise SystemExit(1)
open(output,'w',encoding='utf-8').write(text.replace('@REPO_ROOT@',escaped))
PY
    chmod 600 "$tmp"
  done
  for i in "${!names[@]}"; do mv -f "${tmps[$i]}" "$unit_dir/${names[$i]}"; done
  systemctl --user daemon-reload
  # The main unit gates timer re-arming in ExecStartPost, after deploy succeeds.
  systemctl --user enable nginx-proxy-manager.service nginx-proxy-manager-healthcheck.timer
  systemctl --user restart nginx-proxy-manager.service
  linger=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
  if [[ $linger != yes ]]; then log 'NOTE: an administrator must enable login lingering for unattended boot startup; this installer does not elevate privileges.'; fi
  log "systemd: installed ${names[*]} in $unit_dir"
}
main "$@"
