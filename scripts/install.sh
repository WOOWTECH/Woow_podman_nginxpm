#!/usr/bin/env bash
# scripts/install.sh: install or update Nginx Proxy Manager as rootless Quadlet units
# (podman >= 4.4, systemd --user, linger). Idempotent: an unchanged re-run restarts
# nothing. Run it as the account that owns the containers, never with sudo.
#
#   scripts/install.sh [--with-pi-web-front | --without-pi-web-front] [--no-start] [--dry-run]
#
#   --with-pi-web-front     join the pi-agent network and load the Host/Origin rewrite for
#                           pi-web; recorded as NPM_PI_WEB_FRONT=true in ~/.config/npm/npm.env
#   --without-pi-web-front  record NPM_PI_WEB_FRONT=false and remove the front again
#   --no-start              install the units and daemon-reload, but start/restart nothing
#   --dry-run               render + validate + report what would change; touch nothing
#
# A host that runs a compose/manual npm-app today must use scripts/migrate-legacy.sh:
# this script refuses to start while a legacy npm-app container or unit exists.
#
# Order: preflight -> env -> guards -> render -> dry-run -> pull -> install -> apply -> smoke.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"
# shellcheck source=render-args.sh
. "$REPO/scripts/render-args.sh"

APP=$NPM_APP
ENV_FILE=$NPM_ENV_FILE
PODMAN_MIN=4.4
UNITS=(npm-network.service npm-app-data-volume.service npm-letsencrypt-volume.service npm-app.service)
HEALTH_TIMEOUT=300

front='' no_start=0
while (($#)); do
  case $1 in
    --with-pi-web-front) front=true ;;
    --without-pi-web-front) front=false ;;
    --no-start) no_start=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
export QL_APP=$APP
dry() { [[ ${QL_DRY_RUN:-0} == 1 ]]; }

# ---- 1. host preflight ---------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
ql_lock "$APP"

