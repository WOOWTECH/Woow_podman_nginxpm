#!/usr/bin/env bash
set -Eeuo pipefail
{ set +x; } 2>/dev/null
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

main() {
  lifecycle_lock
  log 'deploy: validating host and configuration'
  load_config "$REPO_ROOT/.env"
  require_command "$(podman_cmd)"; require_command "$(compose_cmd)"; require_command "$(python_cmd)"; require_command curl; require_command flock
  check_versions; check_rootless; check_low_ports
  owner_id
  render_compose
  check_resource_owner container "$BOOTSTRAP_CONTAINER_NAME"
  check_all_ownership
  recover_bootstrap_transition
  make_credentials

  log 'deploy: pulling reviewed image'
  compose pull
  log 'deploy: starting owned resources'
  compose up -d
  log 'deploy: waiting for health and loopback readiness'
  wait_healthy
  wait_http_ready
  api_helper ready --url "$ADMIN_URL" >/dev/null
  log 'deploy: reconciling administrator credentials'
  reconcile_credentials
  log 'deploy: verifying security invariants'
  "$REPO_ROOT/scripts/verify.sh" --from-deploy
  log 'deploy: complete'
}
main "$@"
