# Secure OpenClaw Nginx Proxy Manager Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a secure, repeatable rootless Podman deployment of Nginx Proxy Manager with public HTTP/HTTPS, loopback-only administration, automatic default-password rotation, owned persistent resources, and tested lifecycle operations.

**Architecture:** A pinned single-container Compose stack exposes only `0.0.0.0:80`, `0.0.0.0:443`, and `127.0.0.1:18081`; small Bash entry points share strict validation and ownership helpers while a standard-library Python helper performs secret-bearing NPM API requests without putting credentials in arguments or logs. Project-labelled named volumes hold application data and certificates, user systemd invokes the same idempotent lifecycle scripts, and local/live/remote test tiers keep destructive host and tailnet checks behind explicit gates.

**Tech Stack:** Bash, Python 3 standard library, rootless Podman 4.9.3, podman-compose 1.0.6, Compose specification, curl, tar/gzip, sha256sum, user systemd, Tailscale/Headscale, and a dependency-free shell test harness.

---

## Compatibility and implementation constraints

- Develop and run compatibility checks against exactly Podman `4.9.3` and `podman-compose` `1.0.6`. Invoke `podman-compose` directly; do not assume `podman compose` or Docker Compose v2-only flags such as `--wait`, `--dry-run`, or `--progress`.
- Keep host mappings literal in `docker-compose.yml`: `0.0.0.0:80:80`, `0.0.0.0:443:443`, and `127.0.0.1:18081:81`. They are security policy, not user-configurable environment values.
- Use only features rendered successfully by `podman-compose config` on the target versions. Implement readiness and ownership polling in repository scripts rather than relying on Compose wait semantics.
- Run rootless throughout. Preflight must fail with remediation if `/proc/sys/net/ipv4/ip_unprivileged_port_start` is greater than `80`; scripts must never call `sudo` or silently change the sysctl.
- Never enable shell tracing around secrets. Secret-bearing API values are read from mode-`600` files or stdin, never command-line arguments. Tests must inspect captured stdout/stderr and process invocations for leaks.
- Default test commands are non-destructive. Local container mutation requires `RUN_LIVE_TESTS=1`; tests from separate LAN/tailnet clients additionally require `RUN_REMOTE_LIVE_TESTS=1` and explicit remote host variables.

## Target file layout

```text
.env.example
.gitignore
Makefile
README.md
docker-compose.yml
docs/
  image-pin.md
  operations.md
  operations.zh-TW.md
  plans/2026-08-27-secure-openclaw-deployment.md
scripts/
  backup.sh
  deploy.sh
  install-systemd.sh
  remove.sh
  restore.sh
  verify-remote.sh
  verify.sh
  lib/common.sh
  lib/npm_api.py
systemd/nginx-proxy-manager.service
tests/
  run.sh
  testlib.sh
  fixtures/
  unit/common_test.sh
  unit/compose_test.sh
  unit/credentials_test.sh
  unit/lifecycle_test.sh
  unit/systemd_test.sh
  live/local_test.sh
  live/remote_test.sh
```

`.state/`, `.secrets/`, and `backups/` are runtime-only mode-restricted paths and must be ignored by Git.

### Task 1: Discover and record an immutable upstream image

**Files:**
- Create: `docs/image-pin.md`
- Modify: `.env.example`
- Test: manual registry/image inspection recorded in `docs/image-pin.md`

**Step 1: Confirm the target platform and current upstream release**

On the Podman 4.9.3 target (or an architecture-identical staging host), record the architecture and inspect the official NPM release source. Do not choose `latest`, a prerelease, or a digest copied from an unauthenticated third-party page.

Run:

```bash
podman version
podman info --format '{{.Host.Arch}}'
# Resolve <release> from the official jc21/nginx-proxy-manager release/tag source.
podman pull docker.io/jc21/nginx-proxy-manager:<release>
```

Expected: Podman reports `4.9.3`, the target architecture is recorded, and the explicit release pulls successfully.

**Step 2: Resolve the pulled image digest**

Run:

```bash
podman image inspect docker.io/jc21/nginx-proxy-manager:<release> \
  --format '{{range .RepoDigests}}{{println .}}{{end}}'
podman image inspect docker.io/jc21/nginx-proxy-manager:<release> \
  --format '{{.Os}}/{{.Architecture}} {{.Digest}}'
```

Expected: inspection yields a `docker.io/jc21/nginx-proxy-manager@sha256:<64 hex>` repository digest for the intended platform.

**Step 3: Prove the digest is independently pullable and has the required health probe**

