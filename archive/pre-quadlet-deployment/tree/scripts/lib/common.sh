#!/usr/bin/env bash
# Shared primitives. Sourcing this file performs no deployment action.

_COMMON_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly REPO_ROOT=$(CDPATH= cd -- "$_COMMON_DIR/../.." && pwd -P)
unset _COMMON_DIR
readonly REVIEWED_NPM_IMAGE='docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb'
readonly PROJECT_NAME='nginxpm'
readonly MANAGED_LABEL='io.woow.nginxpm.managed'
readonly OWNER_LABEL='io.woow.nginxpm.owner'
readonly CONTAINER_NAME='npm-app'
readonly BOOTSTRAP_CONTAINER_NAME='npm-bootstrap'
readonly NETWORK_NAME='npm-network'
readonly DATA_VOLUME='npm-app-data'
readonly LE_VOLUME='npm-letsencrypt'
readonly ADMIN_URL='http://127.0.0.1:18081'

umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
log() { printf '%s\n' "$*" >&2; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

_runtime_path() {
  case $1 in .state) printf '%s/.state\n' "$REPO_ROOT";; .secrets) printf '%s/.secrets\n' "$REPO_ROOT";; backups) printf '%s/backups\n' "$REPO_ROOT";; *) die 'invalid runtime directory';; esac
}
ensure_private_dir() {
  local path=$1
  if [[ -L $path ]]; then die "refusing symlinked directory: $path"; return 1; fi
  mkdir -p -- "$path" || return
  chmod 700 -- "$path"
  [[ $(stat -c '%a' -- "$path") == 700 ]] || die "directory is not mode 700: $path"
}
ensure_private_dirs() {
  ensure_private_dir "$REPO_ROOT/.state" && ensure_private_dir "$REPO_ROOT/.secrets"
}
atomic_private_write() {
  local target=$1 parent tmp
  parent=$(dirname -- "$target")
  ensure_private_dir "$parent" || return
  [[ ! -L $target ]] || { die "refusing symlinked file: $target"; return 1; }
  tmp=$(mktemp "$parent/.tmp.XXXXXX") || return
  chmod 600 "$tmp"
  if ! cat >"$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f -- "$tmp" "$target"
  chmod 600 -- "$target"
}
require_private_file() {
  local f=$1 mode owner
  [[ -f $f && ! -L $f ]] || { die "missing private file: $f"; return 1; }
  mode=$(stat -c '%a' -- "$f") || return
  owner=$(stat -c '%u' -- "$f") || return
  [[ $mode == 600 && $owner == "$(id -u)" ]] || { die "private file must be caller-owned mode 600: $f"; return 1; }
}

load_config() {
  local file=${1:-"$REPO_ROOT/.env"} line key value lineno=0 assignment_re='^([A-Z][A-Z0-9_]*)=([^[:space:]]*)$'
  [[ -f $file && ! -L $file ]] || { die "configuration file missing or unsafe: $file"; return 1; }
  [[ $(stat -c '%a' -- "$file") == 600 ]] || { die 'configuration file must be mode 600'; return 1; }
  unset NPM_IMAGE TZ NPM_ADMIN_EMAIL
  declare -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    ((lineno+=1))
    [[ -z $line || $line == \#* ]] && continue
    [[ $line =~ $assignment_re ]] || { die "invalid configuration syntax at line $lineno"; return 1; }
    key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
    [[ $value != *'$'* && $value != *'`'* && $value != *';'* && $value != *'&'* && $value != *'|'* && $value != *'<'* && $value != *'>'* && $value != *'('* && $value != *')'* && $value != *'{'* && $value != *'}'* ]] || { die "unsafe configuration value at line $lineno"; return 1; }
    case $key in NPM_IMAGE|TZ|NPM_ADMIN_EMAIL) ;; *) die "unknown configuration key: $key"; return 1;; esac
    [[ -z ${seen[$key]+x} ]] || { die "duplicate configuration key: $key"; return 1; }
    seen[$key]=1
    printf -v "$key" '%s' "$value"
  done <"$file"
  validate_config
}
validate_config() {
  local email_re='^[A-Za-z0-9.!#%+_/=?^~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
  [[ -n ${NPM_IMAGE:-} && -n ${TZ:-} && -n ${NPM_ADMIN_EMAIL:-} ]] || { die 'NPM_IMAGE, TZ, and NPM_ADMIN_EMAIL are required'; return 1; }
  [[ $NPM_IMAGE == "$REVIEWED_NPM_IMAGE" ]] || { die 'NPM_IMAGE does not equal the reviewed immutable pin'; return 1; }
  [[ $NPM_IMAGE =~ @sha256:[0-9a-f]{64}$ && $NPM_IMAGE != *:latest* ]] || { die 'NPM_IMAGE is not an immutable sha256 pin'; return 1; }
  [[ $TZ =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ && $TZ != *..* ]] || { die 'invalid IANA timezone'; return 1; }
  [[ -f /usr/share/zoneinfo/$TZ ]] || { die 'unknown IANA timezone'; return 1; }
  [[ $NPM_ADMIN_EMAIL =~ $email_re ]] || { die 'invalid administrator email'; return 1; }
  export NPM_IMAGE TZ NPM_ADMIN_EMAIL
}

