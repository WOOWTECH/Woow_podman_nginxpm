#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"
main() {
  local purge=0 yes=0 p
  while (($#)); do case $1 in --purge-data) purge=1;; --yes) yes=1;; *) die "unknown remove option: $1"; exit 2;; esac; shift; done
  ((purge==0 || yes==1)) || { die '--purge-data requires --yes'; exit 2; }
  ((yes==0 || purge==1)) || { die '--yes is valid only with --purge-data'; exit 2; }
  lifecycle_lock
  load_config "$REPO_ROOT/.env"; require_command "$(podman_cmd)"; require_command "$(compose_cmd)"
  check_versions; check_rootless; check_low_ports
  owner_id; render_compose
  check_resource_owner container "$BOOTSTRAP_CONTAINER_NAME"
  check_all_ownership
  recover_bootstrap_transition
  log 'remove: removing owned container and network; preserving data volumes'
  compose down
  if ((purge)); then
    p=$(podman_cmd)
    for volume in "$DATA_VOLUME" "$LE_VOLUME"; do
      if ! resource_absent volume "$volume"; then
        check_resource_owner volume "$volume"
        "$p" volume rm "$volume" >/dev/null
      fi
    done
    rm -f -- "$REPO_ROOT/.secrets/npm-admin.env" "$REPO_ROOT/.state/owner-id" "$REPO_ROOT/.state/checkout"
    log 'remove: owned data and local credentials purged; backups preserved'
  else
    log 'remove: complete; volumes, credentials, state, and backups preserved'
  fi
}
main "$@"
