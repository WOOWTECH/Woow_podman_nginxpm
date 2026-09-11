# shellcheck shell=bash
# scripts/render-args.sh: values computed from ~/.config/npm/npm.env. Sourced by
# scripts/install.sh and tests/dryrun.sh, so CI renders exactly what a host gets.
# render_args <envfile>: QL_ENV is loaded, $REPO is the repo root; sets
# RENDER_ARGS=(KEY=VALUE...). Multi-line values fill whole-line tokens.
render_args() {
  local http https admin extra front p lines='' seen
  ql_assert_match NPM_TZ "$(ql_env_get NPM_TZ)" '[A-Za-z][A-Za-z0-9_+/-]*'
  http=$(ql_env_get NPM_HTTP_PORT)
  https=$(ql_env_get NPM_HTTPS_PORT)
  admin=$(ql_env_get NPM_ADMIN_PORT)
  extra=$(ql_env_get NPM_EXTRA_HTTP_PORTS '')
  front=$(ql_env_get NPM_PI_WEB_FRONT false)
  seen=" "
  for p in "$http" "$https" "$admin" $extra; do
    ql_assert_match "NPM port" "$p" '[1-9][0-9]{0,4}'
    ((p <= 65535)) || ql_die "port $p is out of range"
    [[ $seen != *" $p "* ]] || ql_die "port $p is used twice in $(basename "$1")"
    seen+="$p "
  done
  for p in $extra; do lines+="PublishPort=$p:80"$'\n'; done
  lines=${lines%$'\n'}
  # shellcheck disable=SC2034 # RENDER_ARGS is read by the caller
  case $front in
    true) RENDER_ARGS=("NPM_EXTRA_PUBLISH_LINES=$lines" "NPM_PI_WEB_FRONT_FRAGMENT=$(<"$REPO/quadlet/fragments/pi-web-front.conf")") ;;
    false) RENDER_ARGS=("NPM_EXTRA_PUBLISH_LINES=$lines" "NPM_PI_WEB_FRONT_FRAGMENT=") ;;
    *) ql_die "NPM_PI_WEB_FRONT must be true or false (got '$front')" ;;
  esac
}