# ---- 2. legacy guards (before anything is written: a host with a legacy npm-app must
#         use scripts/migrate-legacy.sh, which derives the settings from that container) ------------------------------------------------------------------------
# A legacy unit that migrate-legacy.sh disabled stays on disk for rollback; only an enabled
# or running one conflicts.
legacy=()
while IFS= read -r u; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null || [[ $(systemctl --user is-enabled "$u" 2>/dev/null || true) == enabled ]]; then legacy+=("$u"); fi
done < <(npm_legacy_units)
if ((${#legacy[@]})); then
  ql_die "legacy unit(s) ${legacy[*]} manage an npm-app container. Use scripts/migrate-legacy.sh, which stops, renames and keeps them for rollback"
fi
label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$NPM_CONTAINER" 2>/dev/null || true)
if podman container exists "$NPM_CONTAINER" >/dev/null 2>&1 && [[ $label != "$NPM_UNIT" ]]; then
  ql_warn "a container named npm-app exists that this package does not manage; scripts/migrate-legacy.sh adopts it"
fi
ql_check_container_collision "$NPM_CONTAINER" "$NPM_UNIT"

# ---- 3. per-host settings (D2: values come from the env file, never from the repo) --------
ql_env_ensure "$REPO/config/npm.env.example" "$ENV_FILE"
[[ $QL_ENV_CREATED == 1 ]] && ql_info "the defaults (ports 80/443, admin on 127.0.0.1:81, no pi-web front) suit a fresh host; installing now"
src_env=$ENV_FILE
if dry && [[ ! -f $ENV_FILE ]]; then src_env=$REPO/config/npm.env.example; fi
if [[ -n $front ]]; then
  if dry; then ql_info "[dry-run] would set NPM_PI_WEB_FRONT=$front in $ENV_FILE"; else ql_env_set "$ENV_FILE" NPM_PI_WEB_FRONT "$front"; fi
fi
ql_env_load "$src_env"
[[ -z $front ]] || QL_ENV[NPM_PI_WEB_FRONT]=$front
front=$(ql_env_get NPM_PI_WEB_FRONT false)

# ---- 4. render and validate ------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/out"
cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$WORK/src/"
RENDER_ARGS=()
render_args "$src_env"
# Values come from QL_ENV (the env file, plus a --with/--without-pi-web-front override).
ql_render "$WORK/src" - "$REPO/quadlet/render-vars" "$WORK/out" "${RENDER_ARGS[@]}" \
  "NPM_TZ=$(ql_env_get NPM_TZ)" "NPM_HTTP_PORT=$(ql_env_get NPM_HTTP_PORT)" \
  "NPM_HTTPS_PORT=$(ql_env_get NPM_HTTPS_PORT)" "NPM_ADMIN_PORT=$(ql_env_get NPM_ADMIN_PORT)"
if [[ $front == true ]]; then
  mkdir -p "$WORK/out/config/pi-web-front"
  cp -p "$REPO"/config/pi-web-front/proxy.conf "$REPO"/config/pi-web-front/maps.conf "$WORK/out/config/pi-web-front/"
fi
ql_dryrun "$WORK/out" --verify --ref-dir "$HOME/.config/containers/systemd" \
  || ql_die "the rendered units failed the dry-run; nothing was installed"
for f in "$WORK/out"/*.container "$WORK/out"/*.network "$WORK/out"/*.volume; do
  ql_check_unit_shadow "$(ql_unit_for "$f")" "$APP"
done

# ---- 5. host checks: low ports, free ports ---------------------------------------------------
read -ra extra_ports <<<"$(ql_env_get NPM_EXTRA_HTTP_PORTS '')"
ports=("$(ql_env_get NPM_HTTP_PORT)" "$(ql_env_get NPM_HTTPS_PORT)" "${extra_ports[@]}")
lowest=$(printf '%s\n' "${ports[@]}" | sort -n | head -n1)
start=$(cat /proc/sys/net/ipv4/ip_unprivileged_port_start 2>/dev/null || echo 1024)
if ((lowest < start)); then
  ql_warn "rootless podman cannot bind port $lowest: net.ipv4.ip_unprivileged_port_start is $start. An administrator can allow it with:"
  printf "    echo 'net.ipv4.ip_unprivileged_port_start=%s' | sudo tee /etc/sysctl.d/99-rootless-podman-ports.conf && sudo sysctl --system\n" "$lowest" >&2
  ql_die "low ports are not bindable for $(id -un)"
fi
if [[ $(podman container inspect --format '{{.State.Running}}' "$NPM_CONTAINER" 2>/dev/null || true) != true ]]; then
  busy=()
  for p in "${ports[@]}" "$(ql_env_get NPM_ADMIN_PORT)"; do
    if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE ":$p\$"; then busy+=("$p"); fi
  done
  if ((${#busy[@]})); then
    busy_re=$(IFS='|'; printf '%s' "${busy[*]}")
    ql_die "port(s) ${busy[*]} are already in use on this host: ss -tlnp | grep -E ':($busy_re)\$'"
  fi
fi

# ---- 6. image before any unit changes ---------------------------------------------------------
ql_pull_images "$WORK/out"
image=$(npm_image_of "$WORK/out/npm-app.container")
if podman image exists "$image" >/dev/null 2>&1; then
  want_id=$(podman image inspect --format '{{.Id}}' "$image")
  have_id=$(podman container inspect --format '{{.Image}}' "$NPM_CONTAINER" 2>/dev/null || true)
  if [[ -n $have_id && $have_id != "$want_id" ]]; then
    ql_info "npm-app runs image ${have_id:0:12}; $image is ${want_id:0:12}: npm-app will restart"
    ql_mark_changed "$APP" "$NPM_UNIT"
  fi
fi

# ---- 7. install changed files, then start / restart only what changed ------------------------
changed=$(ql_install_files "$WORK/out" "$APP" --prune)
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
# The pi-web front config is read by nginx only at start: a changed file restarts npm-app.
if grep -q '^config/' <<<"$changed"; then ql_mark_changed "$APP" "$NPM_UNIT"; fi
if dry; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start $NPM_UNIT"
  exit 0
fi
ql_apply_units "$APP" "${UNITS[@]}"

# ---- 8. smoke --------------------------------------------------------------------------------
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$NPM_CONTAINER" "$HEALTH_TIMEOUT" \
  || ql_die "npm-app did not become healthy; see: journalctl --user -u $NPM_UNIT -n 100; podman logs --tail 100 npm-app"
bash "$REPO/tests/smoke.sh" || ql_die "tests/smoke.sh failed"
cat >&2 <<EOF

Nginx Proxy Manager is installed and healthy: $image

  Admin UI   http://127.0.0.1:$(ql_env_get NPM_ADMIN_PORT)/  (loopback only: ssh -L $(ql_env_get NPM_ADMIN_PORT):127.0.0.1:$(ql_env_get NPM_ADMIN_PORT) $(id -un)@<host>)
             first login on a fresh volume: admin@example.com / changeme; change it at once
  pi-web     front $([[ $front == true ]] && echo "ON: proxy host Forward Hostname pi-web, port 30141, with an access list" || echo "off (--with-pi-web-front to enable)")
  Logs       journalctl --user -u $NPM_UNIT -f ; podman logs -f npm-app
  Upgrade    git pull && scripts/upgrade.sh
EOF
