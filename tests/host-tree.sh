#!/usr/bin/env bash
# tests/host-tree.sh: pins the guard that refuses a migration whose live npm-app does not have
# the shape this package adopts (scripts/common.sh, "the host-tree guard"), and the lineage
# guard that refuses to run out of a host's pre-Quadlet deployment tree.
#
# The host being modelled is woowtechopenclaw, where every assumption migrate-legacy.sh makes
# is false at once:
#   - npm-app is started by nginx-proxy-manager.service, whose ExecStart is a deploy.sh in a
#     hand-copied non-git tree; the string "npm-app" never appears in that unit and the
#     container carries no PODMAN_SYSTEMD_UNIT label, so unit discovery came up EMPTY and the
#     migration ran to completion leaving that unit and its healthcheck timer enabled
#   - npm-app is on three networks (npm-network, odoo18-network, pi-agent); the Quadlet unit
#     joins two, and the third was read into a variable and then dropped
#   - the directory has the same NAME as this repo, so `cd ~/Woow_podman_nginxpm &&
#     scripts/migrate-legacy.sh` used to die with a bare "No such file or directory"
#
# Nothing here touches the real HOME, the user manager or podman: each case runs with its own
# HOME and a podman stub on PATH.
#
#   tests/host-tree.sh [filter]
#
# Every case runs in its own subshell (own HOME, own PATH), so:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/npm-host-tree.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
filter=${1:-}
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }

# case <name> <body...>
case_() {
  local name=$1
  shift
  if [[ -n $filter && $name != *"$filter"* ]]; then return 0; fi
  local out
  if out=$( ("$@") 2>&1); then
    npass=$((npass + 1))
    printf 'ok   %s\n' "$name"
  else
    nfail=$((nfail + 1))
    FAILED+=("$name")
    printf 'FAIL %s\n%s\n' "$name" "$out"
  fi
}

# ---- fixtures ---------------------------------------------------------------------------
# mk_home: an isolated HOME with ~/.config/systemd/user, exported. Echoes the path.
mk_home() {
  local h
  h=$(mktemp -d "$ROOT/home.XXXXXX")
  mkdir -p "$h/.config/systemd/user"
  printf '%s' "$h"
}

# mk_deploy_tree <home> [name]: openclaw's pre-Quadlet NPM tree - a directory with the same
# name as this repo, a .deployed-commit stamp, scripts/deploy.sh, and a scripts/lib that
# holds the OLD helpers rather than quadlet-lib.sh.
mk_deploy_tree() {
  local h=$1 name=${2:-Woow_podman_nginxpm} t
  t=$h/$name
  mkdir -p "$t/scripts/lib" "$t/systemd"
  printf '0123456789abcdef0123456789abcdef01234567\n' >"$t/.deployed-commit"
  printf '#!/usr/bin/env bash\necho deploy\n' >"$t/scripts/deploy.sh"
  chmod +x "$t/scripts/deploy.sh"
  : >"$t/scripts/lib/npm_api.py"
  : >"$t/scripts/lib/check_empty_db.py"
  : >"$t/scripts/lib/common.sh"
  printf '%s' "$t"
}

# mk_unit <home> <name> <content>
mk_unit() { printf '%s\n' "$3" >"$1/.config/systemd/user/$2"; }

# mk_podman <home> <network:containers>...: a podman stub that answers
# `podman ps --filter network=<net> --format {{.Names}}`. Echoes the bin dir.
mk_podman() {
  local h=$1 bin=$1/bin spec
  shift
  mkdir -p "$bin"
  # The stub's body is deliberately unexpanded here: it is bash source, not this shell's.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf 'net=""\nfor a in "$@"; do case $a in network=*) net=${a#network=} ;; esac; done\n'
    printf 'case $net in\n'
    for spec in "$@"; do
      printf '  %s) printf "%%s\\n" %s ;;\n' "${spec%%:*}" "${spec#*:}"
    done
    printf '  *) : ;;\nesac\nexit 0\n'
  } >"$bin/podman"
  chmod +x "$bin/podman"
  printf '%s' "$bin"
}

# load: source the lib and common.sh with the current HOME
load() {
  # shellcheck source=../scripts/lib/quadlet-lib.sh
  . "$REPO/scripts/lib/quadlet-lib.sh"
  # shellcheck source=../scripts/common.sh
  . "$REPO/scripts/common.sh"
}