Run:

```bash
podman pull docker.io/jc21/nginx-proxy-manager@sha256:<digest>
podman run --rm --entrypoint /bin/sh \
  docker.io/jc21/nginx-proxy-manager@sha256:<digest> \
  -c 'test -x /usr/bin/check-health'
```

Expected: the digest pull succeeds and `/usr/bin/check-health` exists. If the probe is absent, document the verified in-image alternative and use that exact command in Task 3; do not guess.

**Step 4: Record reproducible evidence and the pin**

Write `docs/image-pin.md` with the UTC discovery date, official release URL/tag, target OS/architecture, exact commands, immutable repository digest, and the final reference:

```text
docker.io/jc21/nginx-proxy-manager:<release>@sha256:<digest>
```

Set that same reference as `NPM_IMAGE` in `.env.example`. Keep the resolved value literal—no placeholders remain after this task.

**Step 5: Verify no floating NPM image remains**

Run:

```bash
! grep -R 'jc21/nginx-proxy-manager:latest' -- .
grep -F 'docker.io/jc21/nginx-proxy-manager:<release>@sha256:<digest>' \
  .env.example docs/image-pin.md
```

Expected: no floating tag exists and both files contain the identical immutable reference.

**Step 6: Commit**

```bash
git add .env.example docs/image-pin.md
git commit -m "build: record verified NPM image digest"
```

### Task 2: Add the test harness and strict environment validation

**Files:**
- Create: `Makefile`
- Create: `tests/run.sh`
- Create: `tests/testlib.sh`
- Create: `tests/unit/common_test.sh`
- Create: `tests/fixtures/env.valid`
- Create: `scripts/lib/common.sh`
- Modify: `.env.example`
- Modify: `.gitignore`

**Step 1: Write failing environment tests**

Add dependency-free tests for `load_config`/`validate_config` covering:

- required `NPM_IMAGE`, `TZ`, and `NPM_ADMIN_EMAIL` values;
- rejection of unset/empty values, duplicate keys, unknown keys, whitespace-corrupted assignments, shell substitutions, malformed email/timezone, `latest`, tag-only images, and non-`sha256`/non-64-hex digests;
- acceptance only when `NPM_IMAGE` equals the reviewed pin from Task 1 (configuration must not silently select another digest);
- rejection of legacy `NPM_HTTP_PORT`, `NPM_HTTPS_PORT`, and `NPM_ADMIN_PORT` overrides;
- `.state`/`.secrets` directory mode `700` and generated file mode `600` helpers;
- rootless execution and low-port sysctl checks using fixture command/proc overrides.

Make `tests/run.sh unit` discover `tests/unit/*_test.sh`, report per-test failures, and return nonzero on any failure. `make test` must invoke this non-destructive unit tier.

**Step 2: Run the focused test and confirm failure**

Run:

```bash
bash tests/unit/common_test.sh
```

Expected: FAIL because `scripts/lib/common.sh` does not exist.

**Step 3: Implement the smallest strict parser and common primitives**

In `scripts/lib/common.sh`:

- determine `REPO_ROOT` from the script location and canonicalize it;
- parse only the allow-listed `KEY=value` grammar without `eval`;
- validate the exact pinned image, IANA timezone file, and admin email shape;
- set `umask 077`, create private runtime directories, and provide atomic private-file writes;
- provide `die`, redacted logging, command checks, rootless checks, and low-port preflight;
- allow command/proc path injection only when `TEST_MODE=1` so unit tests cannot weaken production validation;
- perform no action when sourced beyond function/constant definitions.

Update `.env.example` to contain only the three supported values and bilingual comments. Ignore `.state/`, `.secrets/`, and `backups/`.

**Step 4: Run tests and shell syntax checks**

Run:

```bash
bash tests/unit/common_test.sh
bash -n scripts/lib/common.sh tests/run.sh tests/testlib.sh
make test
```

Expected: all tests pass; no container is created.

**Step 5: Commit**

```bash
git add .env.example .gitignore Makefile scripts/lib/common.sh tests
git commit -m "test: add strict deployment configuration checks"
```

### Task 3: Lock down Compose topology, persistence, and health

**Files:**
- Modify: `docker-compose.yml`
- Create: `tests/unit/compose_test.sh`
- Modify: `tests/run.sh`
- Modify: `scripts/lib/common.sh`

**Step 1: Write failing rendered-Compose assertions**

Build a test around `podman-compose -f docker-compose.yml config` (skip with an explicit reason only when the exact binary is unavailable). Assert the rendered model has:

