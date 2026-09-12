#!/usr/bin/env bash
# scripts/migrate-legacy.sh: adopt a compose-era or hand-made `npm-app` container in place:
# same volumes, same ports, same networks, now supervised by the Quadlet unit.
#
#   scripts/migrate-legacy.sh [--with-pi-web-front | --without-pi-web-front]
#                             [--keep-env] [--pi-host HOST] [--yes] [--dry-run]
#   scripts/migrate-legacy.sh --rollback [--restore-volumes] [--yes]
#   scripts/migrate-legacy.sh --status
#
# Forward (about one minute of NPM downtime, between steps 4 and 6):
#   1. read the legacy container: port bindings, networks, TZ, volumes, and the user units
#      that start it (its PODMAN_SYSTEMD_UNIT label, and any unit that runs `podman start
#      npm-app`, such as container-npm-app.service)
#   2. write ~/.config/npm/npm.env from that, reporting every value it changes (--keep-env
#      keeps your file and only reports the differences). Joined to the pi-agent network
#      -> NPM_PI_WEB_FRONT=true, unless --with/--without-pi-web-front says otherwise.
#   3. pull the pinned image, record baseline checks, back up (inspect, CreateCommand,
#      legacy unit files, compose directory) into ~/backups/npm-migrate-<timestamp>/
#   4. stop and disable the legacy unit(s), stop the container, export both volumes cold
#   5. rename npm-app -> npm-app-legacy-<date>: kept for rollback, never started again
#   6. scripts/install.sh, then tests/smoke.sh (--pi-host adds the pi route sweep) and a
#      diff against the baseline. A failed install rolls back by itself.
#
# --rollback         stop and remove the Quadlet units (volumes kept), rename the legacy
#                    container back, re-enable and start its unit(s)
# --restore-volumes  with --rollback: also re-import the exports from step 4 (needed only
#                    if the new NPM version migrated the database)
# --status           show what a migration on this host left behind
#
# State: ~/.local/state/woow-quadlet/npm-migrate/state. Nothing is ever deleted: removing
# npm-app-legacy-<date>, the old unit file and the compose network is a manual step after
# the soak period (see the README).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=common.sh
. "$REPO/scripts/common.sh"

MSTATE_DIR=$HOME/.local/state/woow-quadlet/npm-migrate
MSTATE=$MSTATE_DIR/state
mode=forward front_flag='' pi_host='' yes=0 restore_volumes=0 keep_env=0
while (($#)); do
  case $1 in
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --restore-volumes) restore_volumes=1 ;;
    --keep-env) keep_env=1 ;;
    --with-pi-web-front) front_flag=true ;;
    --without-pi-web-front) front_flag=false ;;
    --pi-host) pi_host=${2:?--pi-host needs a hostname}; shift ;;
    --yes) yes=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,32p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry() { [[ ${QL_DRY_RUN:-0} == 1 ]]; }

# state_get KEY: a value from the migration state file
state_get() { sed -n "s/^$1=//p" "$MSTATE" 2>/dev/null | tail -n1; }
state_write() { # state_write KEY=VALUE...
  (umask 077 && mkdir -p "$MSTATE_DIR" && printf '%s\n' "$@" >"$MSTATE.tmp" && mv -f "$MSTATE.tmp" "$MSTATE")
}
confirm() { # confirm <question>
  ((yes)) && return 0
  [[ -t 0 ]] || ql_die "add --yes to run this non-interactively"
  local a
  read -r -p "$1 [y/N] " a
  [[ $a == [yY] || $a == [yY][eE][sS] ]] || ql_die "aborted; nothing was changed"
}
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@" 2>/dev/null || echo 000; }
# checks <admin> <http> <extra...>: functional baseline, compared before/after
checks() {
  local admin=$1 http=$2 p
  shift 2
  printf 'admin_api %s\n' "$(curl -s -m 5 "http://127.0.0.1:$admin/api/" 2>/dev/null | grep -o '"status":"[A-Za-z]*"' || echo none)"
  printf 'http_%s %s\n' "$http" "$(code "http://127.0.0.1:$http/")"
  for p in "$@"; do printf 'http_%s %s\n' "$p" "$(code "http://127.0.0.1:$p/")"; done
}