# ---- npm_legacy_units: the container name must not match npm-app-* ------------------------
#
# Each Exec form is pinned by its OWN case. A single case with several Exec lines is a no-op
# control: the two-line compose unit below stayed green while its `podman start npm-app` line
# was undiscovered, because the `stop -t 10` line still matched. A unit discovered by only one
# of its lines is still discovered - the regression hides until a unit has ONLY that form.
#
# one_form <unit name> <single Exec line> <what it is> [expected output]
one_form() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" "$1" "$2"
  load
  eq "$(npm_legacy_units)" "${4-$1}" "$3"
}

t_legacy_units_start_only() {
  one_form container-npm-app.service \
    'ExecStart=/usr/bin/podman start npm-app' 'podman start <name>'
}

t_legacy_units_stop_only() {
  one_form container-npm-app.service \
    'ExecStart=/usr/bin/podman stop npm-app' 'podman stop <name>'
}

t_legacy_units_stop_timeout() {
  one_form container-npm-app.service \
    'ExecStop=/usr/bin/podman stop -t 10 npm-app' 'podman stop -t N <name>'
}

t_legacy_units_restart_only() {
  one_form npm-restart.service \
    'ExecStart=/usr/bin/podman restart npm-app' 'podman restart <name>'
}

t_legacy_units_no_abspath() {
  one_form npm-bare.service \
    'ExecStart=podman start npm-app' 'podman without /usr/bin/'
}

t_legacy_units_quoted_name() {
  one_form npm-quoted.service \
    'ExecStart=/usr/bin/podman start "npm-app"' 'a double-quoted name'
}

t_legacy_units_single_quoted_name() {
  one_form npm-sq.service \
    "ExecStart=/usr/bin/podman stop 'npm-app'" 'a single-quoted name'
}

t_legacy_units_run_equals_name() {
  one_form npm-run-eq.service \
    'ExecStart=/usr/bin/podman run -d --name=npm-app docker.io/jc21/nginx-proxy-manager:2.15.1' \
    '--name=<name>'
}

# the compose-era unit: both forms at once, still one line of output
t_legacy_units_positive() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" container-npm-app.service \
    'ExecStart=/usr/bin/podman start npm-app
ExecStop=/usr/bin/podman stop -t 10 npm-app'
  load
  eq "$(npm_legacy_units)" "container-npm-app.service" "the compose-era unit"
}

# the negative, per form: a suffixed name must not be discovered by ANY of them
t_legacy_units_start_only_suffixed() {
  one_form npm-app-legacy.service \
    'ExecStart=/usr/bin/podman start npm-app-legacy-20260915' \
    'podman start npm-app-legacy-* must not be discovered' ''
}

t_legacy_units_quoted_suffixed() {
  one_form npm-app-legacy.service \
    'ExecStart=/usr/bin/podman start "npm-app-legacy-20260915"' \
    'a quoted npm-app-legacy-* must not be discovered' ''
}

t_legacy_units_run_name() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" npm-manual.service \
    'ExecStart=/usr/bin/podman run --rm --name npm-app docker.io/jc21/nginx-proxy-manager:2.15.1'
  load
  eq "$(npm_legacy_units)" "npm-manual.service" "a hand-made podman run unit"
}

# The rollback copy of a previous migration. `\bnpm-app\b` matched it, because a word boundary
# sits between "npm-app" and the "-" of "-legacy-": discovering it would make the swap stop and
# disable the unit that keeps the ROLLBACK container available.
t_legacy_units_rejects_suffixed_name() {
  HOME=$(mk_home)
  export HOME
  mk_unit "$HOME" npm-app-legacy.service \
    'ExecStart=/usr/bin/podman start npm-app-legacy-20260915
ExecStop=/usr/bin/podman stop npm-app-legacy-20260915'
  mk_unit "$HOME" npm-other.service \
    'ExecStart=/usr/bin/podman run --name npm-app-legacy-20260915 docker.io/jc21/nginx-proxy-manager:2.15.1'
  load
  eq "$(npm_legacy_units)" "" "npm-app-legacy-* must not be discovered as a legacy unit"
}

