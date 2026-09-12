#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Nginx Proxy Manager Quadlet units. Keeps data by default.
#
#   scripts/uninstall.sh                   stop + remove the units; keep npm-app-data,
#                                          npm-letsencrypt, the npm-network network, the
#                                          env file and the image
#   scripts/uninstall.sh --purge [--yes]   also delete both volumes (after a final export to
#                                          ~/backups/npm/<ts>/) and the npm-network network
#   scripts/uninstall.sh --dry-run         report what would be removed
#
# The pi-agent network is never touched: it belongs to Woow_podman_pi_agent_package.
# Never deleted here: ~/.config/npm/npm.env, images, podman.socket.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

purge=0 yes=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$NPM_APP
ql_require_rootless
ql_lock "$NPM_APP"

if ((!purge)); then
  ql_uninstall_units "$NPM_APP"
  exit 0
fi
if ((!yes)) && [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  [[ -t 0 ]] || ql_die "--purge deletes npm-app-data and npm-letsencrypt; add --yes to confirm non-interactively"
  read -r -p "Type 'npm' to delete the NPM volumes (proxy hosts, access lists, certificates): " answer
  [[ $answer == npm ]] || ql_die "aborted; nothing was deleted"
fi
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  systemctl --user stop "$NPM_UNIT" 2>/dev/null || true
  dest=$HOME/backups/npm/final-$(date +%Y%m%d-%H%M%S)
  for v in "${NPM_VOLUMES[@]}"; do
    if podman volume exists "$v"; then ql_backup_volume "$v" "$dest" >/dev/null; fi
  done
  ql_info "final export: $dest"
fi
ql_uninstall_units "$NPM_APP" --purge
