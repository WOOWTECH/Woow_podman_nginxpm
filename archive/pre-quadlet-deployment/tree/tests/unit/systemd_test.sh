#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
main_unit=$(cat "$ROOT/systemd/nginx-proxy-manager.service")
health_unit=$(cat "$ROOT/systemd/nginx-proxy-manager-healthcheck.service")
timer_unit=$(cat "$ROOT/systemd/nginx-proxy-manager-healthcheck.timer")
installer=$(cat "$ROOT/scripts/install-systemd.sh")
for token in 'Type=oneshot' 'RemainAfterExit=yes' 'UMask=0077' 'ExecStart="@REPO_ROOT@/scripts/deploy.sh"' 'ExecStartPost=/usr/bin/systemctl --user start nginx-proxy-manager-healthcheck.timer' 'ExecStop=-/usr/bin/systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' 'ExecStop="@REPO_ROOT@/scripts/remove.sh"' 'After=network-online.target' 'Restart=on-failure' 'RestartSec=30'; do assert_contains "main unit contains $token" "$main_unit" "$token"; done
mapfile -t exec_starts < <(grep '^ExecStart' "$ROOT/systemd/nginx-proxy-manager.service")
[[ ${#exec_starts[@]} -eq 2 && ${exec_starts[0]} == 'ExecStart="@REPO_ROOT@/scripts/deploy.sh"' && ${exec_starts[1]} == 'ExecStartPost=/usr/bin/systemctl --user start nginx-proxy-manager-healthcheck.timer' ]] && ok 'main start gates timer rearm after deploy' || not_ok 'main start gates timer rearm after deploy'
mapfile -t exec_stops < <(grep '^ExecStop=' "$ROOT/systemd/nginx-proxy-manager.service")
[[ ${#exec_stops[@]} -eq 2 && ${exec_stops[0]} == 'ExecStop=-/usr/bin/systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' && ${exec_stops[1]} == 'ExecStop="@REPO_ROOT@/scripts/remove.sh"' ]] && ok 'main stop best-effort disables health units before scoped removal' || not_ok 'main stop best-effort disables health units before scoped removal'
for token in 'Type=oneshot' 'UMask=0077' 'ExecStart="@REPO_ROOT@/scripts/healthcheck.sh"' 'BindsTo=nginx-proxy-manager.service' 'After=nginx-proxy-manager.service' 'TimeoutStartSec=30'; do assert_contains "health unit contains $token" "$health_unit" "$token"; done
for token in 'OnActiveSec=10s' 'OnUnitActiveSec=10s' 'Unit=nginx-proxy-manager-healthcheck.service' 'WantedBy=timers.target'; do assert_contains "timer contains $token" "$timer_unit" "$token"; done
! grep -Eq '^(Requires|After|PartOf)=.*nginx-proxy-manager\.service' "$ROOT/systemd/nginx-proxy-manager-healthcheck.timer" && ok 'timer has no dependency on the main service' || not_ok 'timer has no dependency on the main service'
[[ $health_unit != *'[Install]'* ]] && ok 'oneshot health service is timer-activated, not directly installable' || not_ok 'oneshot health service is timer-activated, not directly installable'
! grep -Eqi 'sudo|NPM_ADMIN|password|/home/' "$ROOT/systemd/"* && ok 'units embed no elevation, secret, or home assumption' || not_ok 'units embed no elevation, secret, or home assumption'
start_timeout=$(sed -n 's/^TimeoutStartSec=//p' "$ROOT/systemd/nginx-proxy-manager.service")
[[ $start_timeout =~ ^[0-9]+$ && $start_timeout -ge 720 ]] && ok 'systemd start timeout covers nested readiness budgets' || not_ok 'systemd start timeout covers nested readiness budgets'
for token in 'check_versions' 'check_rootless' 'check_low_ports' 'systemctl --user daemon-reload' 'systemctl --user enable nginx-proxy-manager.service nginx-proxy-manager-healthcheck.timer' 'systemctl --user restart nginx-proxy-manager.service' 'mktemp' 'login lingering'; do assert_contains "installer contains $token" "$installer" "$token"; done
! grep -Eq 'systemctl --user (enable|restart|start).*healthcheck\.service' "$ROOT/scripts/install-systemd.sh" && ok 'installer never directly manages health service' || not_ok 'installer never directly manages health service'
! grep -Eq '^  systemctl --user start nginx-proxy-manager-healthcheck\.timer$' "$ROOT/scripts/install-systemd.sh" && ok 'installer relies on the main post-start timer gate' || not_ok 'installer relies on the main post-start timer gate'

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/analyze" "$TMP/analyze-root/scripts"
mkdir -m 700 "$TMP/analyze-runtime"
for script in deploy.sh remove.sh healthcheck.sh; do printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/analyze-root/scripts/$script"; chmod +x "$TMP/analyze-root/scripts/$script"; done
for name in nginx-proxy-manager.service nginx-proxy-manager-healthcheck.service nginx-proxy-manager-healthcheck.timer; do
  sed "s|@REPO_ROOT@|$TMP/analyze-root|g" "$ROOT/systemd/$name" >"$TMP/analyze/$name"
done
if command -v systemd-analyze >/dev/null 2>&1; then
  if XDG_RUNTIME_DIR="$TMP/analyze-runtime" systemd-analyze --user verify "$TMP/analyze/"* >"$TMP/analyze.out" 2>"$TMP/error" && ! grep -Eqi 'ordering cycle' "$TMP/analyze.out" "$TMP/error"; then ok 'rendered user main, health, and timer units have no systemd ordering cycle'; else cat "$TMP/analyze.out" "$TMP/error" >&2; not_ok 'rendered user main, health, and timer units have no systemd ordering cycle'; fi
else echo 'SKIP: systemd-analyze unavailable'; ok 'static no-cycle unit assertions complete'; fi

REPO="$TMP/repo"; BIN="$TMP/bin"; RUNTIME="$TMP/runtime"; CONFIG="$TMP/config"
mkdir -p "$REPO" "$BIN" "$RUNTIME" "$CONFIG"
cp -a "$ROOT/scripts" "$ROOT/systemd" "$ROOT/docker-compose.yml" "$REPO/"
cp "$ROOT/tests/fixtures/env.valid" "$REPO/.env"; chmod 600 "$REPO/.env"
cp "$ROOT/tests/fixtures/lifecycle_podman" "$BIN/podman"
cp "$ROOT/tests/fixtures/lifecycle_compose" "$BIN/podman-compose"
cat >"$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
state=${FAKE_RUNTIME_STATE:?}; events=$state/systemd-events; timer_state=$state/health-timer.state
main=${XDG_CONFIG_HOME:?}/systemd/user/nginx-proxy-manager.service
printf 'systemctl %s\n' "$*" >>"$events"
check_start_gate() {
  mapfile -t starts < <(grep '^ExecStart' "$main")
  [[ ${#starts[@]} -eq 2 ]] || return 41
  [[ ${starts[0]} == ExecStart=\"*/scripts/deploy.sh\" ]] || return 42
  [[ ${starts[1]} == 'ExecStartPost=/usr/bin/systemctl --user start nginx-proxy-manager-healthcheck.timer' ]] || return 43
}
start_main() {
  check_start_gate || return
  if [[ ${FAKE_DEPLOY_FAIL:-0} == 1 ]]; then
    printf 'fake-main-execstart deploy-failed\n' >>"$events"
    return 46
  fi
  printf 'fake-main-execstart deploy-succeeded\n' >>"$events"
  "$0" --user start nginx-proxy-manager-healthcheck.timer
}
case " $* " in
  ' --user restart nginx-proxy-manager.service ')
    mapfile -t stops < <(grep '^ExecStop=' "$main")
    [[ ${#stops[@]} -eq 2 ]] || exit 47
    [[ ${stops[0]} == 'ExecStop=-/usr/bin/systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' ]] || exit 48
    [[ ${stops[1]} == ExecStop=\"*/scripts/remove.sh\" ]] || exit 49
    "$0" --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service || true
    printf 'fake-main-execstop remove\n' >>"$events"
    start_main
    ;;
  ' --user start nginx-proxy-manager.service ')
    start_main
    ;;
  ' --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service ')
    printf 'inactive\n' >"$timer_state"
    ;;
  ' --user start nginx-proxy-manager-healthcheck.timer ')
    [[ ${FAKE_TIMER_START_FAIL:-0} != 1 ]] || exit 50
    printf 'active\n' >"$timer_state"
    ;;
  *' start nginx-proxy-manager-healthcheck.service '*|*' restart nginx-proxy-manager-healthcheck.service '*)
    exit 51
    ;;
esac
SH
cat >"$BIN/loginctl" <<'SH'
#!/usr/bin/env bash
printf 'yes\n'
SH
chmod +x "$BIN/"* "$REPO/scripts/"*.sh
printf '0\n' >"$TMP/low-port"; : >"$RUNTIME/resources"; : >"$RUNTIME/events"; : >"$RUNTIME/systemd-events"; printf 'active\n' >"$RUNTIME/health-timer.state"
if TEST_MODE=1 USER=tester PODMAN_BIN="$BIN/podman" PODMAN_COMPOSE_BIN="$BIN/podman-compose" PROC_LOW_PORT_PATH="$TMP/low-port" FAKE_RUNTIME_STATE="$RUNTIME" XDG_CONFIG_HOME="$CONFIG" PATH="$BIN:$PATH" "$REPO/scripts/install-systemd.sh" >"$TMP/install.out" 2>&1; then ok 'fake installer renders and manages user units'; else cat "$TMP/install.out" >&2; not_ok 'fake installer renders and manages user units'; fi
for name in nginx-proxy-manager.service nginx-proxy-manager-healthcheck.service nginx-proxy-manager-healthcheck.timer; do
  [[ -f $CONFIG/systemd/user/$name && ! -L $CONFIG/systemd/user/$name && $(stat -c %a "$CONFIG/systemd/user/$name") == 600 ]] && ok "installer atomically installs private $name" || not_ok "installer atomically installs private $name"
done
events_are() { printf '%s\n' "$@" | diff -u - "$RUNTIME/systemd-events" >/dev/null; }
if events_are \
  'systemctl --user daemon-reload' \
  'systemctl --user enable nginx-proxy-manager.service nginx-proxy-manager-healthcheck.timer' \
  'systemctl --user restart nginx-proxy-manager.service' \
  'systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' \
  'fake-main-execstop remove' \
  'fake-main-execstart deploy-succeeded' \
  'systemctl --user start nginx-proxy-manager-healthcheck.timer' \
  && [[ $(cat "$RUNTIME/health-timer.state") == active ]]; then ok 'installer restart uses the main post-start timer gate exactly once'; else not_ok 'installer restart uses the main post-start timer gate exactly once'; fi

: >"$RUNTIME/systemd-events"; printf 'active\n' >"$RUNTIME/health-timer.state"
if FAKE_RUNTIME_STATE="$RUNTIME" XDG_CONFIG_HOME="$CONFIG" "$BIN/systemctl" --user restart nginx-proxy-manager.service \
  && events_are \
    'systemctl --user restart nginx-proxy-manager.service' \
    'systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' \
    'fake-main-execstop remove' \
    'fake-main-execstart deploy-succeeded' \
    'systemctl --user start nginx-proxy-manager-healthcheck.timer' \
  && [[ $(cat "$RUNTIME/health-timer.state") == active ]]; then ok 'direct main restart stops, removes, deploys, then rearms timer in exact order'; else not_ok 'direct main restart stops, removes, deploys, then rearms timer in exact order'; fi

: >"$RUNTIME/systemd-events"; printf 'active\n' >"$RUNTIME/health-timer.state"
FAKE_RUNTIME_STATE="$RUNTIME" XDG_CONFIG_HOME="$CONFIG" FAKE_DEPLOY_FAIL=1 "$BIN/systemctl" --user restart nginx-proxy-manager.service; rc=$?
if [[ $rc -ne 0 && $(cat "$RUNTIME/health-timer.state") == inactive ]] && events_are \
  'systemctl --user restart nginx-proxy-manager.service' \
  'systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' \
  'fake-main-execstop remove' \
  'fake-main-execstart deploy-failed'; then ok 'failed restart deploy leaves timer quiescent and never calls rearm'; else not_ok 'failed restart deploy leaves timer quiescent and never calls rearm'; fi

: >"$RUNTIME/systemd-events"; printf 'active\n' >"$RUNTIME/health-timer.state"
FAKE_RUNTIME_STATE="$RUNTIME" XDG_CONFIG_HOME="$CONFIG" FAKE_TIMER_START_FAIL=1 "$BIN/systemctl" --user restart nginx-proxy-manager.service; rc=$?
if [[ $rc -ne 0 && $(cat "$RUNTIME/health-timer.state") == inactive ]] && events_are \
  'systemctl --user restart nginx-proxy-manager.service' \
  'systemctl --user stop nginx-proxy-manager-healthcheck.timer nginx-proxy-manager-healthcheck.service' \
  'fake-main-execstop remove' \
  'fake-main-execstart deploy-succeeded' \
  'systemctl --user start nginx-proxy-manager-healthcheck.timer'; then ok 'timer rearm failure fails the direct main restart'; else not_ok 'timer rearm failure fails the direct main restart'; fi

: >"$RUNTIME/systemd-events"; printf 'inactive\n' >"$RUNTIME/health-timer.state"
if FAKE_RUNTIME_STATE="$RUNTIME" XDG_CONFIG_HOME="$CONFIG" "$BIN/systemctl" --user start nginx-proxy-manager.service \
  && events_are \
    'systemctl --user start nginx-proxy-manager.service' \
    'fake-main-execstart deploy-succeeded' \
    'systemctl --user start nginx-proxy-manager-healthcheck.timer' \
  && [[ $(cat "$RUNTIME/health-timer.state") == active ]]; then ok 'direct main start rearms timer only after deploy succeeds'; else not_ok 'direct main start rearms timer only after deploy succeeds'; fi
! grep -Eq '(start|restart) nginx-proxy-manager-healthcheck\.service' "$RUNTIME/systemd-events" && ok 'main lifecycle never directly starts the health service' || not_ok 'main lifecycle never directly starts the health service'
rendered_health=$(cat "$CONFIG/systemd/user/nginx-proxy-manager-healthcheck.service")
assert_contains 'installed health service uses exact checkout script' "$rendered_health" "ExecStart=\"$REPO/scripts/healthcheck.sh\""
finish