# ---- the deploy-tree discovery ------------------------------------------------------------
t_deploy_tree_units() {
  HOME=$(mk_home)
  export HOME
  local tree
  tree=$(mk_deploy_tree "$HOME")
  # The three real units, verbatim in shape: a service whose ExecStart is the tree's
  # deploy.sh, and a healthcheck service+timer pair beside it.
  mk_unit "$HOME" nginx-proxy-manager.service \
    "ExecStart=%h/Woow_podman_nginxpm/scripts/deploy.sh
ExecStop=%h/Woow_podman_nginxpm/scripts/remove.sh --keep-data"
  mk_unit "$HOME" nginx-proxy-manager-healthcheck.service \
    "ExecStart=-%h/Woow_podman_nginxpm/scripts/healthcheck.sh"
  mk_unit "$HOME" nginx-proxy-manager-healthcheck.timer 'OnUnitActiveSec=5min'
  mk_unit "$HOME" unrelated.service 'ExecStart=/usr/bin/true'
  load
  local out
  out=$(npm_deploy_tree_units)
  has "$out" "nginx-proxy-manager.service $tree" "the deploy.sh unit"
  has "$out" "nginx-proxy-manager-healthcheck.service $tree" "the healthcheck unit (ExecStart=- prefix)"
  hasnt "$out" "unrelated.service" "a unit outside the tree"
}

# A path that contains "-" must still resolve: the executable-prefix strip is per character.
t_deploy_tree_dashed_path() {
  HOME=$(mk_home)
  export HOME
  local tree
  tree=$(mk_deploy_tree "$HOME" "nginx-proxy-manager-deploy")
  mk_unit "$HOME" npm-deploy.service "ExecStart=-$tree/scripts/deploy.sh --yes"
  load
  eq "$(npm_deploy_tree_units)" "npm-deploy.service $tree" "a tree whose path contains dashes"
}

# ---- npm_host_tree_check ------------------------------------------------------------------
t_check_refuses_zero_units_with_deploy_tree() {
  HOME=$(mk_home)
  export HOME
  local tree
  tree=$(mk_deploy_tree "$HOME")
  mk_unit "$HOME" nginx-proxy-manager.service "ExecStart=$tree/scripts/deploy.sh"
  mk_unit "$HOME" nginx-proxy-manager-healthcheck.timer "OnUnitActiveSec=5min"
  mk_unit "$HOME" nginx-proxy-manager-healthcheck.service "ExecStart=$tree/scripts/healthcheck.sh"
  load
  local out rc=0
  out=$( (npm_host_tree_check 0 "npm-network pi-agent ") 2>&1) || rc=$?
  eq "$rc" 1 "npm_host_tree_check must die"
  has "$out" "this host's npm-app was deployed by a different lineage" "the lineage sentence"
  has "$out" "migrate-legacy.sh only adopts the compose-era/hand-made shapes" "the lineage sentence"
  has "$out" "nginx-proxy-manager.service ($tree)" "the unit and its tree"
  has "$out" "nginx-proxy-manager-healthcheck.service ($tree)" "the healthcheck unit"
  has "$out" "do NOT delete the tree" "the do-not-delete warning"
}

# Discovery worked (a compose-era unit was found): no refusal on that ground.
t_check_allows_when_units_found() {
  HOME=$(mk_home)
  export HOME
  local tree
  tree=$(mk_deploy_tree "$HOME")
  mk_unit "$HOME" nginx-proxy-manager.service "ExecStart=$tree/scripts/deploy.sh"
  load
  npm_host_tree_check 1 "npm-network pi-agent " || die_t "must not refuse when a legacy unit was discovered"
}

t_check_allows_own_networks() {
  HOME=$(mk_home)
  export HOME
  load
  npm_host_tree_check 1 "npm-network " || die_t "npm-network alone must pass"
  npm_host_tree_check 1 "npm-network pi-agent " || die_t "npm-network + pi-agent must pass"
}

t_check_refuses_third_network() {
  HOME=$(mk_home)
  export HOME
  local bin
  bin=$(mk_podman "$HOME" "odoo18-network:odoo18-web odoo18-db npm-app")
  PATH=$bin:$PATH
  export PATH
  load
  local out rc=0
  out=$( (npm_host_tree_check 1 "npm-network odoo18-network pi-agent ") 2>&1) || rc=$?
  eq "$rc" 1 "a third network must be refused"
  has "$out" "this host's npm-app was deployed by a different lineage" "the lineage sentence"
  has "$out" "odoo18-network" "the extra network is named"
  has "$out" "odoo18-web" "the containers reached across it are named"
  hasnt "$out" "(NPM reaches odoo18-web odoo18-db npm-app" "npm-app itself must not be listed as a peer"
}