- the exact immutable image from Task 1;
- exactly three published mappings: public IPv4 `80` and `443`, loopback IPv4 `18081 -> 81`, with no host `81`, wildcard admin, IPv6 admin, host networking, or privileged mode;
- named project resources `npm-app`, `npm-network`, `npm-app-data`, and `npm-letsencrypt`;
- `/data` and `/etc/letsencrypt` mounted from their corresponding named volumes;
- restart policy `unless-stopped` and the image-verified healthcheck;
- owner and managed labels on the container, network, and both volumes;
- no Compose constructs unsupported by podman-compose 1.0.6.

Also add a static fallback test that fails rather than silently passing the security-boundary assertions when rendering is unavailable.

**Step 2: Run the test and confirm the insecure current file fails**

Run:

```bash
bash tests/unit/compose_test.sh
```

Expected: FAIL on floating `latest`, wildcard/default admin port, absent healthcheck, network, and ownership labels.

**Step 3: Implement the minimal Compose model**

Update `docker-compose.yml` to use environment interpolation only for validated `NPM_IMAGE`, `TZ`, and generated `NPM_OWNER_ID`. Remove the obsolete top-level `name` if 1.0.6 rendering requires it; lifecycle scripts will set a fixed `COMPOSE_PROJECT_NAME`. Add explicit resource names and labels:

```text
io.woow.nginxpm.managed=true
io.woow.nginxpm.owner=${NPM_OWNER_ID}
```

Use the exact health command proven in Task 1 with bounded interval, timeout, retries, and start period.

**Step 4: Add a compatible render helper**

Add `compose()` and `render_compose()` to `scripts/lib/common.sh`. They must export the already-validated values and call `podman-compose -f "$REPO_ROOT/docker-compose.yml"` from `REPO_ROOT`; do not rely on `--env-file` behavior or newer Compose flags.

**Step 5: Run render and unit tests**

Run:

```bash
podman-compose version
podman version --format '{{.Client.Version}}'
bash tests/unit/compose_test.sh
make test
```

Expected: versions are `1.0.6` and `4.9.3`, the rendered model passes all assertions, and unit tests pass.

**Step 6: Commit**

```bash
git add docker-compose.yml scripts/lib/common.sh tests/unit/compose_test.sh tests/run.sh
git commit -m "feat: enforce secure NPM compose topology"
```

### Task 4: Enforce exact checkout ownership for every resource

**Files:**
- Modify: `scripts/lib/common.sh`
- Create: `tests/fixtures/podman`
- Create: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing ownership tests**

Use a fake `podman` fixture to model absent and existing resources. Test that:

- first use atomically creates a stable owner ID from the canonical checkout identity in `.state/owner-id` with mode `600`;
- a repeated call from the same checkout reuses it;
- absent resources are allowed before creation;
- each expected container, network, and volume with both exact labels is accepted;
- any expected name with a missing, empty, or different owner/managed label is rejected before mutation;
- unexpected resource type/name substitution cannot satisfy the check;
- inspect failures other than “not found” fail closed;
- all lifecycle entry points can call the same checker.

