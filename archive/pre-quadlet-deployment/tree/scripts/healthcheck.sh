#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  [[ $# -eq 0 ]] || { die 'healthcheck.sh takes no arguments'; exit 2; }
  lifecycle_lock
  require_command "$(podman_cmd)"
  check_rootless
  # A periodic probe must never create fresh ownership metadata after a purge.
  [[ -e $REPO_ROOT/.state/owner-id && -e $REPO_ROOT/.state/checkout ]] || {
    die 'ownership state is absent; refusing scheduled healthcheck'
    return 1
  }
  owner_id
  resource_absent container "$CONTAINER_NAME" && {
    die 'owned container is absent; refusing scheduled healthcheck'
    return 1
  }
  require_owned_healthcheck
}
main "$@"