# ---- ql_require_own_lineage ---------------------------------------------------------------
t_lineage_accepts_this_repo() {
  load
  ql_require_own_lineage "$REPO" WOOWTECH/Woow_podman_nginxpm \
    || die_t "this checkout must pass its own lineage check"
}

# archive/pre-quadlet-deployment/tree is the rescued copy of the host tree: it carries the
# same .deployed-commit stamp, so it is the honest fixture for "not this lineage".
t_lineage_refuses_archived_host_tree() {
  load
  local arch=$REPO/archive/pre-quadlet-deployment/tree out rc=0
  [[ -f $arch/.deployed-commit ]] || die_t "fixture gone: $arch/.deployed-commit"
  out=$( (ql_require_own_lineage "$arch" WOOWTECH/Woow_podman_nginxpm) 2>&1) || rc=$?
  eq "$rc" 1 "the archived host tree must be refused"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
  has "$out" "run from a fresh clone of WOOWTECH/Woow_podman_nginxpm" "the instruction"
  has "$out" "do not delete this tree" "the do-not-delete warning"
}

t_lineage_refuses_deploy_sh_tree() {
  HOME=$(mk_home)
  export HOME
  local tree out rc=0
  tree=$(mk_deploy_tree "$HOME")
  rm -f "$tree/.deployed-commit" # only the deploy.sh marker is left
  load
  out=$( (ql_require_own_lineage "$tree" WOOWTECH/Woow_podman_nginxpm) 2>&1) || rc=$?
  eq "$rc" 1 "scripts/deploy.sh without quadlet-lib.sh must be refused"
  has "$out" "scripts/deploy.sh and no scripts/lib/quadlet-lib.sh" "which marker fired"
}

# ---- running the script itself out of the host tree ---------------------------------------
# The whole point: this used to be `line 49: .../quadlet-lib.sh: No such file or directory`.
t_script_run_from_host_tree() {
  HOME=$(mk_home)
  export HOME
  local tree out rc=0
  tree=$(mk_deploy_tree "$HOME")
  cp "$REPO/scripts/migrate-legacy.sh" "$tree/scripts/migrate-legacy.sh"
  chmod +x "$tree/scripts/migrate-legacy.sh"
  out=$( (bash "$tree/scripts/migrate-legacy.sh" --status) 2>&1) || rc=$?
  eq "$rc" 1 "migrate-legacy.sh must refuse to run out of the host tree"
  hasnt "$out" "No such file or directory" "the bare ENOENT must be gone"
  has "$out" "no scripts/lib/quadlet-lib.sh under $tree" "which directory"
  has "$out" "pre-Quadlet deployment tree" "the diagnosis"
  has "$out" "do not delete that tree" "the do-not-delete warning"
}

case_ legacy-units-start-only t_legacy_units_start_only
case_ legacy-units-stop-only t_legacy_units_stop_only
case_ legacy-units-stop-timeout t_legacy_units_stop_timeout
case_ legacy-units-restart-only t_legacy_units_restart_only
case_ legacy-units-no-abspath t_legacy_units_no_abspath
case_ legacy-units-quoted-name t_legacy_units_quoted_name
case_ legacy-units-single-quoted-name t_legacy_units_single_quoted_name
case_ legacy-units-run-equals-name t_legacy_units_run_equals_name
case_ legacy-units-start-only-suffixed t_legacy_units_start_only_suffixed
case_ legacy-units-quoted-suffixed t_legacy_units_quoted_suffixed
case_ legacy-units-positive t_legacy_units_positive
case_ legacy-units-run-name t_legacy_units_run_name
case_ legacy-units-rejects-suffixed-name t_legacy_units_rejects_suffixed_name
case_ deploy-tree-units t_deploy_tree_units
case_ deploy-tree-dashed-path t_deploy_tree_dashed_path
case_ check-refuses-zero-units-with-deploy-tree t_check_refuses_zero_units_with_deploy_tree
case_ check-allows-when-units-found t_check_allows_when_units_found
case_ check-allows-own-networks t_check_allows_own_networks
case_ check-refuses-third-network t_check_refuses_third_network
case_ lineage-accepts-this-repo t_lineage_accepts_this_repo
case_ lineage-refuses-archived-host-tree t_lineage_refuses_archived_host_tree
case_ lineage-refuses-deploy-sh-tree t_lineage_refuses_deploy_sh_tree
case_ script-run-from-host-tree t_script_run_from_host_tree

printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