**Step 2: Run the focused test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh ownership
```

Expected: FAIL because owner generation and inspection functions are absent.

**Step 3: Implement ownership primitives**

Add constants for the exact resource inventory and functions to generate/read `NPM_OWNER_ID`, inspect labels with `podman inspect`, `podman network inspect`, and `podman volume inspect`, and reject foreign resources. Never adopt, relabel, remove, or start a foreign resource. Include the canonical path in a non-secret state metadata file for diagnostics, but compare the opaque owner ID in labels.

**Step 4: Run focused and full unit tests**

Run:

```bash
bash tests/unit/lifecycle_test.sh ownership
make test
```

Expected: all ownership scenarios pass.

**Step 5: Commit**

```bash
git add scripts/lib/common.sh tests/fixtures/podman tests/unit/lifecycle_test.sh
git commit -m "feat: reject resources owned by another checkout"
```

### Task 5: Implement readiness and secret-safe default credential rotation

**Files:**
- Create: `scripts/lib/npm_api.py`
- Create: `scripts/deploy.sh`
- Create: `tests/fixtures/npm_api_server.py`
- Create: `tests/unit/credentials_test.sh`
- Modify: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing API-helper tests**

Start a local fake NPM HTTP server and assert that the helper:

- reads identity, current password, replacement password, and token only from mode-`600` files/stdin—not argv;
- uses the upstream-version-specific token and password-change endpoints verified against the pinned image;
- handles JSON and HTTP failures without echoing response bodies that may contain secrets;
- prints only a machine-safe success/failure status;
- leaves no token file after exit.

Capture stdout, stderr, the fake server request log, and `/proc/<pid>/cmdline`; place canary secrets in inputs and assert they appear only in the server-side request fixture, never local output or argv.

**Step 2: Run the helper test and confirm failure**

Run:

```bash
bash tests/unit/credentials_test.sh api
```

Expected: FAIL because the helper does not exist.

**Step 3: Implement the standard-library API helper**

Use Python 3 `urllib.request` and `json`; do not add pip dependencies. Implement only readiness/authenticate/change-password operations. Bound connect/read behavior, avoid traceback/response-body disclosure, validate loopback URL, and return distinct non-secret exit codes for “credentials rejected”, “not ready”, and “request failed”.

**Step 4: Write failing deploy state-machine tests**

Using fake `podman`, `podman-compose`, and API helper commands, cover:

1. render/preflight/ownership checks happen before `pull` or `up`;
2. a fresh mode-`600` `.secrets/npm-admin.env` is generated atomically with `NPM_ADMIN_EMAIL` and a cryptographically random password;
3. `podman-compose pull` and `up -d` are compatible with 1.0.6 and repeat safely;
4. readiness waits for both Podman health and loopback HTTP readiness with a timeout;
5. generated credentials are tried first on rerun;
6. if generated auth fails and the upstream default succeeds, password is changed immediately;
7. success requires generated auth to succeed and upstream `admin@example.com` / `changeme` auth to fail;
8. if neither credential set works, deployment fails without overwriting credentials;
9. stdout/stderr and mocked command argv never contain default/generated passwords or tokens;
10. an interrupted run is recoverable and a second run converges.

**Step 5: Run the deploy test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh deploy
```

Expected: FAIL because `scripts/deploy.sh` is absent.

**Step 6: Implement the minimal idempotent deploy flow**

In order: disable xtrace, take an exclusive state lock, validate tools/config/rootless low ports, render Compose, establish owner ID, check all existing resources, create credentials if absent, pull the pinned image, run `up -d`, wait for health/readiness, reconcile credentials, prove the default password is rejected, and run the local verification functions added in Task 6. Log stage names only. A deployment that cannot prove rotation must exit nonzero.

Use a password generator backed by Python `secrets` or `/dev/urandom`; never use `$RANDOM`, timestamps, UUIDs, or predictable hashes.

**Step 7: Run credential/deploy tests and syntax checks**

Run:

```bash
bash tests/unit/credentials_test.sh
bash tests/unit/lifecycle_test.sh deploy
python3 -m py_compile scripts/lib/npm_api.py
bash -n scripts/deploy.sh
make test
```

Expected: all tests pass and canary secrets are absent from captured output/argv.

**Step 8: Commit**

```bash
git add scripts/deploy.sh scripts/lib/npm_api.py tests/fixtures/npm_api_server.py \
  tests/unit/credentials_test.sh tests/unit/lifecycle_test.sh
git commit -m "feat: deploy NPM with mandatory credential rotation"
```

### Task 6: Add comprehensive local verification

**Files:**
- Create: `scripts/verify.sh`
- Modify: `scripts/lib/common.sh`
- Modify: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing verification tests**

Mock `podman`, `ss`, HTTP, and API calls. Require verification to check:

- exact owner labels on the container, network, and both volumes;
- container running state and healthy status (not merely existence);
- public listeners on `0.0.0.0:80` and `0.0.0.0:443`;
- admin listener on `127.0.0.1:18081` only, with failures for `0.0.0.0`, non-loopback host addresses, `[::]`, or host port `81`;
- loopback admin HTTP readiness;
- authentication with generated credentials and rejection of default credentials;
- `/data` and `/etc/letsencrypt` exact mounts;
- no secret/default credential canaries in current container logs;
- concise redacted output and nonzero status for each failed invariant.

