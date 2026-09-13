#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"

WAS_RUNNING=0
SHOULD_START=0
MUTATED=0
COMMITTED=0
MAIN_STOPPED=0
STAGE=''
STAGED_ARCHIVE=''
ROLLBACK=''
RETAIN_ROLLBACK=0
RB_STOP='not-run'
RB_DATA_MOUNT='not-run'
RB_DATA_DELETE='not-run'
RB_DATA_EXTRACT='not-run'
RB_LE_MOUNT='not-run'
RB_LE_DELETE='not-run'
RB_LE_EXTRACT='not-run'
RB_RESTART='not-run'

available_bytes() {
  if [[ -n ${RESTORE_AVAILABLE_BYTES:-} ]]; then
    [[ ${TEST_MODE:-0} == 1 && $RESTORE_AVAILABLE_BYTES =~ ^[0-9]+$ ]] || { die 'RESTORE_AVAILABLE_BYTES is test-only'; return 1; }
    printf '%s\n' "$RESTORE_AVAILABLE_BYTES"
    return
  fi
  "$(python_cmd)" - "$1" <<'PY'
import os,sys
v=os.statvfs(sys.argv[1]); print(v.f_bavail*v.f_frsize)
PY
}

require_free_bytes() {
  local path=$1 required=$2 context=$3 available
  available=$(available_bytes "$path") || return
  [[ $available =~ ^[0-9]+$ ]] || { die "cannot determine available staging disk for $context"; return 1; }
  ((available >= required)) || { die "insufficient staging disk for $context (required=$required available=$available)"; return 1; }
}

remove_private_tree() {
  local path=$1 p=${2:-}
  [[ -n $path && -d $path ]] || return 0
  if [[ -n $p ]]; then "$p" unshare rm -rf -- "$path" >/dev/null 2>&1
  else rm -rf -- "$path" >/dev/null 2>&1
  fi
}

emit_recovery() {
  local p=$1
  log "restore rollback status: stop=$RB_STOP data-mount=$RB_DATA_MOUNT data-delete=$RB_DATA_DELETE data-extract=$RB_DATA_EXTRACT letsencrypt-mount=$RB_LE_MOUNT letsencrypt-delete=$RB_LE_DELETE letsencrypt-extract=$RB_LE_EXTRACT restart=$RB_RESTART"
  log "RECOVERY REQUIRED: rollback snapshots retained at $ROLLBACK"
  log "Keep $CONTAINER_NAME stopped. After correcting the reported failure, inspect the snapshots and restore each volume manually:"
  printf '  %q stop %q\n' "$p" "$CONTAINER_NAME" >&2
  printf '  %q unshare sh -c '\''find "$1" -mindepth 1 -delete'\'' sh "$(%q volume inspect --format '\''{{.Mountpoint}}'\'' %q)"\n' "$p" "$p" "$DATA_VOLUME" >&2
  printf '  %q unshare tar -C "$(%q volume inspect --format '\''{{.Mountpoint}}'\'' %q)" --numeric-owner -xf %q\n' "$p" "$p" "$DATA_VOLUME" "$ROLLBACK/data.tar" >&2
  printf '  %q unshare sh -c '\''find "$1" -mindepth 1 -delete'\'' sh "$(%q volume inspect --format '\''{{.Mountpoint}}'\'' %q)"\n' "$p" "$p" "$LE_VOLUME" >&2
  printf '  %q unshare tar -C "$(%q volume inspect --format '\''{{.Mountpoint}}'\'' %q)" --numeric-owner -xf %q\n' "$p" "$p" "$LE_VOLUME" "$ROLLBACK/letsencrypt.tar" >&2
  if ((WAS_RUNNING)); then printf '  # Only after both restores succeed: %q start %q\n' "$p" "$CONTAINER_NAME" >&2; fi
}

