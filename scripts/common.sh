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
#
# The container name is anchored on whitespace-or-end, not on `\b`. A word boundary sits
# between "npm-app" and the "-" of "npm-app-legacy-20260915", so `\bnpm-app\b` matched the
# RENAMED rollback copy (and any other npm-app-* container) as well - see tests/host-tree.sh,
# which pins both the positive and the negative case.
npm_legacy_units() {
  local d=$HOME/.config/systemd/user f
  [[ -d $d ]] || return 0
  for f in "$d"/*.service; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$NPM_UNIT" ]] && continue
    if grep -qE '^[[:space:]]*Exec(Start|StartPre|Stop)=.*[[:space:]](start|stop|run|restart)[[:space:]].*[[:space:]]npm-app([[:space:]]|$)' "$f" \
      || grep -qE '^[[:space:]]*Exec(Start|Stop)=.*[[:space:]]--name[= ]npm-app([[:space:]]|$)' "$f"; then
      printf '%s\n' "${f##*/}"
    fi
  done
}

# ---- the host-tree guard -------------------------------------------------------------------
# This package adopts two shapes of legacy npm-app: the compose-era one (a podman-compose
# project, with com.docker.compose.* labels) and a hand-made `podman run`. woowtechopenclaw
# has neither. There, npm-app is started by `nginx-proxy-manager.service`, whose ExecStart is
# `%h/Woow_podman_nginxpm/scripts/deploy.sh` in a hand-copied, non-git tree of a DIFFERENT
# lineage; the literal string "npm-app" never appears in the unit, and the container carries
# no PODMAN_SYSTEMD_UNIT label because podman-compose made it. Both discovery paths therefore
# came up empty, the banner said "units: (none; started by hand)", and the migration ran to
# completion WITHOUT stopping or disabling that unit or its healthcheck timer - so the next
# boot (or the next timer tick) re-ran deploy.sh and recreated npm-app against the Quadlet
# container's ports 80/443 and both volumes. That is what this guard refuses.
#
# The second half of the same mismatch is the third network: openclaw's npm-app is on
# npm-network + odoo18-network + pi-agent, and the unit carries only npm.network (+ pi-agent
# via the fragment). `nets` was read but never acted on, so after the cutover NPM lost DNS for
# odoo18-web:8069 - silently, because nginx resolves upstreams at config load.

# NPM_OWN_NETWORKS: the networks the Quadlet unit reproduces. npm-network comes from
# quadlet/npm.network (NetworkName=), pi-agent from quadlet/fragments/pi-web-front.conf.
# shellcheck disable=SC2034
NPM_OWN_NETWORKS='npm-network pi-agent'

# npm_exec_paths <unit file>: the program of every Exec*= line, one per line, with systemd's
# `-@+!:` prefixes stripped and %h expanded. A unit that runs a shell wrapper is named by
# that wrapper, which is exactly what locates the tree it lives in.
npm_exec_paths() {
  local line p
  while IFS= read -r line; do
    p=${line%%[[:space:]]*}
    # systemd allows any number of "-@+!:" before the program; strip them one at a time
    # rather than with a pattern, because "-" and ":" also occur inside real paths.
    while [[ $p == [-@+!:]* ]]; do p=${p#?}; done
    p=${p//%h/$HOME}
    if [[ $p == /* ]]; then printf '%s\n' "$p"; fi
  done < <(sed -n 's/^[[:space:]]*Exec[A-Za-z]*=//p' "$1")
  return 0
}

# npm_deploy_tree <path>: the nearest ancestor directory of <path> that looks like a
# pre-Quadlet deployment tree (it has .deployed-commit, or scripts/deploy.sh and no
# scripts/lib/quadlet-lib.sh). Prints nothing when there is none.
npm_deploy_tree() {
  local d=${1%/*}
  while [[ -n $d && $d != / ]]; do
    if [[ -f $d/.deployed-commit ]] || { [[ -f $d/scripts/deploy.sh && ! -f $d/scripts/lib/quadlet-lib.sh ]]; }; then
      printf '%s\n' "$d"
      return 0
    fi
    d=${d%/*}
  done
  return 0
}

# npm_deploy_tree_units: "<unit> <tree>" for every user .service/.timer whose Exec* program
# lies inside such a tree. These are the units that keep a foreign deployment alive.
npm_deploy_tree_units() {
  local d=$HOME/.config/systemd/user f p tree
  [[ -d $d ]] || return 0
  for f in "$d"/*.service "$d"/*.timer; do
    [[ -f $f ]] || continue
    [[ ${f##*/} == "$NPM_UNIT" ]] && continue
    while IFS= read -r p; do
      tree=$(npm_deploy_tree "$p")
      if [[ -n $tree ]]; then
        printf '%s %s\n' "${f##*/}" "$tree"
        break
      fi
    done < <(npm_exec_paths "$f")
  done
  return 0
}

# npm_network_peers <network>: the other containers attached to <network>, space separated.
# Best effort: it is used to name what NPM proxies across a network the unit does not join,
# so an empty answer only makes the refusal less specific, never wrong.
npm_network_peers() {
  podman ps --filter "network=$1" --format '{{.Names}}' 2>/dev/null \
    | grep -vx "$NPM_CONTAINER" | tr '\n' ' ' | sed 's/ $//'
  return 0
}

# npm_host_tree_check <legacy unit count> <networks>: refuse a migration whose live npm-app
# does not match what this package's lineage assumes. Refusals, never warnings - both cases
# leave a working NPM broken in a way that shows up hours later, at the next boot or the next
# certificate renewal.
npm_host_tree_check() {
  local nunits=${1:?usage: npm_host_tree_check <legacy unit count> <networks>} nets=${2-}
  local -a foreign=() extra=()
  local u tree n peers lineage

  lineage="this host's npm-app was deployed by a different lineage; migrate-legacy.sh only adopts the compose-era/hand-made shapes"

  if ((nunits == 0)); then
    while read -r u tree; do [[ -n $u ]] && foreign+=("$u ($tree)"); done < <(npm_deploy_tree_units)
    if ((${#foreign[@]})); then
      ql_die "$lineage. No unit was found that starts or stops npm-app, yet these user units run programs out of a pre-Quadlet deployment tree: ${foreign[*]}. Migrating now would leave them enabled: the next boot or timer tick re-runs that tree's scripts/deploy.sh and recreates npm-app against the Quadlet container's ports and volumes. Retire those units and their tree first (do NOT delete the tree - they execute scripts from it)"
    fi
  fi

  for n in $nets; do
    case " $NPM_OWN_NETWORKS " in
      *" $n "*) continue ;;
    esac
    peers=$(npm_network_peers "$n")
    extra+=("$n${peers:+ (NPM reaches ${peers} across it)}")
  done
  if ((${#extra[@]})); then
    ql_die "$lineage. npm-app is attached to ${#extra[@]} network(s) the Quadlet unit does not join: ${extra[*]}. quadlet/npm-app.container joins npm.network only (plus pi-agent through fragments/pi-web-front.conf), so after the cutover NPM would lose DNS for every upstream on those networks - silently, because nginx resolves upstream names at config load. Add the network to quadlet/ (a fragment like fragments/pi-web-front.conf) before migrating this host"
  fi
  return 0
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
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
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
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