**Step 2: Run the focused test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh verify
```

Expected: FAIL because `scripts/verify.sh` does not exist.

**Step 3: Implement verification as a read-only operation**

Share readiness, ownership, listener, and credential functions through `common.sh`. `verify.sh` may create its private lock/temp files but must not start, stop, relabel, or recreate Podman resources. Search logs for known default credentials and test-injected generated canaries without printing matching lines.

**Step 4: Run tests and syntax checks**

Run:

```bash
bash tests/unit/lifecycle_test.sh verify
bash -n scripts/verify.sh scripts/lib/common.sh
make test
```

Expected: every invariant and failure mode passes.

**Step 5: Commit**

```bash
git add scripts/verify.sh scripts/lib/common.sh tests/unit/lifecycle_test.sh
git commit -m "feat: verify deployment security invariants"
```

### Task 7: Add consistent, private, idempotent backups

**Files:**
- Create: `scripts/backup.sh`
- Modify: `scripts/lib/common.sh`
- Modify: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing backup tests**

Cover:

- config/render/ownership/health checks before mutation;
- one lifecycle lock shared with deploy/restore/remove;
- backup destination creation at mode `700` and archive/manifest/checksum files at mode `600`;
- capture of both named volumes under fixed top-level paths `data/` and `letsencrypt/`;
- metadata containing format version, UTC timestamp, pinned image, and owner ID but no credential/token value;
- stopping for a consistent SQLite/filesystem snapshot and restoring the exact prior running/stopped state via traps on success or failure;
- write-to-temp, archive validation, checksum, and atomic rename;
- a repeated invocation creating a new complete timestamped backup without damaging earlier backups;
- rejection of foreign resources and symlinked/untrusted destination paths.

**Step 2: Run the focused test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh backup
```

Expected: FAIL because `scripts/backup.sh` is absent.

**Step 3: Implement backup**

Use a pinned helper image only if required; preferably use `podman unshare` plus host-side `tar` if verified with rootless Podman 4.9.3. If a helper image is necessary, discover and record its explicit digest using Task 1’s process before adding it. Never introduce a floating helper image. Ensure archive member listing and checksum verification complete before the final rename.

Do not put `.secrets/npm-admin.env` in the volume archive. Document that it is separate operator-held deployment material and never print it.

**Step 4: Run backup tests**

Run:

```bash
bash tests/unit/lifecycle_test.sh backup
bash -n scripts/backup.sh
make test
```

Expected: mode, content, prior-state, failure-trap, and idempotency cases pass.

**Step 5: Commit**

```bash
git add scripts/backup.sh scripts/lib/common.sh tests/unit/lifecycle_test.sh
git commit -m "feat: add private consistent NPM backups"
```

### Task 8: Add path-safe transactional restore

**Files:**
- Create: `scripts/restore.sh`
- Modify: `scripts/lib/common.sh`
- Modify: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing restore validation tests**

Create valid and malicious fixture archives. Before any stop/clear/extract operation, require rejection of:

- checksum mismatch or missing manifest;
- unknown format version, image, owner, or missing `data/`/`letsencrypt/` trees;
- absolute paths, `..` traversal, empty/ambiguous member names, duplicate normalized paths;
- symlink, hardlink, device, FIFO, or socket entries;
- members outside the two fixed roots;
- foreign existing resources or an archive from another owner unless an explicit documented same-owner recovery procedure applies.

Assert validation failures leave volumes and running state untouched.

**Step 2: Run the validation test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh restore-validation
```

Expected: FAIL because `scripts/restore.sh` is absent.

**Step 3: Implement pre-extraction validation**

List and inspect archive headers without extraction, normalize every path, permit regular files/directories only, compare the checksum and metadata, and stage extracted data in newly created private temporary directories. Never use raw `tar -C <live-volume> -xf <unvalidated-archive>`.

**Step 4: Write failing restore convergence tests**

Test lock acquisition, exact prior-state handling, volume replacement only after validation, cleanup on signals, restart/readiness, generated credential auth, default credential rejection, full `verify.sh`, and a second restore of the same archive converging successfully.

**Step 5: Run the convergence test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh restore
```

Expected: FAIL until replacement, rollback, and post-restore verification are wired.

**Step 6: Complete transactional restore**

After validation, stop if running, preserve a rollback snapshot, replace both volume trees, restart if previously running (or when `--start` is explicitly requested), reconcile credentials without ever reactivating the default, and invoke verification. On failure, restore the rollback snapshot and original running state, then exit nonzero.

**Step 7: Run restore and full tests**

Run:

```bash
bash tests/unit/lifecycle_test.sh restore-validation
bash tests/unit/lifecycle_test.sh restore
bash -n scripts/restore.sh
make test
```

Expected: malicious archives never mutate resources; valid restore and repeat restore pass.

**Step 8: Commit**

```bash
git add scripts/restore.sh scripts/lib/common.sh tests/unit/lifecycle_test.sh
git commit -m "feat: add validated transactional NPM restore"
```

### Task 9: Add safe idempotent removal

**Files:**
- Create: `scripts/remove.sh`
- Modify: `tests/unit/lifecycle_test.sh`