rollback_volume() {
  local p=$1 volume=$2 snapshot=$3 prefix=$4 mp=''
  if mp=$(volume_mountpoint "$volume" 2>/dev/null); then
    if [[ $prefix == data ]]; then RB_DATA_MOUNT='ok'; else RB_LE_MOUNT='ok'; fi
  else
    if [[ $prefix == data ]]; then RB_DATA_MOUNT='failed'; RB_DATA_DELETE='skipped'; RB_DATA_EXTRACT='skipped'
    else RB_LE_MOUNT='failed'; RB_LE_DELETE='skipped'; RB_LE_EXTRACT='skipped'; fi
    return 1
  fi
  if "$p" unshare sh -c 'find "$1" -mindepth 1 -delete' sh "$mp" >/dev/null 2>&1; then
    if [[ $prefix == data ]]; then RB_DATA_DELETE='ok'; else RB_LE_DELETE='ok'; fi
  else
    if [[ $prefix == data ]]; then RB_DATA_DELETE='failed'; RB_DATA_EXTRACT='skipped'
    else RB_LE_DELETE='failed'; RB_LE_EXTRACT='skipped'; fi
    return 1
  fi
  if "$p" unshare tar -C "$mp" --numeric-owner -xf "$snapshot" >/dev/null 2>&1; then
    if [[ $prefix == data ]]; then RB_DATA_EXTRACT='ok'; else RB_LE_EXTRACT='ok'; fi
  else
    if [[ $prefix == data ]]; then RB_DATA_EXTRACT='failed'; else RB_LE_EXTRACT='failed'; fi
    return 1
  fi
}

perform_rollback() {
  local p=$1 partial=0
  RETAIN_ROLLBACK=1
  if "$p" stop "$CONTAINER_NAME" >/dev/null 2>&1; then
    RB_STOP='ok'
  else
    RB_STOP='failed'; partial=1
    RB_DATA_MOUNT='skipped'; RB_DATA_DELETE='skipped'; RB_DATA_EXTRACT='skipped'
    RB_LE_MOUNT='skipped'; RB_LE_DELETE='skipped'; RB_LE_EXTRACT='skipped'
  fi
  if ((partial == 0)); then
    rollback_volume "$p" "$DATA_VOLUME" "$ROLLBACK/data.tar" data || partial=1
    rollback_volume "$p" "$LE_VOLUME" "$ROLLBACK/letsencrypt.tar" letsencrypt || partial=1
  fi
  if ((partial == 0)) && ((WAS_RUNNING)); then
    if run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null 2>&1; then RB_RESTART='ok'; else RB_RESTART='failed'; partial=1; fi
  elif ((WAS_RUNNING)); then
    RB_RESTART='skipped-partial-rollback'
  else
    RB_RESTART='not-required'
  fi
  emit_recovery "$p"
  ((partial == 0))
}

cleanup_restore() {
  local rc=$? p=''
  trap - EXIT INT TERM HUP
  set +e
  p=$(podman_cmd 2>/dev/null)
  if ((!COMMITTED)); then
    if ((MUTATED)) && [[ -n $p && -d $ROLLBACK ]]; then
      perform_rollback "$p" || rc=1
    elif ((MAIN_STOPPED && WAS_RUNNING)) && [[ -n $p ]]; then
      if run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null 2>&1; then
        RB_RESTART='ok'
      else
        RB_RESTART='failed'; RETAIN_ROLLBACK=1; rc=1
        log "RECOVERY REQUIRED: the pre-restore container restart failed; snapshots, if present, remain at $ROLLBACK"
        printf '  %q start %q\n' "$p" "$CONTAINER_NAME" >&2
      fi
    fi
  fi
  remove_private_tree "$STAGE" "$p" || true
  if ((COMMITTED || !RETAIN_ROLLBACK)); then remove_private_tree "$ROLLBACK" "$p" || true; fi
  exit "$rc"
}

