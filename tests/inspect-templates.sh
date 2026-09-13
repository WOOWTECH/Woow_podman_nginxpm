#!/usr/bin/env bash
# tests/inspect-templates.sh: run the legacy-container derivation of scripts/migrate-legacy.sh
# against a captured `podman inspect npm-app` instead of a live host. Creates no containers;
# runs in CI (called from tests/dryrun.local.sh) and locally.
#
# What it pins down: `podman inspect --format` is a Go template over podman's structs, so a
# field is addressed by its Go FIELD name and not by the lowercase JSON tag that the same
# command prints - define.InspectHostPort is {HostIP, HostPort} while its JSON says "HostIp".
# A wrong name fails the whole template, podman writes the error to stderr and nothing to
# stdout, and the `while read` loop then derives nothing while the script carries on with its
# defaults. That is how {{.HostIp}} dropped port 30142 (pi-web's only public entry point)
# from a migration that otherwise looked healthy. Reviewing the template cannot catch this,
# so it is executed here: tests/gotmpl.py resolves names from the Go field names.
#
# The fixture is tests/fixtures/npm-app-legacy.inspect.json - the compose-era npm-app of
# toypark1234 in the shape `podman inspect` prints (JSON tags as keys), with the fields that
# podman omits when empty written out (a bind mount's "Name": ""), so that a key missing from
# the fixture means a field podman's struct does not have. What the derivation must produce
# is tests/fixtures/toypark1234.env, the same file tests/dryrun.sh renders the units from.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/common.sh
. "$REPO/scripts/common.sh"
export QL_LOG_PREFIX=inspect-templates

FIXTURE=$REPO/tests/fixtures/npm-app-legacy.inspect.json
EXPECTED=$REPO/tests/fixtures/toypark1234.env
command -v python3 >/dev/null || ql_die "python3 is needed to render the inspect templates"
[[ -f $FIXTURE && -f $EXPECTED ]] || ql_die "missing fixture: $FIXTURE or $EXPECTED"

ok=0 bad=0
pass() { ok=$((ok + 1)); }
fail() { echo "FAIL $*"; bad=$((bad + 1)); }
check() { # check <label> <got> <want>
  if [[ $2 == "$3" ]]; then pass; else fail "$1: expected [$3], got [$2]"; fi
}
# render <template>: what `podman inspect --format <template> npm-app` would print
render() { python3 "$REPO/tests/gotmpl.py" "$FIXTURE" "$1"; }
# refuses <label> <template>: the template must fail the way podman fails it
refuses() {
  local out
  if out=$(render "$2" 2>&1); then
    fail "$1: the template rendered instead of failing: [$out]"
  elif [[ $out != *"can't evaluate field"* ]]; then
    fail "$1: failed, but not with a field error: [$out]"
  else
    pass
  fi
}

# ---- 1. ports, networks, TZ: the whole npm.env migrate-legacy.sh would write ---------------
npm_ports_derive < <(render "$NPM_FMT_PORTS")
nets=$(render "$NPM_FMT_NETWORKS")
tz=$(render "$NPM_FMT_ENV" | sed -n 's/^TZ=//p' | tail -n1)
front=false
[[ " $nets " == *" pi-agent "* ]] && front=true

derived=$(printf 'NPM_TZ=%s\nNPM_HTTP_PORT=%s\nNPM_HTTPS_PORT=%s\nNPM_ADMIN_PORT=%s\nNPM_EXTRA_HTTP_PORTS=%s\nNPM_PI_WEB_FRONT=%s\n' \
  "$tz" "$http" "$https" "$admin" "${extra[*]}" "$front")
if diff -u <(grep -Ev '^(#|$)' "$EXPECTED") <(printf '%s\n' "$derived"); then
  pass
else
  fail "the derived npm.env differs from tests/fixtures/toypark1234.env (above)"
fi
# Spelled out as well, so a failure names the value that moved:
check "HTTP port" "$http" 80
check "HTTPS port" "$https" 443
check "admin port" "$admin" 81
check "extra HTTP ports (pi-web's public entry point)" "${extra[*]}" 30142
check "pi-web front from the pi-agent network" "$front" true
check "TZ" "$tz" Asia/Taipei

# ---- 2. mounts: reported, and no phantom row from podman's trailing newline ----------------
mounts=$(npm_mounts_check true < <(render "$NPM_FMT_MOUNTS") 2>&1)
if [[ $mounts == *"legacy mount bind /etc/localtime -> /etc/localtime is not carried over"* ]]; then pass; else
  fail "a mount the unit drops must be reported: [$mounts]"
fi
if [[ $mounts == *"proxy.conf bind"*"replaced by the pi-web front"* ]]; then pass; else
  fail "the proxy.conf bind must be reported as replaced: [$mounts]"
fi
if [[ $mounts == *"mount  -> "* || $mounts == *"->  is not"* ]]; then
  fail "the blank row podman's trailing newline adds was reported as a mount: [$mounts]"
else pass; fi
check "warnings per mount" "$(grep -c 'is not carried over' <<<"$mounts")" 1

# ---- 3. the field names themselves: what podman refuses, this must refuse ------------------
# .HostIp is the JSON tag of define.InspectHostPort.HostIP: the bug this test exists for.
# shellcheck disable=SC2016 # Go template variables, matched literally
refuses "{{.HostIp}} (the JSON tag)" '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}|{{.HostIp}}|{{.HostPort}}{{println}}{{end}}{{end}}'
# podman wraps --format in an implicit {{range .}}, so $ is the inspect array, not a container.
refuses '{{$.Name}} (the root is the array)' '{{range .Mounts}}{{$.Name}}|{{.Source}}{{println}}{{end}}'
# and a plain typo stays a failure rather than an empty string
refuses "a field that does not exist" '{{.HostConfig.PortBindingz}}'

echo "inspect-templates: $ok passed, $bad failed"
((bad == 0))