**Step 1: Write failing removal tests**

Specify and test two explicit modes:

- default `remove.sh`: remove the owned container and network while preserving both data volumes, credentials, and backups;
- `remove.sh --purge-data --yes`: remove the owned container, network, both volumes, and local generated credentials/state, but never backups.

Both modes must validate config/render/ownership before mutation, reject foreign resources, acquire the lifecycle lock, tolerate already-absent owned resources, avoid interactive behavior under systemd, reject unknown flags, and never broaden Podman prune scope.

**Step 2: Run the focused test and confirm failure**

Run:

```bash
bash tests/unit/lifecycle_test.sh remove
```

Expected: FAIL because `scripts/remove.sh` is absent.

**Step 3: Implement exact-name removal**

Use 1.0.6-compatible `podman-compose down` for service/network teardown only after ownership checks. For purge, re-check labels immediately before deleting each exact volume name. Remove private local state only after Podman deletion succeeds. A repeat invocation must return success.

**Step 4: Run removal tests**

Run:

```bash
bash tests/unit/lifecycle_test.sh remove
bash -n scripts/remove.sh
make test
```

Expected: preserve, purge, foreign, partial, and repeated cases pass.

**Step 5: Commit**

```bash
git add scripts/remove.sh tests/unit/lifecycle_test.sh
git commit -m "feat: add ownership-safe NPM removal"
```

### Task 10: Integrate with user systemd

**Files:**
- Create: `systemd/nginx-proxy-manager.service`
- Create: `scripts/install-systemd.sh`
- Create: `tests/unit/systemd_test.sh`
- Modify: `tests/run.sh`

**Step 1: Write failing unit-file/installer tests**

Assert that the service:

- is a user unit using absolute paths substituted by the installer;
- runs `scripts/deploy.sh` for `ExecStart` and ownership-safe non-purging stop logic for `ExecStop`;
- uses `Type=oneshot`, `RemainAfterExit=yes`, appropriate network ordering, restart/failure semantics that do not create a tight loop, and a private umask;
- does not embed environment values, credentials, `sudo`, or a home-directory assumption;
- validates rootless Podman 4.9.3/podman-compose 1.0.6 and low-port prerequisites before installation;
- installs atomically under `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, runs `systemctl --user daemon-reload`, and idempotently enables/starts the unit;
- emits a clear, non-secret note when login lingering must be enabled by an administrator rather than attempting privilege escalation.

**Step 2: Run the test and confirm failure**

Run:

```bash
bash tests/unit/systemd_test.sh
```

Expected: FAIL because the template and installer are absent.

**Step 3: Implement the user unit and installer**

Keep lifecycle behavior in scripts, not shell fragments in the unit. Use a repository-provided non-purging stop command or `remove.sh` mode whose semantics are covered by Task 9. Quote substituted paths safely and reject newline/percent hazards.

**Step 4: Verify the rendered unit**

Run:

```bash
bash tests/unit/systemd_test.sh
systemd-analyze --user verify systemd/nginx-proxy-manager.service
bash -n scripts/install-systemd.sh
make test
```

Expected: tests pass. If the template intentionally contains an installer token, have the test render to a temporary unit before `systemd-analyze verify`.

**Step 5: Commit**

```bash
git add systemd/nginx-proxy-manager.service scripts/install-systemd.sh \
  tests/unit/systemd_test.sh tests/run.sh
