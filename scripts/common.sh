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

# npm_env_value <KEY> [default]: a value from npm.env without loading it into QL_ENV
# (used by read-only scripts such as tests/smoke.sh).
npm_env_value() {
  local v
  v=$(sed -n "s/^$1=//p" "$NPM_ENV_FILE" 2>/dev/null | tail -n1)
  printf '%s' "${v:-${2:-}}"
}