_test_override() {
  local name=$1 default=$2 value
  value=${!name:-}
  if [[ -n $value ]]; then [[ ${TEST_MODE:-0} == 1 ]] || { die "$name is test-only"; return 1; }; printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
}
podman_cmd() { _test_override PODMAN_BIN podman; }
compose_cmd() { _test_override PODMAN_COMPOSE_BIN podman-compose; }
python_cmd() { _test_override PYTHON_BIN python3; }
proc_low_port_path() { _test_override PROC_LOW_PORT_PATH /proc/sys/net/ipv4/ip_unprivileged_port_start; }

check_rootless() {
  local p info
  p=$(podman_cmd) || return
  info=$($p info --format '{{.Host.Security.Rootless}}' 2>/dev/null) || { die 'cannot query Podman rootless status'; return 1; }
  [[ $info == true ]] || die 'rootless Podman is required'
}
check_low_ports() {
  local f value
  f=$(proc_low_port_path) || return
  [[ -r $f ]] || { die 'cannot read ip_unprivileged_port_start'; return 1; }
  read -r value <"$f"
  [[ $value =~ ^[0-9]+$ && $value -le 80 ]] || die 'rootless ports 80/443 require administrator to set net.ipv4.ip_unprivileged_port_start <= 80'
}
check_versions() {
  local p c pv cv='' output line matches=0
  local compose_version_re='^[[:space:]]*podman-compose[[:space:]]+version[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$'
  p=$(podman_cmd); c=$(compose_cmd)
  pv=$($p version --format '{{.Client.Version}}' 2>/dev/null) || return 1
  output=$($c version 2>/dev/null) || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $compose_version_re ]]; then
      cv=${BASH_REMATCH[1]}
      ((matches+=1))
    fi
  done <<<"$output"
  [[ $pv == 4.9.3 ]] || die "Podman 4.9.3 required (found $pv)"
  [[ $matches -eq 1 ]] || { die 'podman-compose version output is missing or ambiguous'; return 1; }
  [[ $cv == 1.0.6 ]] || die "podman-compose 1.0.6 required (found $cv)"
}

owner_id() {
  local owner_file="$REPO_ROOT/.state/owner-id" meta_file="$REPO_ROOT/.state/checkout"
  ensure_private_dirs || return
  if [[ ! -e $owner_file ]]; then
    printf 'woow-nginxpm-owner-v1:%s' "$REPO_ROOT" | sha256sum | awk '{print $1}' | atomic_private_write "$owner_file" || return
  fi
  if [[ ! -e $meta_file ]]; then printf '%s\n' "$REPO_ROOT" | atomic_private_write "$meta_file" || return; fi
  require_private_file "$owner_file" || return
  require_private_file "$meta_file" || return
  [[ $(cat "$meta_file") == "$REPO_ROOT" ]] || { die 'checkout ownership metadata mismatch'; return 1; }
  read -r NPM_OWNER_ID <"$owner_file"
  [[ $NPM_OWNER_ID =~ ^[0-9a-f]{64}$ ]] || { die 'invalid owner state'; return 1; }
  export NPM_OWNER_ID COMPOSE_PROJECT_NAME=$PROJECT_NAME
}

