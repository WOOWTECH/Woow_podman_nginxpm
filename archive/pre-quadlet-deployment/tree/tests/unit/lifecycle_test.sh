#!/usr/bin/env bash
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
source "$ROOT/tests/testlib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; RUNTIME="$TMP/runtime"; BIN="$TMP/bin"
mkdir -p "$REPO" "$RUNTIME" "$BIN"
cp -a "$ROOT/scripts" "$ROOT/docker-compose.yml" "$REPO/"
cp "$ROOT/tests/fixtures/env.valid" "$REPO/.env"; chmod 600 "$REPO/.env"
cp "$ROOT/tests/fixtures/lifecycle_api.py" "$REPO/scripts/lib/npm_api.py"
cp "$ROOT/tests/fixtures/lifecycle_podman" "$BIN/podman"
cp "$ROOT/tests/fixtures/lifecycle_compose" "$BIN/podman-compose"
cat >"$BIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"${FAKE_RUNTIME_STATE:?}/events"
[[ ${FAKE_CURL_FAIL:-0} != 1 ]]
SH
cat >"$BIN/ss" <<'SH'
#!/usr/bin/env bash
if [[ -f ${FAKE_RUNTIME_STATE:?}/listeners ]]; then cat "$FAKE_RUNTIME_STATE/listeners"; else cat <<'OUT'
LISTEN 0 128 0.0.0.0:80 0.0.0.0:*
LISTEN 0 128 0.0.0.0:443 0.0.0.0:*
LISTEN 0 128 127.0.0.1:18081 0.0.0.0:*
OUT
fi
SH
chmod +x "$BIN"/* "$REPO/scripts"/*.sh "$REPO/scripts/lib"/*.py
printf '0\n' >"$TMP/low-port"
: >"$RUNTIME/resources"; : >"$RUNTIME/events"; : >"$RUNTIME/container.log"
export TEST_MODE=1 PODMAN_BIN="$BIN/podman" PODMAN_COMPOSE_BIN="$BIN/podman-compose" PROC_LOW_PORT_PATH="$TMP/low-port" FAKE_RUNTIME_STATE="$RUNTIME" FAKE_REQUIRE_LIFECYCLE_FD_CLOSED=1 PATH="$BIN:$PATH"
run_entry() { "$REPO/scripts/$1.sh" "${@:2}" >"$TMP/$1.out" 2>&1; }
resource_field() { awk -v t="$1" -v n="$2" -v f="$3" '$1==t&&$2==n {print $f}' "$RUNTIME/resources"; }
set_container_state() {
  awk -v running="$1" -v health="$2" 'BEGIN{OFS=" "} $1=="container"&&$2=="npm-app" {$5=running;$6=health} {print}' "$RUNTIME/resources" >"$RUNTIME/resources.tmp" && mv "$RUNTIME/resources.tmp" "$RUNTIME/resources"
}
set_api_state() { python3 - "$RUNTIME/api.json" "$1" "$2" <<'PY'
import json,sys
with open(sys.argv[1],'w') as f: json.dump({'email':sys.argv[2],'password':sys.argv[3]},f)
PY
}
event_count() { grep -Ec "$1" "$RUNTIME/events" 2>/dev/null || true; }

printf 'volume npm-app-data true foreign x x %s\n' "$RUNTIME/data" >"$RUNTIME/resources"
assert_failure 'deploy behavior rejects a pre-existing foreign resource' run_entry deploy
! grep -q ' pull$' "$RUNTIME/events" && ok 'ownership failure occurs before image pull or mutation' || not_ok 'ownership failure occurs before image pull or mutation'
printf 'container npm-bootstrap true foreign true healthy x\n' >"$RUNTIME/resources"; : >"$RUNTIME/events"
assert_failure 'deploy refuses a foreign bootstrap-name container' run_entry deploy
! grep -q 'podman rm' "$RUNTIME/events" && ok 'foreign bootstrap is never removed' || not_ok 'foreign bootstrap is never removed'
: >"$RUNTIME/resources"; : >"$RUNTIME/events"
assert_success 'deploy succeeds against fake Podman/Compose/API state machines' run_entry deploy
[[ $(resource_field container npm-app 5) == true && $(resource_field container npm-app 6) == healthy ]] && ok 'deploy creates a running healthy owned container' || not_ok 'deploy creates a running healthy owned container'
grep -q '^lifecycle-fd9 closed compose-up$' "$RUNTIME/events" && ok 'deploy compose child sees lifecycle fd 9 closed' || not_ok 'deploy compose child sees lifecycle fd 9 closed'
grep -q '^lifecycle-fd9 closed podman-run$' "$RUNTIME/events" && ok 'bootstrap run child sees lifecycle fd 9 closed' || not_ok 'bootstrap run child sees lifecycle fd 9 closed'
grep -q '^podman healthcheck run npm-app$' "$RUNTIME/events" && ok 'deploy actively runs the exact container healthcheck' || not_ok 'deploy actively runs the exact container healthcheck'
assert_success 'timer entrypoint drives an exact-owned running container' run_entry healthcheck
owner=$(cat "$REPO/.state/owner-id"); checks_before=$(event_count '^podman healthcheck run npm-app$')
sed -i 's/^container npm-app true [^ ]*/container npm-app true foreign/' "$RUNTIME/resources"
assert_failure 'timer entrypoint refuses a foreign container' run_entry healthcheck
[[ $(event_count '^podman healthcheck run npm-app$') -eq $checks_before ]] && ok 'foreign timer target is rejected before healthcheck execution' || not_ok 'foreign timer target is rejected before healthcheck execution'
sed -i "s/^container npm-app true foreign/container npm-app true $owner/" "$RUNTIME/resources"
python3 - "$RUNTIME/api.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v['email']=='operator@example.com' and v['password']!='changeme' else 1)
PY
[[ $? -eq 0 ]] && ok 'deploy behavior establishes generated API credentials' || not_ok 'deploy behavior establishes generated API credentials'
python3 - "$RUNTIME/events" <<'PY'
import sys
v=open(sys.argv[1]).read().splitlines()
def pos(text,start=0): return next(i for i,x in enumerate(v[start:],start) if text in x)
a=pos(' pull'); b=pos(' up -d',a); c=pos('bootstrap-validated',b); d=pos('podman rm -f npm-bootstrap',c); e=pos(' up -d',d); f=pos('podman logs npm-app',e)
raise SystemExit(0 if a<b<c<d<e<f else 1)
PY
[[ $? -eq 0 ]] && ok 'fresh deploy bootstraps, removes transient, converges steady, then verifies' || not_ok 'fresh deploy bootstraps, removes transient, converges steady, then verifies'
run_line=$(grep '^podman run ' "$RUNTIME/events" | head -1)
creds=$(cat "$REPO/.secrets/npm-admin.env")
password=${creds##*PASSWORD=}
[[ $run_line == *'--log-driver=none'* && $run_line == *'--publish 127.0.0.1:18081:81'* && $run_line == *'--network npm-network'* && $run_line == *'npm-app-data:/data'* && $run_line == *'npm-letsencrypt:/etc/letsencrypt'* && $run_line != *"$password"* ]] && ok 'bootstrap uses no-log exact topology and no secret argv' || not_ok 'bootstrap uses no-log exact topology and no secret argv'
[[ -z $(resource_field container npm-bootstrap 2) && ! -e $REPO/.state/npm-bootstrap.env ]] && ok 'fresh bootstrap immediately removes container and env file' || not_ok 'fresh bootstrap immediately removes container and env file'
bootstraps=$(event_count '^bootstrap-validated$')
rotations=$(grep -c '^api change-password$' "$RUNTIME/events")
assert_success 'repeat deploy converges successfully' run_entry deploy
[[ $(event_count '^bootstrap-validated$') -eq $bootstraps && $(grep -c '^api change-password$' "$RUNTIME/events") -eq $rotations ]] && ok 'repeat deploy neither bootstraps nor rotates again' || not_ok 'repeat deploy neither bootstraps nor rotates again'
rm -f "$RUNTIME/launch-held" "$RUNTIME/launch-release"
FAKE_HOLD_LAUNCH=compose-up "$REPO/scripts/deploy.sh" >"$TMP/held-deploy.out" 2>&1 & held_deploy=$!
attempt=0
while ((attempt < 100)) && [[ ! -e $RUNTIME/launch-held ]]; do sleep 0.05; attempt=$((attempt+1)); done
[[ -e $RUNTIME/launch-held ]] && ok 'fake compose launch is held while parent deploy remains alive' || not_ok 'fake compose launch is held while parent deploy remains alive'
pulls=$(event_count ' pull$')
assert_failure 'parent retains lifecycle lock while compose child runs without fd 9' run_entry deploy
[[ $(event_count ' pull$') -eq $pulls ]] && ok 'concurrent deploy is rejected before mutation while launch child runs' || not_ok 'concurrent deploy is rejected before mutation while launch child runs'
touch "$RUNTIME/launch-release"
if wait "$held_deploy"; then ok 'held deploy completes after fake launch is released'; else not_ok 'held deploy completes after fake launch is released'; fi
rm -f "$RUNTIME/launch-held" "$RUNTIME/launch-release"
rm -f "$RUNTIME/failed.pull"; if FAKE_FAIL_ONCE=pull run_entry deploy; then not_ok 'injected pull failure propagates'; else ok 'injected pull failure propagates'; fi
[[ $(resource_field container npm-app 5) == true ]] && ok 'pre-start deploy failure leaves prior running state intact' || not_ok 'pre-start deploy failure leaves prior running state intact'
assert_success 'manual healthcheck succeeds when compose leaves scheduler status starting' env FAKE_CONTAINER_HEALTH=starting bash -c '"$1/scripts/deploy.sh" >"$2" 2>&1' _ "$REPO" "$TMP/manual-health.out"
[[ $(resource_field container npm-app 6) == healthy ]] && ok 'manual healthcheck updates scheduler-stalled status' || not_ok 'manual healthcheck updates scheduler-stalled status'
if READY_TIMEOUT=1 FAKE_CONTAINER_HEALTH=starting FAKE_HEALTHCHECK_FAIL=1 run_entry deploy; then not_ok 'manual healthcheck command failure propagates as timeout'; else ok 'manual healthcheck command failure propagates as timeout'; fi
if READY_TIMEOUT=1 FAKE_CONTAINER_HEALTH=starting FAKE_HEALTHCHECK_STALE=1 run_entry deploy; then not_ok 'successful command without healthy status is rejected'; else ok 'successful command without healthy status is rejected'; fi
assert_success 'deploy recovers after manual healthcheck succeeds' run_entry deploy
if READY_TIMEOUT=1 FAKE_CURL_FAIL=1 run_entry deploy; then not_ok 'deploy readiness timeout propagates'; else ok 'deploy readiness timeout propagates'; fi
assert_success 'deploy recovers after readiness endpoint returns' run_entry deploy
rm -f "$RUNTIME/failed.api-ready"
if FAKE_FAIL_ONCE=api-ready run_entry deploy; then not_ok 'deploy API transport failure propagates'; else ok 'deploy API transport failure propagates'; fi
assert_success 'deploy recovers after API transport failure' run_entry deploy
set_api_state unknown@example.test UnknownPassword-123456789012345678901234567890
assert_failure 'deploy rejects when credentials fail and empty database cannot be proven' run_entry deploy
[[ $(resource_field container npm-app 5) == true ]] && ok 'failed empty proof restores the steady container' || not_ok 'failed empty proof restores the steady container'
python3 - "$RUNTIME/api.json" <<'PY'
import json,sys
with open(sys.argv[1],'w') as f: json.dump({'email':None,'password':None},f)
PY
rm -f "$RUNTIME/failed.bootstrap-rm"
if FAKE_FAIL_ONCE=bootstrap-rm run_entry deploy; then not_ok 'injected post-creation cleanup failure propagates'; else ok 'injected post-creation cleanup failure propagates'; fi
[[ -n $(resource_field container npm-bootstrap 2) && ! -e $REPO/.state/npm-bootstrap.env ]] && ok 'cleanup failure removes private env and leaves labeled transient recoverable' || not_ok 'cleanup failure removes private env and leaves labeled transient recoverable'
assert_success 'rerun removes interrupted transient and converges created administrator' run_entry deploy
[[ -z $(resource_field container npm-bootstrap 2) && $(resource_field container npm-app 5) == true ]] && ok 'transition recovery leaves only running steady container' || not_ok 'transition recovery leaves only running steady container'
set_api_state admin@example.com changeme
rm -f "$RUNTIME/failed.interrupted-rotation"
if FAKE_INTERRUPT_ROTATION_ONCE=1 run_entry deploy; then not_ok 'interruption after password rotation propagates'; else ok 'interruption after password rotation propagates'; fi
python3 - "$RUNTIME/api.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v['email']=='admin@example.com' and v['password']!='changeme' else 1)
PY
[[ $? -eq 0 ]] && ok 'interrupted rotation leaves recoverable password-then-identity state' || not_ok 'interrupted rotation leaves recoverable password-then-identity state'
assert_success 'repeat deploy completes interrupted identity rotation' run_entry deploy

exec 7>"$REPO/.state/lifecycle.lock"; flock -n 7
pulls=$(event_count ' pull$')
assert_failure 'lifecycle lock contention rejects concurrent deploy' run_entry deploy
[[ $(event_count ' pull$') -eq $pulls ]] && ok 'contended lifecycle operation performs no mutation' || not_ok 'contended lifecycle operation performs no mutation'
exec 7>&-

printf '%s\n' 'operator@example.com' >"$RUNTIME/container.log"
assert_failure 'generated administrator email log canary fails verification' run_entry verify
: >"$RUNTIME/container.log"; assert_success 'verification recovers after canary is removed' run_entry verify
if FAKE_STEADY_BOOTSTRAP_ENV=1 run_entry verify; then not_ok 'steady bootstrap environment canary fails verification'; else ok 'steady bootstrap environment canary fails verification'; fi
set_container_state false healthy; assert_failure 'verification rejects a stopped container' run_entry verify
set_container_state true unhealthy
if FAKE_HEALTHCHECK_FAIL=1 run_entry verify; then not_ok 'verification rejects a failing manual healthcheck'; else ok 'verification rejects a failing manual healthcheck'; fi
assert_success 'verification actively recovers stale health through a manual check' run_entry verify
set_container_state true healthy
cat >"$RUNTIME/listeners" <<'OUT'
LISTEN 0 128 0.0.0.0:80 0.0.0.0:*
LISTEN 0 128 0.0.0.0:443 0.0.0.0:*
LISTEN 0 128 0.0.0.0:18081 0.0.0.0:*
OUT
assert_failure 'verification rejects an unsafe administration listener' run_entry verify
rm "$RUNTIME/listeners"
if FAKE_WRONG_MOUNTS=1 run_entry verify; then not_ok 'verification rejects a wrong data mount'; else ok 'verification rejects a wrong data mount'; fi
if FAKE_DEFAULT_AUTH_VALID=1 run_entry verify; then not_ok 'verification rejects still-valid default authentication'; else ok 'verification rejects still-valid default authentication'; fi
rm -f "$RUNTIME/failed.api-auth"
if FAKE_FAIL_ONCE=api-auth run_entry verify; then not_ok 'verification rejects ambiguous API authentication failure'; else ok 'verification rejects ambiguous API authentication failure'; fi
grep -q 'could not be evaluated' "$TMP/verify.out" 2>/dev/null && ok 'API ambiguity is distinguished from credential rejection' || not_ok 'API ambiguity is distinguished from credential rejection'

printf before >"$RUNTIME/data/value"
mkdir -p "$RUNTIME/letsencrypt/archive/example.test" "$RUNTIME/letsencrypt/live/example.test"
printf certificate >"$RUNTIME/letsencrypt/archive/example.test/fullchain1.pem"
ln -s ../../archive/example.test/fullchain1.pem "$RUNTIME/letsencrypt/live/example.test/fullchain.pem"
printf hardlinked >"$RUNTIME/data/hardlink-source"; ln "$RUNTIME/data/hardlink-source" "$RUNTIME/data/hardlink-copy"
mkdir "$TMP/hardlink-backups"
backup_starts=$(event_count '^lifecycle-fd9 closed podman-start$')
assert_failure 'hardlink-bearing backup fails validation before publication' run_entry backup "$TMP/hardlink-backups"
[[ $(find "$TMP/hardlink-backups" -mindepth 1 -print -quit | wc -l) -eq 0 && $(resource_field container npm-app 5) == true ]] && ok 'unsupported hardlinks leave no published set and restore running state' || not_ok 'unsupported hardlinks leave no published set and restore running state'
[[ $(event_count '^lifecycle-fd9 closed podman-start$') -gt $backup_starts ]] && ok 'backup restart child sees lifecycle fd 9 closed' || not_ok 'backup restart child sees lifecycle fd 9 closed'
rm "$RUNTIME/data/hardlink-copy" "$RUNTIME/data/hardlink-source"
mkdir "$TMP/failed-backups"
rm -f "$RUNTIME/failed.unshare"; if FAKE_FAIL_ONCE=unshare run_entry backup "$TMP/failed-backups"; then not_ok 'injected backup copy failure propagates'; else ok 'injected backup copy failure propagates'; fi
[[ $(find "$TMP/failed-backups" -mindepth 1 -print -quit | wc -l) -eq 0 && $(resource_field container npm-app 5) == true ]] && ok 'failed backup cleans set and restores running state' || not_ok 'failed backup cleans set and restores running state'
mkdir "$TMP/restart-failed-backups"; rm -f "$RUNTIME/failed.start"
if FAKE_FAIL_ONCE=start run_entry backup "$TMP/restart-failed-backups"; then not_ok 'injected post-publication restart failure propagates'; else ok 'injected post-publication restart failure propagates'; fi
[[ $(find "$TMP/restart-failed-backups" -mindepth 1 -print -quit | wc -l) -eq 0 ]] && ok 'post-publication failure removes archive manifest and checksum' || not_ok 'post-publication failure removes archive manifest and checksum'
"$BIN/podman" start npm-app >/dev/null
mkdir "$TMP/backups"; assert_success 'backup publishes a complete validated set' run_entry backup "$TMP/backups"
archive=$(find "$TMP/backups" -maxdepth 1 -name 'npm-backup-*.tar.gz' -print)
base=${archive%.tar.gz}
[[ -f $archive && -f $base.manifest && -f $base.sha256 && $(find "$TMP/backups" -mindepth 1 -maxdepth 1 | wc -l) -eq 3 ]] && ok 'archive manifest and checksum publish as one clean set' || not_ok 'archive manifest and checksum publish as one clean set'
owner=$(cat "$REPO/.state/owner-id")
assert_success 'published set passes production validator' python3 "$REPO/scripts/lib/validate_backup.py" "$archive" --image 'docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb' --owner "$owner"
python3 - "$archive" <<'PY'
import sys,tarfile
with tarfile.open(sys.argv[1]) as t:
 m=t.getmember('letsencrypt/live/example.test/fullchain.pem')
 raise SystemExit(0 if m.issym() and m.linkname=='../../archive/example.test/fullchain1.pem' else 1)
PY
[[ $? -eq 0 ]] && ok 'backup preserves letsencrypt certificate symlink semantics' || not_ok 'backup preserves letsencrypt certificate symlink semantics'
python3 - "$RUNTIME/events" <<'PY'
import sys
v=open(sys.argv[1]).read().splitlines(); stops=[i for i,x in enumerate(v) if x=='podman stop npm-app']; starts=[i for i,x in enumerate(v) if x=='podman start npm-app']
raise SystemExit(0 if stops and starts and stops[-1]<starts[-1] else 1)
PY
[[ $? -eq 0 ]] && ok 'backup stop/snapshot/start ordering is observed' || not_ok 'backup stop/snapshot/start ordering is observed'

set_container_state false healthy
mkdir "$TMP/stopped-backups"; before_stops=$(event_count '^podman stop npm-app$'); before_starts=$(event_count '^podman start npm-app$')
assert_success 'backup accepts a previously stopped healthy container' run_entry backup "$TMP/stopped-backups"
[[ $(resource_field container npm-app 5) == false && $(event_count '^podman stop npm-app$') -eq $before_stops && $(event_count '^podman start npm-app$') -eq $before_starts ]] && ok 'backup preserves prior stopped state without stop/start' || not_ok 'backup preserves prior stopped state without stop/start'
sleep 1
assert_success 'repeat backup from stopped state publishes another complete set' run_entry backup "$TMP/stopped-backups"
[[ $(find "$TMP/stopped-backups" -maxdepth 1 -type f | wc -l) -eq 6 && $(resource_field container npm-app 5) == false ]] && ok 'repeated backup converges with two complete sets and remains stopped' || not_ok 'repeated backup converges with two complete sets and remains stopped'
"$BIN/podman" start npm-app >/dev/null

printf after >"$RUNTIME/data/value"
assert_success 'restore succeeds through staged fake runtime flow' run_entry restore "$archive"
[[ $(cat "$RUNTIME/data/value") == before && -L "$RUNTIME/letsencrypt/live/example.test/fullchain.pem" && $(cat "$RUNTIME/letsencrypt/live/example.test/fullchain.pem") == certificate ]] && ok 'restore recovers data and functional certificate symlink' || not_ok 'restore recovers data and functional certificate symlink'
printf stable >"$RUNTIME/data/value"; rm -f "$RUNTIME/failed.start"
if FAKE_FAIL_ONCE=start run_entry restore "$archive"; then not_ok 'injected post-mutation restore failure propagates'; else ok 'injected post-mutation restore failure propagates'; fi
[[ $(cat "$RUNTIME/data/value") == stable && $(resource_field container npm-app 5) == true ]] && ok 'failed restore rolls data back and restores prior running state' || not_ok 'failed restore rolls data back and restores prior running state'
python3 - "$RUNTIME/events" <<'PY'
import sys
v=open(sys.argv[1]).read().splitlines(); marker=max(i for i,x in enumerate(v) if x=='podman start npm-app')
prior=[i for i,x in enumerate(v[:marker]) if x.startswith('podman unshare sh -c find')]
raise SystemExit(0 if prior else 1)
PY
[[ $? -eq 0 ]] && ok 'restore mutation occurs before restart verification' || not_ok 'restore mutation occurs before restart verification'

for mode in delete extract restart; do
  rm -f "$RUNTIME"/failed.main-restore-extract "$RUNTIME"/failed.rollback-*
  "$BIN/podman" start npm-app >/dev/null
  printf "rollback-$mode" >"$RUNTIME/data/value"
  before_rb=$(find "$REPO/.state" -maxdepth 1 -type d -name 'restore-rollback.*' | wc -l)
  if FAKE_ROLLBACK_FAILURE=$mode run_entry restore "$archive"; then not_ok "injected rollback $mode failure propagates"; else ok "injected rollback $mode failure propagates"; fi
  after_rb=$(find "$REPO/.state" -maxdepth 1 -type d -name 'restore-rollback.*' | wc -l)
  [[ $after_rb -gt $before_rb ]] && ok "rollback $mode failure retains private snapshots" || not_ok "rollback $mode failure retains private snapshots"
  grep -q 'RECOVERY REQUIRED: rollback snapshots retained' "$TMP/restore.out" && ok "rollback $mode failure emits explicit recovery instructions" || not_ok "rollback $mode failure emits explicit recovery instructions"
  if [[ $mode == restart ]]; then
    [[ $(resource_field container npm-app 5) == false ]] && grep -q 'restart=failed' "$TMP/restore.out" && ok 'rollback restart failure is tracked and leaves service stopped' || not_ok 'rollback restart failure is tracked and leaves service stopped'
  else
    [[ $(resource_field container npm-app 5) == false ]] && grep -q 'restart=skipped-partial-rollback' "$TMP/restore.out" && ok "partial rollback $mode never restarts service" || not_ok "partial rollback $mode never restarts service"
  fi
  rm -rf "$REPO/.state"/restore-rollback.*
  "$BIN/podman" start npm-app >/dev/null
  assert_success "restore recovers after injected rollback $mode failure" run_entry restore "$archive"
done

mkdir "$TMP/race-set"; cp "$archive" "$base.manifest" "$base.sha256" "$TMP/race-set/"; chmod 600 "$TMP/race-set/"*
race_archive="$TMP/race-set/$(basename "$archive")"
real_python=$(command -v python3)
cat >"$BIN/python-race" <<SH
#!/usr/bin/env bash
"$real_python" "\$@"
rc=\$?
if ((rc==0)) && [[ \${1:-} == *validate_backup.py && " \$* " == *' --metrics '* ]]; then printf tampered >>"\${RACE_ARCHIVE:?}"; fi
exit \$rc
SH
chmod +x "$BIN/python-race"
set_container_state false healthy; printf race-change >"$RUNTIME/data/value"
assert_success 'restore extracts staged immutable copy after caller archive changes' env PYTHON_BIN="$BIN/python-race" RACE_ARCHIVE="$race_archive" bash -c '"$1/scripts/restore.sh" "$2" >"$3" 2>&1' _ "$REPO" "$race_archive" "$TMP/race.out"
[[ $(cat "$RUNTIME/data/value") == before ]] && ok 'caller-path TOCTOU mutation cannot alter staged extraction' || not_ok 'caller-path TOCTOU mutation cannot alter staged extraction'
assert_failure 'mutated caller archive is now invalid while staged restore already succeeded' python3 "$REPO/scripts/lib/validate_backup.py" "$race_archive" --image 'docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb' --owner "$owner"
"$BIN/podman" start npm-app >/dev/null

printf disk-stable >"$RUNTIME/data/value"; stops_before=$(event_count '^podman stop npm-app$')
assert_failure 'restore preflight rejects insufficient private staging disk' env RESTORE_AVAILABLE_BYTES=1 bash -c '"$1/scripts/restore.sh" "$2" >"$3" 2>&1' _ "$REPO" "$archive" "$TMP/disk.out"
[[ $(cat "$RUNTIME/data/value") == disk-stable && $(event_count '^podman stop npm-app$') -eq $stops_before ]] && ok 'staging disk preflight fails before stop or volume mutation' || not_ok 'staging disk preflight fails before stop or volume mutation'

mkdir "$TMP/invalid-set"; cp "$archive" "$base.manifest" "$base.sha256" "$TMP/invalid-set/"; chmod 600 "$TMP/invalid-set/"*
printf altered >>"$TMP/invalid-set/$(basename "$base").manifest"
printf validation-stable >"$RUNTIME/data/value"; stops_before=$(event_count '^podman stop npm-app$'); deletes_before=$(event_count 'find.*-delete')
assert_failure 'restore rejects an invalid external manifest before mutation' run_entry restore "$TMP/invalid-set/$(basename "$archive")"
[[ $(cat "$RUNTIME/data/value") == validation-stable && $(event_count '^podman stop npm-app$') -eq $stops_before && $(event_count 'find.*-delete') -eq $deletes_before ]] && ok 'restore validation failure performs no stop or volume mutation' || not_ok 'restore validation failure performs no stop or volume mutation'

set_container_state false healthy; printf stopped-change >"$RUNTIME/data/value"
assert_success 'restore of a prior-stopped container succeeds without --start' run_entry restore "$archive"
[[ $(resource_field container npm-app 5) == false && $(cat "$RUNTIME/data/value") == before ]] && ok 'restore preserves prior stopped state' || not_ok 'restore preserves prior stopped state'
printf stopped-repeat >"$RUNTIME/data/value"
assert_success 'repeat stopped restore converges without starting' run_entry restore "$archive"
[[ $(resource_field container npm-app 5) == false && $(cat "$RUNTIME/data/value") == before ]] && ok 'repeat stopped restore converges and remains stopped' || not_ok 'repeat stopped restore converges and remains stopped'
printf start-change >"$RUNTIME/data/value"
assert_success 'restore --start starts a previously stopped container' run_entry restore --start "$archive"
[[ $(resource_field container npm-app 5) == true && $(cat "$RUNTIME/data/value") == before ]] && ok 'restore --start recovers data and starts service' || not_ok 'restore --start recovers data and starts service'
printf running-repeat >"$RUNTIME/data/value"
assert_success 'repeat running restore converges' run_entry restore "$archive"
[[ $(resource_field container npm-app 5) == true && $(cat "$RUNTIME/data/value") == before ]] && ok 'repeat running restore remains healthy and converged' || not_ok 'repeat running restore remains healthy and converged'

owner=$(cat "$REPO/.state/owner-id")
sed -i 's/^volume npm-app-data true [^ ]*/volume npm-app-data true foreign/' "$RUNTIME/resources"
assert_failure 'remove refuses a foreign resource before compose mutation' run_entry remove
[[ -n $(resource_field container npm-app 2) ]] && ok 'foreign-resource removal failure preserves the running container' || not_ok 'foreign-resource removal failure preserves the running container'
sed -i "s/^volume npm-app-data true foreign/volume npm-app-data true $owner/" "$RUNTIME/resources"
rm -f "$RUNTIME/failed.down"
if FAKE_FAIL_ONCE=down run_entry remove; then not_ok 'partial compose-down failure propagates'; else ok 'partial compose-down failure propagates'; fi
[[ -n $(resource_field container npm-app 2) && -n $(resource_field volume npm-app-data 2) ]] && ok 'compose-down failure preserves owned resources' || not_ok 'compose-down failure preserves owned resources'
assert_success 'remove preserves owned volumes' run_entry remove
[[ -z $(resource_field container npm-app 2) && -n $(resource_field volume npm-app-data 2) ]] && ok 'remove state machine preserves data volumes' || not_ok 'remove state machine preserves data volumes'
assert_success 'repeat remove is idempotent' run_entry remove
assert_success 'deploy recreates partial runtime before purge failure test' run_entry deploy
rm -f "$RUNTIME/failed.volume-rm-npm-app-data"
if FAKE_FAIL_ONCE=volume-rm-npm-app-data run_entry remove --purge-data --yes; then not_ok 'partial purge volume-removal failure propagates'; else ok 'partial purge volume-removal failure propagates'; fi
[[ -n $(resource_field volume npm-app-data 2) && -n $(resource_field volume npm-letsencrypt 2) && -f $REPO/.secrets/npm-admin.env ]] && ok 'partial purge failure retains unremoved volumes and credentials for recovery' || not_ok 'partial purge failure retains unremoved volumes and credentials for recovery'
assert_success 'repeat purge converges after partial failure' run_entry remove --purge-data --yes
[[ -z $(resource_field volume npm-app-data 2) && -z $(resource_field volume npm-letsencrypt 2) ]] && ok 'purge removes both owned volumes' || not_ok 'purge removes both owned volumes'
assert_success 'repeat purge is idempotent' run_entry remove --purge-data --yes
finish
