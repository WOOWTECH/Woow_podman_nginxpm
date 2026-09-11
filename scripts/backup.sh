#!/usr/bin/env bash
# scripts/backup.sh: export both NPM volumes (SQLite DB, proxy hosts, access lists with
# hashed credentials, JWT keys, certificates) plus ~/.config/npm, into one directory.
#
#   scripts/backup.sh [--hot] [--dest DIR]
#
#   (default)   cold: stop npm-app for the export (a few seconds), then start it again
#   --hot       no stop (SQLite writes are rare, but a cold export is consistent)
#   --dest DIR  parent directory, default ~/backups/npm; each run writes DIR/<timestamp>/
#
# Prints the run directory on stdout. Files are 0600 in 0700 directories, each with a
# .sha256. Restore with: scripts/restore.sh DIR/<timestamp>
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

parent=$HOME/backups/npm hot=0
while (($#)); do
  case $1 in
    --hot) hot=1 ;;
    --dest) parent=${2:?--dest needs a directory}; shift ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
for v in "${NPM_VOLUMES[@]}"; do podman volume exists "$v" >/dev/null 2>&1 || ql_die "volume $v does not exist"; done
dest=$parent/$(date +%Y%m%d-%H%M%S)
[[ ! -e $dest ]] || ql_die "$dest already exists"

restart=0
if ((!hot)) && systemctl --user is-active --quiet "$NPM_UNIT"; then
  restart=1
  trap 'systemctl --user start "$NPM_UNIT" || ql_warn "could not start $NPM_UNIT again; run: systemctl --user start $NPM_UNIT"' EXIT
  ql_info "stopping $NPM_UNIT for a consistent export (use --hot to skip)"
  systemctl --user stop "$NPM_UNIT"
fi
for v in "${NPM_VOLUMES[@]}"; do ql_backup_volume "$v" "$dest" >/dev/null; done
if [[ -d $HOME/.config/npm ]]; then
  (umask 077 && tar -czf "$dest/npm-config.tgz" -C "$HOME/.config" npm) || ql_die "cannot archive ~/.config/npm"
  (cd -- "$dest" && umask 077 && sha256sum -- npm-config.tgz >npm-config.tgz.sha256)
fi
((restart)) && ql_info "starting $NPM_UNIT again"
ql_info "backup complete: $dest"
printf '%s\n' "$dest"