status() {
  if [[ -f $MSTATE ]]; then sed 's/^/  /' "$MSTATE"; else echo "  no migration state in $MSTATE"; fi
  podman ps -a --filter name='^npm-app' --format '  {{.Names}}  {{.Status}}  {{.Image}}' 2>/dev/null || true
  local u
  for u in $(state_get LEGACY_UNITS); do
    printf '  %s: %s, %s\n' "$u" "$(systemctl --user is-enabled "$u" 2>/dev/null || true)" "$(systemctl --user is-active "$u" 2>/dev/null || true)"
  done
  printf '  %s: %s\n' "$NPM_UNIT" "$(systemctl --user is-active "$NPM_UNIT" 2>/dev/null || true)"
}

rollback() {
  local legacy units bdir v t mp
  legacy=$(state_get LEGACY_NAME)
  units=$(state_get LEGACY_UNITS)
  bdir=$(state_get BACKUP_DIR)
  if [[ -z $legacy ]]; then
    mapfile -t cands < <(podman ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^npm-app-legacy-' || true)
    ((${#cands[@]} == 1)) || ql_die "no migration state and ${#cands[@]} npm-app-legacy-* containers; roll back by hand"
    legacy=${cands[0]}
  fi
  podman container exists "$legacy" >/dev/null 2>&1 || ql_die "legacy container $legacy does not exist"
  ql_warn "rolling back: $NPM_UNIT out, $legacy back as npm-app${units:+ (units: $units)}"
  if dry; then ql_info "[dry-run] would stop $NPM_UNIT, uninstall the Quadlet files, rename $legacy npm-app, start ${units:-the container}"; return 0; fi
  systemctl --user stop "$NPM_UNIT" 2>/dev/null || true
  QL_APP=$NPM_APP ql_uninstall_units "$NPM_APP"
  if podman container exists "$NPM_CONTAINER" >/dev/null 2>&1; then
    [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$NPM_CONTAINER" 2>/dev/null) == "$NPM_UNIT" ]] \
      || ql_die "a container named npm-app exists that is neither the Quadlet one nor $legacy; resolve by hand"
    podman rm -f "$NPM_CONTAINER" >/dev/null
  fi
  if ((restore_volumes)); then
    [[ -n $bdir && -d $bdir ]] || ql_die "--restore-volumes: backup directory '${bdir:-?}' not found"
    for v in "${NPM_VOLUMES[@]}"; do
      t=$(find "$bdir" -maxdepth 1 -name "$v-*.tar" | sort | tail -n1)
      [[ -n $t ]] || ql_die "--restore-volumes: no $v-*.tar in $bdir"
      (cd -- "$bdir" && sha256sum -c --quiet -- "${t##*/}.sha256") || ql_die "checksum mismatch: $t"
      mp=$(podman volume inspect --format '{{.Mountpoint}}' "$v")
      [[ -n $mp && -d $mp && $mp == */volumes/*/_data ]] || ql_die "unexpected mountpoint '$mp' for $v"
      podman unshare find "$mp" -mindepth 1 -delete
      podman volume import "$v" "$t"
      ql_info "re-imported $v from ${t##*/}"
    done
  fi
  podman rename "$legacy" "$NPM_CONTAINER"
  if [[ -n $units ]]; then
    for u in $units; do systemctl --user enable "$u" >/dev/null 2>&1 || ql_warn "could not enable $u"; done
    # shellcheck disable=SC2086 # a space-separated list of unit names
    systemctl --user start $units || ql_warn "starting $units failed; trying podman start"
  fi
  [[ $(podman inspect --format '{{.State.Running}}' "$NPM_CONTAINER" 2>/dev/null) == true ]] || podman start "$NPM_CONTAINER" >/dev/null
  local ap
  ap=$(state_get ADMIN_PORT)
  ql_wait_until 120 "the legacy npm-app admin API" \
    bash -c "curl -s -m 5 http://127.0.0.1:${ap:-81}/api/ | grep -q '\"status\":\"OK\"'" || ql_warn "the legacy admin API does not answer yet"
  if [[ -n $bdir && -f $bdir/checks.before ]]; then
    # shellcheck disable=SC2046 # the extra ports, space separated
    checks "$(state_get ADMIN_PORT)" "$(state_get HTTP_PORT)" $(state_get EXTRA_PORTS) >"$bdir/checks.rollback"
    if diff "$bdir/checks.before" "$bdir/checks.rollback"; then ql_info "checks match the pre-migration baseline"; else ql_warn "checks differ from the baseline (see above)"; fi
  fi
  state_write "PHASE=rolled-back" "LEGACY_NAME=" "LEGACY_UNITS=$units" "BACKUP_DIR=$bdir" \
    "HTTP_PORT=$(state_get HTTP_PORT)" "ADMIN_PORT=$(state_get ADMIN_PORT)" "EXTRA_PORTS=$(state_get EXTRA_PORTS)"
  ql_info "rolled back: npm-app runs from the legacy container again"
}

ql_require_rootless
case $mode in
  status) status; exit 0 ;;
  rollback)
    ql_require_user_systemd
    ql_lock npm-migrate
    confirm "Roll back to the legacy npm-app container?"
    rollback
    exit 0 ;;
esac

# ---- forward -------------------------------------------------------------------------------
ql_preflight 4.4
ql_lock npm-migrate
podman container exists "$NPM_CONTAINER" >/dev/null 2>&1 || ql_die "no container named npm-app: nothing to migrate (on a fresh host run scripts/install.sh)"
label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$NPM_CONTAINER")
[[ $label == "<no value>" ]] && label=''
if [[ $label == "$NPM_UNIT" ]]; then ql_info "npm-app is already managed by $NPM_UNIT; nothing to migrate"; exit 0; fi

# 1. read the legacy container
mapfile -t legacy_units < <({ [[ -n $label ]] && printf '%s\n' "$label"; npm_legacy_units; } | sort -u)
# The derivation and its templates live in common.sh; tests/inspect-templates.sh runs them
# against a captured `podman inspect npm-app`.
npm_ports_derive < <(podman inspect --format "$NPM_FMT_PORTS" "$NPM_CONTAINER")
nets=$(podman inspect --format "$NPM_FMT_NETWORKS" "$NPM_CONTAINER")
tz=$(podman inspect --format "$NPM_FMT_ENV" "$NPM_CONTAINER" | sed -n 's/^TZ=//p' | tail -n1)
front=false
[[ " $nets " == *" pi-agent "* ]] && front=true
[[ -z $front_flag ]] || front=$front_flag  # --with/--without-pi-web-front wins
npm_mounts_check "$front" < <(podman inspect --format "$NPM_FMT_MOUNTS" "$NPM_CONTAINER")
legacy_image=$(podman inspect --format '{{.ImageName}}' "$NPM_CONTAINER")
legacy_id=$(podman inspect --format '{{.Image}}' "$NPM_CONTAINER")
running=$(podman inspect --format '{{.State.Running}}' "$NPM_CONTAINER")
workdir=$(podman inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$NPM_CONTAINER")
[[ $workdir == "<no value>" ]] && workdir=''
new_image=$(npm_image_of "$REPO/quadlet/npm-app.container")

cat >&2 <<EOF
legacy npm-app: image $legacy_image (${legacy_id:0:12}), running=$running
  units:     ${legacy_units[*]:-(none; started by hand)}
  ports:     http $http, https $https, admin $admin (-> 127.0.0.1:$admin), extra ${extra[*]:-none}
  networks:  ${nets}-> npm-network$([[ $front == true ]] && echo " + pi-agent (pi-web front)")
  TZ:        ${tz:-unset (Asia/Taipei)}
  compose:   ${workdir:-none}
EOF
if [[ $(systemctl --user is-enabled podman-restart.service 2>/dev/null || true) == enabled ]]; then
  ql_warn "podman-restart.service is enabled: it starts containers with restart policy 'always' at boot."
  ql_warn "npm-app-legacy-<date> has policy '$(podman inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$NPM_CONTAINER")'; remove it after the soak."
fi

# 2. settings
declare -A want=([NPM_TZ]=${tz:-Asia/Taipei} [NPM_HTTP_PORT]=$http [NPM_HTTPS_PORT]=$https [NPM_ADMIN_PORT]=$admin [NPM_EXTRA_HTTP_PORTS]="${extra[*]}" [NPM_PI_WEB_FRONT]=$front)
if dry; then
  ql_info "[dry-run] ~/.config/npm/npm.env would get:"
  for k in NPM_TZ NPM_HTTP_PORT NPM_HTTPS_PORT NPM_ADMIN_PORT NPM_EXTRA_HTTP_PORTS NPM_PI_WEB_FRONT; do printf '    %s=%s\n' "$k" "${want[$k]}" >&2; done
  ql_info "[dry-run] would pull $new_image, back up, stop ${legacy_units[*]:-npm-app}, rename npm-app, run scripts/install.sh"
  exit 0
fi
confirm "Back up, stop ${legacy_units[*]:-npm-app}, rename npm-app to npm-app-legacy-$(date +%Y%m%d) and install the Quadlet unit (about 1 minute of NPM downtime)?"
ql_env_ensure "$REPO/config/npm.env.example" "$NPM_ENV_FILE"
if ((keep_env)); then
  ql_info "--keep-env: $NPM_ENV_FILE is used as it is; differences from the legacy container:"
  for k in "${!want[@]}"; do
    have=$(npm_env_value "$k")
    [[ $have == "${want[$k]}" ]] || ql_warn "  $k=$have (the legacy container implies ${want[$k]})"
  done
else
  for k in NPM_TZ NPM_HTTP_PORT NPM_HTTPS_PORT NPM_ADMIN_PORT NPM_EXTRA_HTTP_PORTS NPM_PI_WEB_FRONT; do
    have=$(npm_env_value "$k")
    [[ $have == "${want[$k]}" ]] || ql_info "$k: $have -> ${want[$k]}"
    ql_env_set "$NPM_ENV_FILE" "$k" "${want[$k]}"
  done
  ql_info "$NPM_ENV_FILE now matches the legacy container (--keep-env keeps your own values)"
fi

# 3. image, baseline, backup (no downtime yet)
podman image exists "$new_image" >/dev/null 2>&1 || podman pull "$new_image" >/dev/null || ql_die "podman pull $new_image failed; nothing was changed"
new_id=$(podman image inspect --format '{{.Id}}' "$new_image")
if [[ $new_id == "$legacy_id" ]]; then
  ql_info "$new_image is the same image the legacy container runs: no version change"
else
  ql_warn "$new_image (${new_id:0:12}) differs from the legacy image (${legacy_id:0:12}): NPM may migrate its database on first start; a rollback then needs --restore-volumes"
fi
D=$(date +%Y%m%d)
# One directory per attempt: a retry after a rollback on the same day must not collide.
B=$HOME/backups/npm-migrate-$(date +%Y%m%d-%H%M%S)
(umask 077 && mkdir -p "$B")
if [[ $running == true ]]; then
  # shellcheck disable=SC2068 # the extra ports as separate words
  checks "$admin" "$http" ${extra[@]} >"$B/checks.before"
  sed 's/^/  before: /' "$B/checks.before" >&2
fi
(
  umask 077
  podman inspect "$NPM_CONTAINER" >"$B/npm-app.inspect.json"
  podman inspect --format '{{json .Config.CreateCommand}}' "$NPM_CONTAINER" >"$B/npm-app.createcmd.json"
  for u in "${legacy_units[@]}"; do
    f=$HOME/.config/systemd/user/$u
    [[ -f $f ]] && cp -p -- "$f" "$B/"
  done
  if [[ -n $workdir && -d $workdir ]]; then tar -czf "$B/compose-dir.tgz" -C "$(dirname -- "$workdir")" -- "$(basename -- "$workdir")"; fi
)

# 4. downtime starts
ql_info "stopping the legacy npm-app"
for u in "${legacy_units[@]}"; do systemctl --user stop "$u" 2>/dev/null || ql_warn "could not stop $u"; done
podman stop -t 30 "$NPM_CONTAINER" >/dev/null 2>&1 || true
[[ $(podman inspect --format '{{.State.Running}}' "$NPM_CONTAINER") == false ]] || ql_die "npm-app is still running; nothing else was changed. Start the legacy unit again: systemctl --user start ${legacy_units[*]}"
for v in "${NPM_VOLUMES[@]}"; do ql_backup_volume "$v" "$B" >/dev/null; done
for u in "${legacy_units[@]}"; do systemctl --user disable "$u" >/dev/null 2>&1 || ql_warn "could not disable $u"; done
# 5. keep the legacy container for rollback
legacy=npm-app-legacy-$D
i=2
while podman container exists "$legacy" >/dev/null 2>&1; do legacy=npm-app-legacy-$D-$i; i=$((i + 1)); done
podman rename "$NPM_CONTAINER" "$legacy"
state_write "PHASE=switched" "DATE=$D" "LEGACY_NAME=$legacy" "LEGACY_UNITS=${legacy_units[*]}" "BACKUP_DIR=$B" \
  "HTTP_PORT=$http" "ADMIN_PORT=$admin" "EXTRA_PORTS=${extra[*]}"
ql_info "legacy container kept as $legacy"

# 6. install; roll back by itself on failure
if ! bash "$REPO/scripts/install.sh"; then
  ql_warn "install.sh failed; rolling back automatically"
  rollback
  ql_die "migration failed and was rolled back; details above"
fi
smoke_args=()
[[ -n $pi_host ]] && smoke_args=(--pi-host "$pi_host" --pi-port "${extra[0]:-$http}")
bash "$REPO/tests/smoke.sh" "${smoke_args[@]}" || ql_warn "smoke checks failed; roll back with: scripts/migrate-legacy.sh --rollback"
if [[ -f $B/checks.before ]]; then
  # shellcheck disable=SC2068
  checks "$admin" "$http" ${extra[@]} >"$B/checks.after"
  if diff "$B/checks.before" "$B/checks.after" >&2; then ql_info "functional checks match the baseline"; else ql_warn "functional checks differ from the baseline (above)"; fi
fi
state_write "PHASE=migrated" "DATE=$D" "LEGACY_NAME=$legacy" "LEGACY_UNITS=${legacy_units[*]}" "BACKUP_DIR=$B" \
  "HTTP_PORT=$http" "ADMIN_PORT=$admin" "EXTRA_PORTS=${extra[*]}"
cat >&2 <<EOF

Migrated. npm-app now runs from $NPM_UNIT; the admin UI is on 127.0.0.1:$admin only.
  Backup      $B
  Roll back   scripts/migrate-legacy.sh --rollback   (add --restore-volumes if the NPM version changed)
  After the soak period, clean up by hand:
    podman rm $legacy
    rm ~/.config/systemd/user/${legacy_units[0]:-<legacy unit>} && systemctl --user daemon-reload
    podman network rm <the old compose network>   # for example nginx-proxy-manager_default
EOF
