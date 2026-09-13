#!/usr/bin/env bash
# scripts/restore.sh: put the NPM volumes back from a scripts/backup.sh run directory.
#
#   scripts/restore.sh <DIR> [--yes] [--no-safety-backup] [--with-config]
#
#   DIR                 a run directory from backup.sh (holds npm-app-data-*.tar,
#                       npm-letsencrypt-*.tar and npm-config.tgz)
#   --yes               do not ask for confirmation (required without a terminal)
#   --no-safety-backup  do not export the current contents first
#   --with-config       also restore ~/.config/npm from npm-config.tgz (then re-run install.sh)
#
# Destructive: both volumes are emptied and re-imported. The current contents are exported
# to ~/backups/npm/pre-restore-<ts>/ first. npm-app is stopped meanwhile, then started and
# checked with tests/smoke.sh.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

dir='' yes=0 safety=1 config=0
while (($#)); do
  case $1 in
    --yes) yes=1 ;;
    --no-safety-backup) safety=0 ;;
    --with-config) config=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $dir ]] || ql_die "one directory only"; dir=$1 ;;
  esac
  shift
done
[[ -n $dir && -d $dir ]] || ql_die "usage: scripts/restore.sh <backup run directory> [--yes]"
ql_require_rootless
ql_lock "$NPM_APP"
declare -A tarof=()
for v in "${NPM_VOLUMES[@]}"; do
  mapfile -t found < <(find "$dir" -maxdepth 1 -name "$v-*.tar" | sort)
  ((${#found[@]} == 1)) || ql_die "expected exactly one $v-*.tar in $dir, found ${#found[@]}"
  tarof[$v]=${found[0]}
  (cd -- "$dir" && sha256sum -c --quiet -- "$(basename -- "${found[0]}").sha256") || ql_die "checksum mismatch: ${found[0]}"
done
if ((config)); then
  [[ -f $dir/npm-config.tgz ]] || ql_die "--with-config: $dir/npm-config.tgz is missing"
  (cd -- "$dir" && sha256sum -c --quiet npm-config.tgz.sha256) || ql_die "checksum mismatch: npm-config.tgz"
fi
ql_info "checksums ok"
if ((!yes)); then
  [[ -t 0 ]] || ql_die "restore replaces npm-app-data and npm-letsencrypt; add --yes to confirm non-interactively"
  read -r -p "Replace the NPM volumes with the backup in $dir? Type 'restore': " answer
  [[ $answer == restore ]] || ql_die "aborted; nothing was changed"
fi

systemctl --user stop "$NPM_UNIT" 2>/dev/null || true
[[ $(podman container inspect --format '{{.State.Running}}' "$NPM_CONTAINER" 2>/dev/null || true) != true ]] \
  || ql_die "npm-app is still running; stop whatever runs it first"
if ((safety)); then
  pre=$HOME/backups/npm/pre-restore-$(date +%Y%m%d-%H%M%S)
  for v in "${NPM_VOLUMES[@]}"; do
    podman volume exists "$v" >/dev/null 2>&1 && ql_backup_volume "$v" "$pre" >/dev/null
  done
  ql_info "current contents exported to $pre"
fi
for v in "${NPM_VOLUMES[@]}"; do
  podman volume exists "$v" >/dev/null 2>&1 || podman volume create "$v" >/dev/null
  mp=$(podman volume inspect --format '{{.Mountpoint}}' "$v")
  [[ -n $mp && -d $mp && $mp == */volumes/*/_data ]] || ql_die "unexpected mountpoint '$mp' for volume $v"
  # Files in the volume may belong to container subuids: delete inside the user namespace.
  podman unshare find "$mp" -mindepth 1 -delete || ql_die "cannot empty volume $v"
  podman volume import "$v" "${tarof[$v]}" || ql_die "podman volume import $v failed; import ${tarof[$v]} again, or the pre-restore export"
  ql_info "restored $v from ${tarof[$v]##*/}"
done
if ((config)); then
  tar -xzf "$dir/npm-config.tgz" -C "$HOME/.config" || ql_die "cannot restore ~/.config/npm"
  ql_info "restored ~/.config/npm; run scripts/install.sh to re-render the unit from it"
fi
systemctl --user start "$NPM_UNIT"
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$NPM_CONTAINER" 300 || ql_die "npm-app is not healthy after the restore"
bash "$REPO/tests/smoke.sh"