git commit -m "feat: manage NPM with rootless user systemd"
```

### Task 11: Add gated local and remote live security tests

**Files:**
- Create: `tests/live/local_test.sh`
- Create: `tests/live/remote_test.sh`
- Create: `scripts/verify-remote.sh`
- Modify: `tests/run.sh`
- Modify: `Makefile`

**Step 1: Write gate tests before live behavior**

Unit-test that:

- `make test` and `tests/run.sh unit` never invoke Podman mutation, SSH, or remote curl;
- local live tests exit with an explicit SKIP unless `RUN_LIVE_TESTS=1`;
- remote tests exit with an explicit SKIP unless both `RUN_LIVE_TESTS=1` and `RUN_REMOTE_LIVE_TESTS=1`;
- remote mode strictly requires separate `TAILNET_TEST_SSH`, `LAN_TEST_SSH`, `TAILSCALE_GATEWAY_HOST`, and `LAN_TARGET_HOST` values and rejects localhost/same-host aliases;
- SSH uses batch mode, bounded connect timeout, and no secret values.

**Step 2: Run gate tests and confirm failure**

Run:

```bash
bash tests/run.sh gates
```

Expected: FAIL until the tier dispatch and guards exist.

**Step 3: Implement the local live test**

On an expendable target with free ports, exercise:

1. clean deploy and repeated deploy;
2. Compose health plus `verify.sh` readiness/listener/mount/owner checks;
3. generated credential success and default credential failure;
4. no credentials in deployment output or `podman logs`;
5. restart and user-systemd restart persistence;
6. backup, archive validation, mutate a harmless fixture, restore, and verify persistence;
7. non-purging remove/redeploy and explicit purge/repeated purge.

Use traps to clean only resources whose exact owner labels match the test checkout. Preserve failure diagnostics only after redacting canaries.

**Step 4: Implement the separate-client remote gate**

`verify-remote.sh` must run two independent probes:

- through `TAILNET_TEST_SSH`, reach `http://<TAILSCALE_GATEWAY_HOST>:18081` and receive an expected NPM response;
- through `LAN_TEST_SSH`, fail to connect to `http://<LAN_TARGET_HOST>:18081` while confirming the intended public `80`/`443` endpoints remain reachable.

Also have the deployment host verify that Tailscale/Headscale forwards tailnet TCP `18081` to `127.0.0.1:18081`, not to a LAN address. Treat timeout, DNS ambiguity, same-host clients, or a successful direct LAN admin connection as failure, not skip.

**Step 5: Run non-destructive tiers**

Run:

```bash
make test
bash tests/run.sh gates
bash tests/live/local_test.sh
bash tests/live/remote_test.sh
```

Expected: unit/gate tests pass; both live scripts explicitly SKIP without their opt-in variables and mutate nothing.

**Step 6: Run the local live gate on the version-matched staging host**

Run:

```bash
RUN_LIVE_TESTS=1 bash tests/live/local_test.sh
```

Expected: full deploy/restart/backup/restore/remove lifecycle passes under rootless Podman 4.9.3 and podman-compose 1.0.6.

**Step 7: Run the remote gate from genuinely separate clients**

Run:

```bash
RUN_LIVE_TESTS=1 RUN_REMOTE_LIVE_TESTS=1 \
TAILNET_TEST_SSH='<tailnet-client>' \
LAN_TEST_SSH='<lan-client>' \
TAILSCALE_GATEWAY_HOST='<gateway-tailnet-ip-or-name>' \
LAN_TARGET_HOST='<openclaw-lan-ip>' \
bash tests/live/remote_test.sh
```

Expected: the tailnet gateway admin request succeeds, direct LAN admin request fails, and LAN public HTTP/HTTPS probes succeed.

**Step 8: Commit**

```bash
git add Makefile scripts/verify-remote.sh tests/run.sh tests/live
git commit -m "test: gate local and tailnet deployment checks"
```

### Task 12: Replace legacy guidance with bilingual operations documentation

**Files:**
- Modify: `README.md`
- Create: `docs/operations.md`
- Create: `docs/operations.zh-TW.md`
- Modify: `.env.example`
- Test: `tests/unit/docs_test.sh`
- Modify: `tests/run.sh`

**Step 1: Write failing documentation consistency tests**

Assert English and Traditional Chinese guidance both include:

- exact rootless Podman `4.9.3` and podman-compose `1.0.6` requirements;
- immutable NPM image pin and link to `docs/image-pin.md`;
- strict `.env` creation/permissions and no configurable port escape hatch;
- public `80`/`443`, loopback `18081`, and absence of public/default host `81`;
- readiness/health and automated default-password rotation behavior, credential file location/mode, and explicit warnings never to paste credentials into logs/issues;
- ownership refusal behavior and exact resource inventory;
- idempotent deploy, verify, backup, restore, remove-preserve, purge, and user-systemd commands;
- rootless low-port sysctl prerequisite and administrator-managed lingering;
- backup format, path validation, credential-separation, restore rollback, and recovery notes;
- Tailscale gateway forwarding to loopback plus the separate tailnet/LAN remote test gate;
- test tier commands and destructive-test warnings.

Fail on legacy instructions exposing `:81`, `latest`, Docker-first commands, manual “change `changeme` after login”, or unsafe raw tar extraction.

**Step 2: Run the documentation test and confirm failure**

Run:

```bash
bash tests/unit/docs_test.sh
```

Expected: FAIL because current README contains legacy image, port, default credential, Docker, and raw restore guidance.

**Step 3: Write concise bilingual entry documentation**