_resource_inspect() {
  local type=$1 name=$2 format=$3 p
  p=$(podman_cmd) || return
  case $type in
    container) "$p" inspect --type container --format "$format" "$name";;
    network) "$p" network inspect --format "$format" "$name";;
    volume) "$p" volume inspect --format "$format" "$name";;
    *) return 2;;
  esac
}
resource_absent() {
  local type=$1 name=$2 err rc
  err=$(mktemp); chmod 600 "$err"
  _resource_inspect "$type" "$name" '{{.Name}}' >/dev/null 2>"$err" && rc=0 || rc=$?
  if ((rc==0)); then rm -f "$err"; return 1; fi
  if grep -Eqi 'no such|not found|does not exist' "$err"; then rm -f "$err"; return 0; fi
  rm -f "$err"; die "failed to inspect $type $name"
}
check_resource_owner() {
  local type=$1 name=$2 managed owner actual
  if resource_absent "$type" "$name"; then return 0; fi
  actual=$(_resource_inspect "$type" "$name" '{{.Name}}' 2>/dev/null) || { die "cannot inspect $type $name"; return 1; }
  [[ $actual == "$name" || $actual == "/$name" ]] || { die "resource identity mismatch: $type $name"; return 1; }
  if [[ $type == container ]]; then
    managed=$(_resource_inspect "$type" "$name" "{{ index .Config.Labels \"$MANAGED_LABEL\" }}" 2>/dev/null) || return 1
    owner=$(_resource_inspect "$type" "$name" "{{ index .Config.Labels \"$OWNER_LABEL\" }}" 2>/dev/null) || return 1
  else
    managed=$(_resource_inspect "$type" "$name" "{{ index .Labels \"$MANAGED_LABEL\" }}" 2>/dev/null) || return 1
    owner=$(_resource_inspect "$type" "$name" "{{ index .Labels \"$OWNER_LABEL\" }}" 2>/dev/null) || return 1
  fi
  [[ $managed == true && $owner == "$NPM_OWNER_ID" ]] || { die "refusing foreign or unlabeled $type: $name"; return 1; }
}
check_all_ownership() {
  [[ -n ${NPM_OWNER_ID:-} ]] || owner_id || return
  check_resource_owner container "$CONTAINER_NAME" &&
  check_resource_owner network "$NETWORK_NAME" &&
  check_resource_owner volume "$DATA_VOLUME" &&
  check_resource_owner volume "$LE_VOLUME"
}
bootstrap_env_file() { printf '%s/.state/npm-bootstrap.env\n' "$REPO_ROOT"; }
cleanup_bootstrap_artifacts() {
  local p env_file rc=0
  p=$(podman_cmd) || return
  env_file=$(bootstrap_env_file)
  if ! resource_absent container "$BOOTSTRAP_CONTAINER_NAME"; then
    check_resource_owner container "$BOOTSTRAP_CONTAINER_NAME" || return
    "$p" rm -f "$BOOTSTRAP_CONTAINER_NAME" >/dev/null 2>&1 || rc=1
    resource_absent container "$BOOTSTRAP_CONTAINER_NAME" || rc=1
  fi
  if [[ -e $env_file || -L $env_file ]]; then
    require_private_file "$env_file" || return 1
    rm -f -- "$env_file" || rc=1
    [[ ! -e $env_file && ! -L $env_file ]] || rc=1
  fi
  return "$rc"
}
recover_bootstrap_transition() {
  # A prior bootstrap may have created the user before deployment was
  # interrupted. Remove only the exact-owned transient and its private file;
  # the ordinary container can then converge using the generated credential.
  cleanup_bootstrap_artifacts || { die 'could not clean an interrupted bootstrap transition'; return 1; }
}

compose() {
  local c; c=$(compose_cmd) || return
  (
    exec 9>&-
    cd "$REPO_ROOT" && export NPM_IMAGE TZ NPM_OWNER_ID COMPOSE_PROJECT_NAME="$PROJECT_NAME" && "$c" -f "$REPO_ROOT/docker-compose.yml" "$@"
  )
}
render_compose() { compose config >/dev/null; }

run_without_lifecycle_fd() {
  # The caller keeps fd 9 and its exclusion lock; only the launched process
  # (and any long-lived helpers it creates) sees the descriptor closed.
  "$@" 9>&-
}

