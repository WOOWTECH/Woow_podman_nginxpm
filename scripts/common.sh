# shellcheck shell=bash
# scripts/common.sh: NPM helpers shared by install.sh, upgrade.sh and migrate-legacy.sh.
# Source it after scripts/lib/quadlet-lib.sh.

# shellcheck disable=SC2034 # read by the scripts that source this file
NPM_APP=npm
# shellcheck disable=SC2034
NPM_ENV_FILE=$HOME/.config/npm/npm.env
# shellcheck disable=SC2034
NPM_CONTAINER=npm-app
# shellcheck disable=SC2034
NPM_UNIT=npm-app.service
# shellcheck disable=SC2034
NPM_VOLUMES=(npm-app-data npm-letsencrypt)

# npm_legacy_units: user units in ~/.config/systemd/user that start or stop a container
# named npm-app (the compose-era container-npm-app.service, a generate-systemd unit, ...).
npm_legacy_units() {
  local d=$HOME/.config/systemd/user f
  [[ -d $d ]] || return 0
  for f in "$d"/*.service; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$NPM_UNIT" ]] && continue
    if grep -qE '^[[:space:]]*Exec(Start|StartPre|Stop)=.*[[:space:]](start|stop|run|restart)[[:space:]].*\bnpm-app\b' "$f" \
      || grep -qE '^[[:space:]]*Exec(Start|Stop)=.*[[:space:]]--name[= ]npm-app\b' "$f"; then
      printf '%s\n' "${f##*/}"
    fi
  done
}

# npm_rendered_image <rendered npm-app.container>: its Image= value
npm_image_of() { sed -n 's/^Image=//p' "$1" | tail -n1; }

# ---- reading the legacy container ----------------------------------------------------------
# `podman inspect --format` runs a Go template over podman's own structs, so a field is
# addressed by its Go FIELD name and never by the lowercase JSON tag that `podman inspect`
# prints: define.InspectHostPort is {HostIP, HostPort} although its JSON says "HostIp". An
# unknown field fails the whole template - podman writes an error to stderr and no rows to
# stdout - and a `while read` loop over it then derives nothing at all, silently. Keep these
# templates here: tests/inspect-templates.sh renders them against a captured inspect fixture
# and checks what migrate-legacy.sh derives from them.
# shellcheck disable=SC2016,SC2034 # a Go template, and read by whoever sources this file
NPM_FMT_PORTS='{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}|{{.HostIP}}|{{.HostPort}}{{println}}{{end}}{{end}}'
# shellcheck disable=SC2034
NPM_FMT_MOUNTS='{{range .Mounts}}{{.Type}}|{{.Name}}|{{.Source}}|{{.Destination}}{{println}}{{end}}'
# shellcheck disable=SC2016,SC2034
NPM_FMT_NETWORKS='{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# shellcheck disable=SC2034
NPM_FMT_ENV='{{range .Config.Env}}{{println .}}{{end}}'

# npm_ports_derive: read the NPM_FMT_PORTS rows ("<cport>|<host ip>|<host port>") on stdin
# and set http, https, admin and extra[] in the caller. The main HTTP port is 80 when 80 is
# published, else the first published one; every other 80/tcp binding is an extra. A port
# podman does not report falls back to 80/443/81 with a warning.
npm_ports_derive() {
  http='' https='' admin='' extra=()
  local cport hip hport p
  local -a http_ports=()
  while IFS='|' read -r cport hip hport; do
    [[ -n $hport ]] || continue # podman ends its output with a newline of its own
    case $cport in
      80/tcp) http_ports+=("$hport") ;;
      443/tcp) [[ -n $https ]] || https=$hport ;;
      81/tcp) [[ -n $admin ]] || admin=$hport ;;
      *) ql_warn "legacy publishes $cport on ${hip:-*}:$hport; the unit does not carry that over (add it by hand if needed)" ;;
    esac
  done
  for p in "${http_ports[@]}"; do [[ $p == 80 ]] && http=80; done
  [[ -n $http || ${#http_ports[@]} == 0 ]] || http=${http_ports[0]}
  for p in "${http_ports[@]}"; do [[ $p == "$http" ]] || extra+=("$p"); done
  [[ -n $http ]] || { ql_warn "legacy npm-app publishes no HTTP port; using 80"; http=80; }
  [[ -n $https ]] || { ql_warn "legacy npm-app publishes no HTTPS port; using 443"; https=443; }
  [[ -n $admin ]] || { ql_warn "legacy npm-app publishes no admin port; using 81 (loopback)"; admin=81; }
  return 0
}

# npm_mounts_check <pi-web-front true|false>: read the NPM_FMT_MOUNTS rows
# ("<type>|<name>|<source>|<destination>") on stdin and report every mount the Quadlet unit
# does not carry over. Dies when /data or /etc/letsencrypt is not the volume this package
# adopts, because renaming the container would then point the unit at the wrong data.
npm_mounts_check() {
  local front=$1 mtype mname msrc mdst
  while IFS='|' read -r mtype mname msrc mdst; do
    [[ -n $mdst ]] || continue # podman ends its output with a newline of its own
    case $mdst in
      /data) [[ $mtype == volume && $mname == npm-app-data ]] || ql_die "legacy /data is '$mtype ${mname:-$msrc}', not the npm-app-data volume; this script adopts npm-app-data only" ;;
      /etc/letsencrypt) [[ $mtype == volume && $mname == npm-letsencrypt ]] || ql_die "legacy /etc/letsencrypt is '$mtype ${mname:-$msrc}', not the npm-letsencrypt volume" ;;
      /etc/nginx/conf.d/include/proxy.conf)
        if [[ $front == true ]]; then ql_info "legacy proxy.conf bind ($msrc) is replaced by the pi-web front's copy"
        else ql_warn "legacy mounts $msrc over proxy.conf, but the pi-web front is off: that override will be gone"; fi ;;
      *) ql_warn "legacy mount $mtype ${mname:-$msrc} -> $mdst is not carried over" ;;
    esac
  done
  return 0
}

# npm_env_value <KEY> [default]: a value from npm.env without loading it into QL_ENV
# (used by read-only scripts such as tests/smoke.sh).
npm_env_value() {
  local v
  v=$(sed -n "s/^$1=//p" "$NPM_ENV_FILE" 2>/dev/null | tail -n1)
  printf '%s' "${v:-${2:-}}"
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing
# starts them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a
# renamed, stopped container whose policy is exactly `always` revives and fights the new
# Quadlet container for its name, ports and volumes. podman 4.9.3 cannot defuse that in
# place - `podman update` is cgroup-only, a restart policy is fixed at create time - so the
# answer there is to capture the container and remove it. ql_rollback_strategy asks this
# host (is that unit enabled, what is each container's policy) and answers `rename` or
# `capture`; it never looks at a host name.

# npm_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime:
# a container the library cannot replay (an empty CreateCommand - created through the podman
# API rather than the CLI) is refused here, while the legacy stack is still running.
npm_legacy_capture() {
  local bk=${1:?usage: npm_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# npm_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy
# containers out of the new stack's way, in the shape the strategy asked for.
npm_legacy_retire() {
  local strategy=${1:?} sfx=${2:?} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)" ;;
      capture)
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the
        # capture records and expects to find again.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c" ;;
      *) ql_die "unknown rollback strategy '$strategy'" ;;
    esac
  done
}

# npm_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its
# original restart policy; the caller starts it, exactly as it starts a renamed one.
npm_legacy_restore() {
  local sfx=${1:?} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container $c-legacy-$sfx nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