Make `README.md` a matched English/Traditional Chinese overview and quick start. Link each language to its full operations guide. Keep commands and security guarantees equivalent; do not leave one language with weaker warnings.

Document the host-side Tailscale gateway command only after validating its syntax against the installed Tailscale version. It must forward tailnet TCP `18081` exclusively to `tcp://127.0.0.1:18081`; state that LAN firewall exposure is not an alternative.

**Step 4: Write full operations runbooks**

In both guides, include prerequisites, first deployment, expected redacted output, locating credentials without printing them, verification, systemd, backup/restore, safe removal, remote gate setup, upgrades (repeat Task 1 and review/commit a new digest), troubleshooting, and disaster recovery. Never include an actual generated password/token.

**Step 5: Run docs and full non-destructive checks**

Run:

```bash
bash tests/unit/docs_test.sh
make test
git grep -nE 'nginx-proxy-manager:latest|0\.0\.0\.0:81|NPM_ADMIN_PORT|changeme.*immediately|tar xzf' \
  -- ':!docs/plans/*' ':!tests/*'
```

Expected: documentation tests pass; grep returns no production/documentation legacy guidance (references in negative security tests are excluded).

**Step 6: Commit**

```bash
git add README.md .env.example docs/operations.md docs/operations.zh-TW.md \
  tests/unit/docs_test.sh tests/run.sh
git commit -m "docs: add bilingual secure operations runbooks"
```

### Task 13: Run final version-matched acceptance and record evidence

**Files:**
- Modify only if a test exposes a defect: the smallest relevant implementation/test/documentation file
- Do not add generated `.env`, `.state/`, `.secrets/`, backup archives, logs, or Python bytecode

**Step 1: Prove repository hygiene and static/unit behavior**

Run:

```bash
make test
find scripts tests -type f \( -name '*.sh' -o -name 'podman' \) -exec bash -n {} +
python3 -m py_compile scripts/lib/npm_api.py tests/fixtures/npm_api_server.py
git diff --check
git status --short
```

Expected: all checks pass; only intentional source changes, if any, appear. Remove generated `__pycache__` before proceeding.

**Step 2: Prove exact runtime compatibility**

Run on staging/OpenClaw:

```bash
podman version --format '{{.Client.Version}}'
podman-compose version
podman-compose -f docker-compose.yml config >/dev/null
```

Expected: `4.9.3`, `1.0.6`, and successful rendering.

**Step 3: Run local live acceptance twice**

Run:

```bash
RUN_LIVE_TESTS=1 bash tests/live/local_test.sh
RUN_LIVE_TESTS=1 bash tests/live/local_test.sh
```

Expected: both runs pass, proving convergence/idempotency as well as lifecycle behavior.

**Step 4: Run remote network-boundary acceptance**

Run Task 11’s remote command from the configured separate clients.

Expected: tailnet gateway `18081` succeeds, LAN `18081` fails, public `80`/`443` remain available.

**Step 5: Inspect for secret or generated-artifact leaks**

Run:

```bash
! git grep -nE '(changeme|NPM_ADMIN_PASSWORD|Bearer [A-Za-z0-9._-]+)' \
  -- ':!docs/plans/*' ':!tests/*'
git status --ignored --short
```

Expected: no production secret/default-password literal is logged or documented; runtime secrets, state, backups, and bytecode are absent from tracked/unignored changes.

**Step 6: Commit only necessary acceptance fixes**

If acceptance found a defect, rerun the focused failing test before and after the smallest fix, then rerun Steps 1–5 and commit that fix alone:

```bash
git add <only-the-fixed-source-and-test-files>
git commit -m "fix: satisfy secure deployment acceptance"
```

If no defect was found, do not create an empty commit.

## Definition of done

- The image is an independently verified explicit release and digest, with reproducible discovery evidence.
- Strict validation and rendered-Compose checks run before every mutation.
- Only public host ports `80`/`443` and loopback `18081` are exposed; container/admin port `81` is never directly reachable from LAN.
- Deployment is not successful until NPM is healthy/ready, generated credentials work, and upstream default credentials fail.
- No password or token appears in argv, stdout/stderr, container logs, committed files, or backup metadata.
- Container, network, and both volumes have exact checkout ownership labels; foreign resources fail closed.
- Deploy, verify, backup, validated restore, safe remove/purge, and user-systemd operations are idempotent on rootless Podman 4.9.3 with podman-compose 1.0.6.
- Default tests are non-destructive; local and separate-client remote gates pass when explicitly enabled.
- English and Traditional Chinese documentation describe the same secure operation and recovery model.