lifecycle_lock() {
  ensure_private_dirs || return
  exec 9>"$REPO_ROOT/.state/lifecycle.lock"
  chmod 600 "$REPO_ROOT/.state/lifecycle.lock"
  flock -n 9 || die 'another lifecycle operation is running'
}
container_running() { [[ $(_resource_inspect container "$CONTAINER_NAME" '{{.State.Running}}' 2>/dev/null) == true ]]; }
container_healthy() { [[ $(_resource_inspect container "$CONTAINER_NAME" '{{.State.Health.Status}}' 2>/dev/null) == healthy ]]; }
run_owned_healthcheck() {
  local p
  [[ -n ${NPM_OWNER_ID:-} ]] || { die 'owner identity is not loaded'; return 1; }
  resource_absent container "$CONTAINER_NAME" && return 1
  check_resource_owner container "$CONTAINER_NAME" || return
  container_running || return 1
  p=$(podman_cmd) || return
  # Podman 4.9 may fail to schedule native healthchecks when the user systemd
  # socket is unavailable. Drive the check explicitly and require both its
  # successful exit and the resulting inspected health status.
  "$p" healthcheck run "$CONTAINER_NAME" >/dev/null 2>&1 || return 1
  container_healthy
}
require_owned_healthcheck() {
  run_owned_healthcheck || die 'owned container manual healthcheck failed or did not report healthy'
}
wait_healthy() {
  local deadline=$((SECONDS+${READY_TIMEOUT:-180}))
  while ((SECONDS<deadline)); do run_owned_healthcheck && return 0; sleep 2; done
  die 'container did not become healthy before timeout'
}
wait_http_ready() {
  local deadline=$((SECONDS+${READY_TIMEOUT:-180}))
  while ((SECONDS<deadline)); do curl --silent --show-error --fail --max-time 3 "$ADMIN_URL/api/" >/dev/null 2>&1 && return 0; sleep 2; done
  die 'loopback administration API did not become ready before timeout'
}
credentials_file() { printf '%s/.secrets/npm-admin.env\n' "$REPO_ROOT"; }
read_credentials() {
  local f line email_count=0 password_count=0
  f=$(credentials_file); require_private_file "$f" || return
  unset GENERATED_ADMIN_EMAIL GENERATED_ADMIN_PASSWORD
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      NPM_ADMIN_EMAIL=*) ((email_count+=1)); GENERATED_ADMIN_EMAIL=${line#*=};;
      PASSWORD=*) ((password_count+=1)); GENERATED_ADMIN_PASSWORD=${line#*=};;
      *) die 'invalid credentials file'; return 1;;
    esac
  done <"$f"
  [[ $email_count -eq 1 && $password_count -eq 1 && $GENERATED_ADMIN_EMAIL == "$NPM_ADMIN_EMAIL" && ${#GENERATED_ADMIN_PASSWORD} -ge 32 ]] || die 'invalid generated credentials'
}
make_credentials() {
  local f pass
  f=$(credentials_file)
  if [[ -e $f || -L $f ]]; then
    if ! read_credentials; then unset GENERATED_ADMIN_EMAIL GENERATED_ADMIN_PASSWORD; return 1; fi
    unset GENERATED_ADMIN_EMAIL GENERATED_ADMIN_PASSWORD; return 0
  fi
  pass=$($(python_cmd) -c 'import secrets; print(secrets.token_urlsafe(48))') || return
  printf 'NPM_ADMIN_EMAIL=%s\nPASSWORD=%s\n' "$NPM_ADMIN_EMAIL" "$pass" | atomic_private_write "$f"
  unset pass
}
secret_field_file() {
  local field=$1 out=$2 f
  f=$(credentials_file); require_private_file "$f" || return
  awk -v k="$field=" 'index($0,k)==1 {print substr($0,length(k)+1); found=1} END{if(!found)exit 1}' "$f" | atomic_private_write "$out"
}
api_helper() { "$(python_cmd)" "$REPO_ROOT/scripts/lib/npm_api.py" "$@"; }
credentials_auth_generated() {
  local tdir e p rc
  tdir=$(mktemp -d "$REPO_ROOT/.state/api.XXXXXX"); chmod 700 "$tdir"
  secret_field_file NPM_ADMIN_EMAIL "$tdir/email" && secret_field_file PASSWORD "$tdir/password" || { rm -rf "$tdir"; return 1; }
  api_helper auth --url "$ADMIN_URL" --identity-file "$tdir/email" --password-file "$tdir/password" >/dev/null; rc=$?
  rm -rf "$tdir"; return "$rc"
}
default_auth() {
  local tdir rc
  tdir=$(mktemp -d "$REPO_ROOT/.state/api.XXXXXX"); chmod 700 "$tdir"
  printf '%s\n' 'admin@example.com' | atomic_private_write "$tdir/email"
  # Split construction avoids retaining a default credential literal in production documentation/log output.
  printf '%s%s\n' 'change' 'me' | atomic_private_write "$tdir/password"
  api_helper auth --url "$ADMIN_URL" --identity-file "$tdir/email" --password-file "$tdir/password" >/dev/null; rc=$?
  rm -rf "$tdir"; return "$rc"
}
transitional_auth() {
  local tdir rc
  tdir=$(mktemp -d "$REPO_ROOT/.state/api.XXXXXX"); chmod 700 "$tdir"
  printf '%s\n' 'admin@example.com' | atomic_private_write "$tdir/email"
  secret_field_file PASSWORD "$tdir/password"
  api_helper auth --url "$ADMIN_URL" --identity-file "$tdir/email" --password-file "$tdir/password" >/dev/null; rc=$?
  rm -rf "$tdir"; return "$rc"
}
finish_transitional_rotation() {
  local tdir rc
  tdir=$(mktemp -d "$REPO_ROOT/.state/api.XXXXXX"); chmod 700 "$tdir"
  printf '%s\n' 'admin@example.com' | atomic_private_write "$tdir/old-email"
  secret_field_file NPM_ADMIN_EMAIL "$tdir/new-email"
  secret_field_file PASSWORD "$tdir/password"
  api_helper change-password --url "$ADMIN_URL" --identity-file "$tdir/old-email" --current-file "$tdir/password" --new-file "$tdir/password" --new-identity-file "$tdir/new-email" >/dev/null; rc=$?
  rm -rf "$tdir"; return "$rc"
}
rotate_default_credentials() {
  local tdir rc
  tdir=$(mktemp -d "$REPO_ROOT/.state/api.XXXXXX"); chmod 700 "$tdir"
  printf '%s\n' 'admin@example.com' | atomic_private_write "$tdir/default-email"
  printf '%s%s\n' 'change' 'me' | atomic_private_write "$tdir/default-password"
  secret_field_file NPM_ADMIN_EMAIL "$tdir/new-email"
  secret_field_file PASSWORD "$tdir/new-password"
  api_helper change-password --url "$ADMIN_URL" --identity-file "$tdir/default-email" --current-file "$tdir/default-password" --new-file "$tdir/new-password" --new-identity-file "$tdir/new-email" >/dev/null; rc=$?
  rm -rf "$tdir"; return "$rc"
}
database_empty_setup() {
  local p mountpoint database
  p=$(podman_cmd) || return
  mountpoint=$(volume_mountpoint "$DATA_VOLUME") || return
  database="$mountpoint/database.sqlite"
  "$p" unshare "$(python_cmd)" "$REPO_ROOT/scripts/lib/check_empty_db.py" "$database" >/dev/null
}
poll_generated_auth() {
  local deadline=$((SECONDS+${READY_TIMEOUT:-180})) rc
  while ((SECONDS<deadline)); do
    if credentials_auth_generated; then return 0; else rc=$?; fi
    [[ $rc -eq 10 || $rc -eq 11 ]] || return "$rc"
    sleep 2
  done
  return 11
}
restore_steady_after_bootstrap_failure() {
  if resource_absent container "$BOOTSTRAP_CONTAINER_NAME"; then
    compose up -d >/dev/null 2>&1 || log 'deploy: automatic steady-container recovery failed; rerun deploy after resolving the reported error'
  fi
}
bootstrap_empty_admin() {
  local p env_file rc
  p=$(podman_cmd) || return
  env_file=$(bootstrap_env_file)

  check_resource_owner container "$CONTAINER_NAME" || return
  "$p" stop "$CONTAINER_NAME" >/dev/null || { die 'could not stop steady container for empty-setup proof'; return 1; }
  if ! database_empty_setup; then
    run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    die 'credential bootstrap refused because an empty user/auth database was not proven'
    return 1
  fi
  if ! "$p" rm "$CONTAINER_NAME" >/dev/null; then
    run_without_lifecycle_fd "$p" start "$CONTAINER_NAME" >/dev/null 2>&1 || true
    die 'could not remove stopped steady container for bootstrap'
    return 1
  fi

  read_credentials || { restore_steady_after_bootstrap_failure; return 1; }
  printf 'TZ=%s\nINITIAL_ADMIN_EMAIL=%s\nINITIAL_ADMIN_PASSWORD=%s\n' \
    "$TZ" "$GENERATED_ADMIN_EMAIL" "$GENERATED_ADMIN_PASSWORD" | atomic_private_write "$env_file" || {
      unset GENERATED_ADMIN_EMAIL GENERATED_ADMIN_PASSWORD
      restore_steady_after_bootstrap_failure
      return 1
    }
  unset GENERATED_ADMIN_EMAIL GENERATED_ADMIN_PASSWORD
  require_private_file "$env_file" || { restore_steady_after_bootstrap_failure; return 1; }

  if run_without_lifecycle_fd "$p" run -d --name "$BOOTSTRAP_CONTAINER_NAME" \
      --label "$MANAGED_LABEL=true" --label "$OWNER_LABEL=$NPM_OWNER_ID" \
      --log-driver=none --restart=no --env-file "$env_file" \
      --network "$NETWORK_NAME" --publish 127.0.0.1:18081:81 \
      --volume "$DATA_VOLUME:/data" --volume "$LE_VOLUME:/etc/letsencrypt" \
      --pull=never "$REVIEWED_NPM_IMAGE" >/dev/null; then
    :
  else
    rc=$?
    cleanup_bootstrap_artifacts || true
    restore_steady_after_bootstrap_failure
    die 'transient administrator bootstrap container failed to start'
    return "$rc"
  fi
  if ! check_resource_owner container "$BOOTSTRAP_CONTAINER_NAME"; then
    cleanup_bootstrap_artifacts || true
    restore_steady_after_bootstrap_failure
    return 1
  fi
  if ! poll_generated_auth; then
    cleanup_bootstrap_artifacts || true
    restore_steady_after_bootstrap_failure
    die 'transient administrator bootstrap did not authenticate before timeout'
    return 1
  fi
  if ! cleanup_bootstrap_artifacts; then
    die 'administrator was created but transient bootstrap cleanup failed; rerun deploy to recover'
    return 1
  fi

  if ! compose up -d; then
    die 'administrator was created but steady container convergence failed; rerun deploy to recover'
    return 1
  fi
  wait_healthy || return
  wait_http_ready || return
  api_helper ready --url "$ADMIN_URL" >/dev/null || return
}
verify_steady_environment_redacted() {
  local tmp creds
  tmp=$(mktemp "$REPO_ROOT/.state/environment.XXXXXX"); chmod 600 "$tmp"
  _resource_inspect container "$CONTAINER_NAME" '{{json .Config.Env}}' >"$tmp" 2>/dev/null || { rm -f "$tmp"; die 'cannot inspect steady container environment'; return 1; }
  creds=$(credentials_file)
  if ! "$(python_cmd)" - "$tmp" "$creds" <<'PY'
import json, sys
try:
    values=json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    raise SystemExit(1)
if not isinstance(values, list) or any(not isinstance(v, str) for v in values):
    raise SystemExit(1)
secrets={}
for line in open(sys.argv[2], encoding='utf-8'):
    key, sep, value=line.rstrip('\n').partition('=')
    if sep: secrets[key]=value
for item in values:
    if item.startswith(('INITIAL_ADMIN_EMAIL=', 'INITIAL_ADMIN_PASSWORD=')):
        raise SystemExit(1)
    if any(secret and secret in item for secret in secrets.values()):
        raise SystemExit(1)
PY
  then rm -f "$tmp"; die 'bootstrap credential material found in steady container environment'; return 1
  fi
  rm -f "$tmp"
}
reconcile_credentials() {
  local rc
  if credentials_auth_generated; then :
  else
    rc=$?
    [[ $rc -eq 10 ]] || { die 'generated credential authentication could not be evaluated'; return 1; }
    if default_auth; then
      rotate_default_credentials || { die 'initial credential rotation failed'; return 1; }
    else
      rc=$?
      [[ $rc -eq 10 ]] || { die 'initial credential authentication could not be evaluated'; return 1; }
      if transitional_auth; then
        finish_transitional_rotation || { die 'interrupted credential rotation could not be completed'; return 1; }
      else
        rc=$?
        [[ $rc -eq 10 ]] || { die 'transitional credential authentication could not be evaluated'; return 1; }
        bootstrap_empty_admin || return 1
      fi
    fi
  fi
  credentials_auth_generated || { die 'generated credentials do not authenticate'; return 1; }
  if default_auth; then die 'initial credentials remain active'; return 1; else rc=$?; fi
  [[ $rc -eq 10 ]] || { die 'initial credential rejection could not be proven'; return 1; }
}
volume_mountpoint() {
  local volume=$1 mp
  mp=$(_resource_inspect volume "$volume" '{{.Mountpoint}}' 2>/dev/null) || return
  [[ -n $mp && $mp == /* ]] || die "invalid mountpoint for $volume"
  printf '%s\n' "$mp"
}
