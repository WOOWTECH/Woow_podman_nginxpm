# shellcheck shell=bash
# tests/dryrun.local.sh: NPM assertions, sourced at the end of tests/dryrun.sh (the vendored
# template). The generic variants have already rendered their units into $WORK/<variant>/out:
#   example              config/npm.env.example: no pi-web front, no extra ports
#   fixture-toypark1234  pi-web front + extra port 30142
# This adds a variant with pi-agent's network unit present (tests/fixtures/refs/), so the
# optional ordering on pi-agent-network.service is verified against a real unit, then checks
# the podman 4.9.3 generator output of each variant.
# Uses $REPO, $WORK, run_variant and the `failures` counter from tests/dryrun.sh.

run_variant toypark1234+pi-agent "$REPO/tests/fixtures/toypark1234.env" \
  "$REPO"/quadlet/*.container "$REPO"/quadlet/*.volume "$REPO"/quadlet/*.network "$REPO/tests/fixtures/refs/pi-agent.network"

# Where fixture-toypark1234.env comes from: the derivation in scripts/migrate-legacy.sh, run
# against a captured `podman inspect npm-app`. Without it nothing ever executes those Go
# templates and a wrong field name (.HostIp for .HostIP) silently drops a published port.
echo "== inspect templates"
if bash "$REPO/tests/inspect-templates.sh"; then
  echo "ok   inspect-templates"
else
  echo "FAIL inspect-templates"
  failures=$((failures + 1))
fi

# _npm_gen <variant> <unit>: that unit as the Quadlet generator emits it for the variant
_npm_gen() {
  QUADLET_UNIT_DIRS="$WORK/$1/out" "${QL_QUADLET_BIN:-/usr/libexec/podman/quadlet}" -dryrun -user 2>/dev/null |
    awk -v want="---$2---" '$0 == want { on = 1; next } /^---.*---$/ { on = 0 } on'
}
_npm_ok=0
_npm_check() { # _npm_check <label> <command...>
  local label=$1
  shift
  if "$@"; then _npm_ok=$((_npm_ok + 1)); else echo "FAIL $label"; failures=$((failures + 1)); fi
}
_npm_has() { [[ $1 == *"$2"* ]]; }
_npm_hasnt() { [[ $1 != *"$2"* ]]; }
_npm_line() { grep -qxF -- "$2" <<<"$1"; }

for variant in example fixture-toypark1234 toypark1234+pi-agent; do
  unit=$(_npm_gen "$variant" npm-app.service)
  exec_line=$(grep '^ExecStart=' <<<"$unit" || true)
  echo "== invariants: $variant"
  _npm_check "$variant: container name npm-app" _npm_has "$exec_line" '--name=npm-app '
  _npm_check "$variant: own network" _npm_has "$exec_line" '--network=npm-network'
  _npm_check "$variant: HTTP on all interfaces" _npm_has "$exec_line" '--publish 80:80 '
  _npm_check "$variant: HTTPS on all interfaces" _npm_has "$exec_line" '--publish 443:443 '
  _npm_check "$variant: admin on loopback" _npm_has "$exec_line" '--publish 127.0.0.1:81:81 '
  _npm_check "$variant: admin never on all interfaces" _npm_hasnt "$exec_line" '--publish 81:81'
  _npm_check "$variant: admin never on 0.0.0.0" _npm_hasnt "$exec_line" '--publish 0.0.0.0:81'
  _npm_check "$variant: data volume adopted by name" _npm_has "$exec_line" '-v npm-app-data:/data '
  _npm_check "$variant: letsencrypt volume adopted by name" _npm_has "$exec_line" '-v npm-letsencrypt:/etc/letsencrypt '
  _npm_check "$variant: image pinned to 2.15.1" _npm_has "$exec_line" 'docker.io/jc21/nginx-proxy-manager:2.15.1'
  _npm_check "$variant: TZ rendered" _npm_has "$exec_line" '--env TZ=Asia/Taipei'
  _npm_check "$variant: health command" _npm_has "$exec_line" '--health-cmd /usr/bin/check-health'
  _npm_check "$variant: no literal /home" _npm_hasnt "$unit" '/home/'
  _npm_check "$variant: no literal /run/user" _npm_hasnt "$unit" '/run/user/'
  _npm_check "$variant: VolumeName npm-app-data" _npm_has "$(_npm_gen "$variant" npm-app-data-volume.service)" 'podman volume create --ignore'
  _npm_check "$variant: NetworkName npm-network" _npm_has "$(_npm_gen "$variant" npm-network.service)" 'npm-network'
  _npm_check "$variant: never a hard dependency on pi-agent" _npm_hasnt "$unit" 'Requires=pi-agent-network.service'
  case $variant in
    example)
      _npm_check "$variant: no pi-agent network" _npm_hasnt "$exec_line" '--network=pi-agent'
      _npm_check "$variant: no extra port" _npm_hasnt "$exec_line" '--publish 30142:80'
      _npm_check "$variant: stock proxy.conf" _npm_hasnt "$exec_line" 'pi-web-front'
      ;;
    *)
      _npm_check "$variant: second network pi-agent" _npm_has "$exec_line" '--network=npm-network --network=pi-agent '
      _npm_check "$variant: extra port 30142" _npm_has "$exec_line" '--publish 30142:80 '
      _npm_check "$variant: proxy.conf mounted read-write" _npm_has "$exec_line" '-v %h/.config/npm/pi-web-front/proxy.conf:/etc/nginx/conf.d/include/proxy.conf '
      _npm_check "$variant: maps.conf mounted read-write" _npm_has "$exec_line" '-v %h/.config/npm/pi-web-front/maps.conf:/etc/nginx/conf.d/00-woow-pi-web-front.conf '
      _npm_check "$variant: self-healing pi-agent network" _npm_line "$unit" 'ExecStartPre=podman network create --ignore pi-agent'
      _npm_check "$variant: optional ordering Wants=" _npm_line "$unit" 'Wants=pi-agent-network.service'
      _npm_check "$variant: optional ordering After=" _npm_line "$unit" 'After=pi-agent-network.service'
      ;;
  esac
done
echo "invariants: $_npm_ok passed"

# The front's mounts must stay read-write (NPM chowns conf.d at start) and its config must be
# a proxy.conf that only swaps the Host/Origin lines.
_npm_check "fragment: no :ro mount" _npm_hasnt "$(grep '^Volume=' "$REPO/quadlet/fragments/pi-web-front.conf")" ':ro'
# shellcheck disable=SC2016 # nginx variables, matched literally
_npm_check "proxy.conf: Host from the map" grep -qx 'proxy_set_header Host $woow_upstream_host;' "$REPO/config/pi-web-front/proxy.conf"
# shellcheck disable=SC2016
_npm_check "proxy.conf: Origin from the map" grep -qx 'proxy_set_header Origin $woow_upstream_origin;' "$REPO/config/pi-web-front/proxy.conf"
# shellcheck disable=SC2016
_npm_check "maps.conf: keyed on \$server" grep -q '^map $server $woow_upstream_host' "$REPO/config/pi-web-front/maps.conf"
