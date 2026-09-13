#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"
WAS_RUNNING=0 BACKUP_STAGE='' OUTPUT_STAGE='' PUBLISHED=0
PUBLISHED_ARCHIVE='' PUBLISHED_MANIFEST='' PUBLISHED_CHECKSUM=''
restore_running_state() {
  local rc=$? p
  trap - EXIT INT TERM HUP
  p=$(podman_cmd 2>/dev/null || true)
  if ((WAS_RUNNING)) && [[ -n $p ]]; then run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null 2>&1 || rc=1; fi
  if [[ -n $BACKUP_STAGE && -d $BACKUP_STAGE ]]; then
    if [[ -n $p ]]; then "$p" unshare rm -rf "$BACKUP_STAGE" >/dev/null 2>&1 || true; else rm -rf "$BACKUP_STAGE" || true; fi
  fi
  [[ -z $OUTPUT_STAGE || ! -d $OUTPUT_STAGE ]] || rm -rf -- "$OUTPUT_STAGE" || true
  if ((PUBLISHED)) && ((rc != 0)); then rm -f -- "$PUBLISHED_ARCHIVE" "$PUBLISHED_MANIFEST" "$PUBLISHED_CHECKSUM"; fi
  exit "$rc"
}
main() {
  local destination=${1:-"$REPO_ROOT/backups"} p data_mp le_mp stamp base stage archive manifest checksum
  [[ $# -le 1 ]] || { die 'usage: backup.sh [destination]'; exit 2; }
  lifecycle_lock
  load_config "$REPO_ROOT/.env"; require_command "$(podman_cmd)"; require_command "$(compose_cmd)"; require_command "$(python_cmd)"; require_command tar; require_command sha256sum
  check_versions; check_rootless; check_low_ports
  owner_id; render_compose; check_all_ownership
  for resource in "$CONTAINER_NAME:$CONTAINER_NAME" "volume:$DATA_VOLUME" "volume:$LE_VOLUME"; do
    type=${resource%%:*}; name=${resource#*:}; [[ $type == "$CONTAINER_NAME" ]] && type=container
    resource_absent "$type" "$name" && { die "cannot back up absent $type $name"; return 1; }
  done
  if container_running; then container_healthy || { die 'refusing backup of unhealthy running container'; return 1; }; WAS_RUNNING=1; fi
  ensure_private_dir "$destination"
  [[ $(readlink -f -- "$destination") == "$destination" ]] || { die 'backup destination must be a canonical non-symlink path'; return 1; }
  p=$(podman_cmd); data_mp=$(volume_mountpoint "$DATA_VOLUME"); le_mp=$(volume_mountpoint "$LE_VOLUME")
  stage=$(mktemp -d "$REPO_ROOT/.state/backup.XXXXXX"); BACKUP_STAGE=$stage; chmod 700 "$stage"; mkdir -m 700 "$stage/data" "$stage/letsencrypt"
  trap restore_running_state EXIT
  trap 'exit 130' INT TERM HUP
  stamp=$(date -u +%Y%m%dT%H%M%SZ); base="npm-backup-$stamp"; archive="$destination/$base.tar.gz"; manifest="$destination/$base.manifest"; checksum="$destination/$base.sha256"
  PUBLISHED_ARCHIVE=$archive; PUBLISHED_MANIFEST=$manifest; PUBLISHED_CHECKSUM=$checksum
  [[ ! -e $archive && ! -e $manifest && ! -e $checksum ]] || { die 'backup timestamp collision'; return 1; }
  printf 'format_version=1\ncreated_utc=%s\nimage=%s\nowner_id=%s\n' "$stamp" "$NPM_IMAGE" "$NPM_OWNER_ID" | atomic_private_write "$stage/manifest"
  OUTPUT_STAGE=$(mktemp -d "$destination/.backup-set.XXXXXX"); chmod 700 "$OUTPUT_STAGE"
  if ((WAS_RUNNING)); then log 'backup: stopping for consistent snapshot'; "$p" stop "$CONTAINER_NAME" >/dev/null; fi
  "$p" unshare tar -C "$data_mp" --numeric-owner -cf - . | "$p" unshare tar -C "$stage/data" --numeric-owner -xf -
  "$p" unshare tar -C "$le_mp" --numeric-owner -cf - . | "$p" unshare tar -C "$stage/letsencrypt" --numeric-owner -xf -
  "$p" unshare tar -C "$stage" --numeric-owner -czf "$OUTPUT_STAGE/$base.tar.gz" manifest data letsencrypt
  chmod 600 "$OUTPUT_STAGE/$base.tar.gz"
  cp "$stage/manifest" "$OUTPUT_STAGE/$base.manifest"; chmod 600 "$OUTPUT_STAGE/$base.manifest"
  (cd "$OUTPUT_STAGE" && sha256sum "$base.tar.gz") | atomic_private_write "$OUTPUT_STAGE/$base.sha256"
  "$(python_cmd)" "$REPO_ROOT/scripts/lib/validate_backup.py" "$OUTPUT_STAGE/$base.tar.gz" --image "$NPM_IMAGE" --owner "$NPM_OWNER_ID" >/dev/null
  PUBLISHED=1
  mv "$OUTPUT_STAGE/$base.manifest" "$manifest"
  mv "$OUTPUT_STAGE/$base.tar.gz" "$archive"
  mv "$OUTPUT_STAGE/$base.sha256" "$checksum"
  "$(python_cmd)" "$REPO_ROOT/scripts/lib/validate_backup.py" "$archive" --image "$NPM_IMAGE" --owner "$NPM_OWNER_ID" >/dev/null
  "$p" unshare rm -rf "$stage"; BACKUP_STAGE=''
  log "backup: complete: $archive"
}
main "$@"
