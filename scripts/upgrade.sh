#!/usr/bin/env bash
# scripts/upgrade.sh: move npm-app to the image pinned in quadlet/npm-app.container (run it
# after a `git pull` that bumped the version), with a cold backup first and an automatic
# rollback that also restores the volumes (NPM's database migrations only go forward).
#
#   scripts/upgrade.sh [--no-backup]
#
# Steps: pull the new image while the old one serves -> with the pi-web front, check that
# the new image's proxy.conf still matches ours (tests/pi-web-front.sh) -> cold backup ->
# keep copies of the installed files -> scripts/install.sh -> on failure: put the previous
# files back, restore both volumes from the backup, restart, smoke.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

QDIR=$HOME/.config/containers/systemd
STATE=$HOME/.local/state/woow-quadlet/$NPM_APP
export QL_APP=$NPM_APP
backup=1
while (($#)); do
  case $1 in
    --no-backup) backup=0 ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_require_podman_min 4.4
[[ -f $QDIR/npm-app.container && -f $NPM_ENV_FILE ]] || ql_die "npm-app is not installed by this package yet; run scripts/install.sh"
prev_image=$(npm_image_of "$QDIR/npm-app.container")
new_image=$(npm_image_of "$REPO/quadlet/npm-app.container")
ql_info "installed: $prev_image; repo pins: $new_image"
if [[ $new_image == "$prev_image" ]]; then
  ql_info "the pinned image is unchanged; running install.sh to converge the units"
  exec bash "$REPO/scripts/install.sh"
fi

# 1. everything that can fail without downtime
podman image exists "$new_image" >/dev/null 2>&1 || podman pull "$new_image" >/dev/null || ql_die "podman pull $new_image failed; nothing was changed"
if [[ $(npm_env_value NPM_PI_WEB_FRONT false) == true ]]; then
  bash "$REPO/tests/pi-web-front.sh" --image "$new_image" \
    || ql_die "$new_image changed the proxy.conf that the pi-web front replaces; update config/pi-web-front/proxy.conf first. Nothing was changed"
fi
bdir=''
if ((backup)); then
  bdir=$(bash "$REPO/scripts/backup.sh") || ql_die "backup failed; nothing was changed (use --no-backup to skip it)"
fi

# 2. keep what is installed now
rb=$STATE/upgrade-$(date +%Y%m%d-%H%M%S)
(umask 077 && mkdir -p "$rb/config")
for f in npm-app.container npm.network npm-app-data.volume npm-letsencrypt.volume; do
  [[ -f $QDIR/$f ]] && cp -p -- "$QDIR/$f" "$rb/"
done
[[ -f $STATE/manifest ]] && cp -p -- "$STATE/manifest" "$rb/"
[[ -d $HOME/.config/npm/pi-web-front ]] && cp -pR -- "$HOME/.config/npm/pi-web-front" "$rb/config/"

# 3. switch
if bash "$REPO/scripts/install.sh"; then
  ql_info "upgraded npm-app: $prev_image -> $new_image (backup: ${bdir:-none}; previous image kept)"
  exit 0
fi

# 4. rollback: files, then data (a newer NPM may have migrated the database), then start
ql_warn "the upgrade failed; rolling back to $prev_image"
systemctl --user stop "$NPM_UNIT" 2>/dev/null || true
for f in npm-app.container npm.network npm-app-data.volume npm-letsencrypt.volume; do
  [[ -f $rb/$f ]] && cp -p -- "$rb/$f" "$QDIR/$f"
done
[[ -f $rb/manifest ]] && cp -p -- "$rb/manifest" "$STATE/manifest"
[[ -d $rb/config/pi-web-front ]] && cp -pR -- "$rb/config/pi-web-front" "$HOME/.config/npm/"
systemctl --user daemon-reload
if [[ -n $bdir ]]; then
  # restore.sh ends with tests/smoke.sh: a non-zero exit can mean the data restore failed,
  # or only that a check is still red. Report it, keep going, and let the operator look.
  bash "$REPO/scripts/restore.sh" "$bdir" --yes --no-safety-backup \
    || ql_warn "rollback: scripts/restore.sh $bdir reported a problem (above); check npm-app by hand"
else
  systemctl --user start "$NPM_UNIT" || ql_die "rollback: $NPM_UNIT does not start; see journalctl --user -u $NPM_UNIT -n 100"
  QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$NPM_CONTAINER" 300 || ql_die "rollback: npm-app is not healthy on $prev_image either"
  bash "$REPO/tests/smoke.sh" || ql_warn "rollback: smoke checks failed"
fi
ql_warn "rolled back to $prev_image; the checkout still pins $new_image. Fix the problem and run upgrade.sh again."
exit 1