main() {
  local archive='' source_stem source_manifest source_checksum start=0 p data_mp le_mp
  local copy_bytes archive_bytes logical_bytes member_count metrics free_required snapshot_bytes
  while (($#)); do
    case $1 in
      --start) start=1;;
      --*) die "unknown restore option: $1"; exit 2;;
      *) [[ -z $archive ]] || { die 'only one archive may be restored'; exit 2; }; archive=$1;;
    esac
    shift
  done
  [[ -n $archive ]] || { die 'usage: restore.sh [--start] BACKUP.tar.gz'; exit 2; }
  [[ $archive == *.tar.gz ]] || { die 'restore archive must end in .tar.gz'; exit 2; }
  archive=$(readlink -f -- "$archive")
  source_stem=${archive%.tar.gz}; source_manifest=$source_stem.manifest; source_checksum=$source_stem.sha256

  lifecycle_lock
  load_config "$REPO_ROOT/.env"
  require_command "$(podman_cmd)"; require_command "$(compose_cmd)"; require_command "$(python_cmd)"; require_command tar
  check_versions; check_rootless; check_low_ports
  owner_id; render_compose; check_all_ownership
  for resource in "container:$CONTAINER_NAME" "volume:$DATA_VOLUME" "volume:$LE_VOLUME"; do
    type=${resource%%:*}; name=${resource#*:}
    resource_absent "$type" "$name" && { die "cannot restore absent $type $name"; return 1; }
  done
  require_private_file "$archive"; require_private_file "$source_manifest"; require_private_file "$source_checksum"

  STAGE=$(mktemp -d "$REPO_ROOT/.state/restore-stage.XXXXXX"); chmod 700 "$STAGE"
  p=$(podman_cmd)
  trap cleanup_restore EXIT
  trap 'exit 130' INT TERM HUP
  copy_bytes=$(($(stat -c '%s' -- "$archive") + $(stat -c '%s' -- "$source_manifest") + $(stat -c '%s' -- "$source_checksum") + 1048576))
  require_free_bytes "$STAGE" "$copy_bytes" 'private backup copy'
  STAGED_ARCHIVE="$STAGE/$(basename -- "$archive")"
  cp -- "$archive" "$STAGED_ARCHIVE"
  cp -- "$source_manifest" "${STAGED_ARCHIVE%.tar.gz}.manifest"
  cp -- "$source_checksum" "${STAGED_ARCHIVE%.tar.gz}.sha256"
  chmod 400 "$STAGED_ARCHIVE" "${STAGED_ARCHIVE%.tar.gz}.manifest" "${STAGED_ARCHIVE%.tar.gz}.sha256"

  # Validation and extraction use only this private read-only copy. The caller's
  # paths are never opened again after staging.
  metrics=$("$(python_cmd)" "$REPO_ROOT/scripts/lib/validate_backup.py" "$STAGED_ARCHIVE" --image "$NPM_IMAGE" --owner "$NPM_OWNER_ID" --metrics) || return
  read -r archive_bytes logical_bytes member_count <<<"$metrics"
  [[ $archive_bytes =~ ^[0-9]+$ && $logical_bytes =~ ^[0-9]+$ && $member_count =~ ^[0-9]+$ ]] || { die 'backup validator returned invalid metrics'; return 1; }
  free_required=$((logical_bytes + 64 * 1024 * 1024))
  require_free_bytes "$STAGE" "$free_required" 'validated backup extraction'
  "$p" unshare tar -C "$STAGE" --numeric-owner -xzf "$STAGED_ARCHIVE"

  WAS_RUNNING=0; container_running && WAS_RUNNING=1
  SHOULD_START=$((WAS_RUNNING || start))
  data_mp=$(volume_mountpoint "$DATA_VOLUME")
  le_mp=$(volume_mountpoint "$LE_VOLUME")
  ROLLBACK=$(mktemp -d "$REPO_ROOT/.state/restore-rollback.XXXXXX"); chmod 700 "$ROLLBACK"
  if ((WAS_RUNNING)); then
    "$p" stop "$CONTAINER_NAME" >/dev/null
    MAIN_STOPPED=1
  fi
  snapshot_bytes=$(($(du -sb --apparent-size "$data_mp" | awk '{print $1}') + $(du -sb --apparent-size "$le_mp" | awk '{print $1}') + 64 * 1024 * 1024))
  require_free_bytes "$ROLLBACK" "$snapshot_bytes" 'rollback snapshots'
  "$p" unshare tar -C "$data_mp" --numeric-owner -cf "$ROLLBACK/data.tar" .
  "$p" unshare tar -C "$le_mp" --numeric-owner -cf "$ROLLBACK/letsencrypt.tar" .

  MUTATED=1
  "$p" unshare sh -c 'find "$1" -mindepth 1 -delete' sh "$data_mp"
  "$p" unshare sh -c 'find "$1" -mindepth 1 -delete' sh "$le_mp"
  "$p" unshare tar -C "$STAGE/data" --numeric-owner -cf - . | "$p" unshare tar -C "$data_mp" --numeric-owner -xf -
  "$p" unshare tar -C "$STAGE/letsencrypt" --numeric-owner -cf - . | "$p" unshare tar -C "$le_mp" --numeric-owner -xf -
  if ((SHOULD_START)); then
    run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null
    wait_healthy; wait_http_ready; reconcile_credentials
    "$REPO_ROOT/scripts/verify.sh" --from-deploy
  fi
  COMMITTED=1
  log 'restore: complete'
}
main "$@"
