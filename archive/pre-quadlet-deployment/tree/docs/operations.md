# Secure NPM operations (English)

## Requirements and fixed topology

Use rootless Podman **4.9.3**, direct `podman-compose` **1.0.6**, Python 3, curl, tar/gzip, sha256sum, `ss`, `flock`, and user systemd. The immutable NPM release/digest and verification procedure are in [image-pin.md](image-pin.md). Do not use a floating image or substitute an unreviewed digest.

Public listeners are literal `0.0.0.0:80` and `0.0.0.0:443`. Administration is only `127.0.0.1:18081`, mapped to container port `81`; host port `81` is absent and ports cannot be overridden in `.env`. Rootless binding requires `net.ipv4.ip_unprivileged_port_start <= 80`. An administrator, not these scripts, must set that sysctl and enable login lingering when boot startup is required.

The exact owned resources are container `npm-app`, network `npm-network`, and volumes `npm-app-data` and `npm-letsencrypt`. Every resource must have `io.woow.nginxpm.managed=true` and this checkout's exact opaque owner label. An existing missing/mismatched label causes a fail-closed refusal before mutation.

## First deployment and credentials

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env                 # edit only TZ and NPM_ADMIN_EMAIL
./scripts/deploy.sh
./scripts/verify.sh
```

`.env` permits exactly `NPM_IMAGE`, `TZ`, and `NPM_ADMIN_EMAIL`; the image must equal the reviewed pin. Deployment pulls and starts only after version, rootless, low-port, render, and ownership checks. Podman 4.9 can fail to attach its automatic health scheduler to user systemd, so deployment and verification actively run `podman healthcheck run npm-app` and require both a successful exit and an inspected `healthy` status. They also wait for loopback API readiness and create a cryptographically random administrator secret. Older releases with the upstream initial credential are rotated through the API. On v2.15.1, if generated, initial, and recoverable transitional credentials are all rejected, deployment stops the steady container and read-only proves that both `user` and `auth` are empty before starting an exact-image, exact-volume/network transient bootstrap. Its administration port is loopback-only, its secret env file is mode `600`, and `--log-driver=none` prevents persistence of upstream's plaintext setup message. The transient and env file are removed before the steady Compose container is recreated without `INITIAL_ADMIN_*`; interrupted transitions are cleaned and converged on the next deploy. Any ambiguous/non-empty state fails closed.

Generated operator material is `.secrets/npm-admin.env`, directory mode `700`, file mode `600`. Inspect it only in a private local terminal when needed; do not print it as part of diagnostics. **Never paste credentials into logs, shell arguments, chat, issues, or support tickets.** Expected script output contains stage names only.

## Routine lifecycle

All commands are idempotent and use one lifecycle lock:

```bash
./scripts/deploy.sh                 # deploy or converge
./scripts/verify.sh                 # read-only security verification
./scripts/backup.sh                 # private backup under backups/
./scripts/restore.sh backups/npm-backup-YYYYMMDDTHHMMSSZ.tar.gz
./scripts/remove.sh                 # remove container/network; preserve data, credentials, backups
./scripts/remove.sh --purge-data --yes  # also delete exact owned volumes and local credentials/state; preserve backups
```

Verification requires exact labels, running/healthy state, exact port bindings/listeners and mounts, loopback readiness, generated authentication, initial-password rejection, and no known credential canary in container logs.

## User systemd

```bash
./scripts/install-systemd.sh
systemctl --user status nginx-proxy-manager.service
systemctl --user status nginx-proxy-manager-healthcheck.timer
systemctl --user restart nginx-proxy-manager.service
```

The installer atomically renders the absolute-path main service, timer-activated health oneshot, and timer; validates exact runtime versions and low-port/rootless prerequisites; then reloads and enables both the main service and timer. Every successful main-service start/restart starts or rearms the timer from `ExecStartPost`, after deployment succeeds. The dependency-free timer periodically triggers the exact-owned `npm-app` healthcheck oneshot, which remains ordered after and bound to the main service. Stopping the main service first stops the timer and health oneshot, then removes the scoped stack. The health oneshot is not enabled or managed directly. The installer does not elevate privileges. If `loginctl show-user "$USER" -p Linger` reports `no`, ask an administrator to enable lingering.

## Backup, restore, and recovery

A backup briefly stops a running healthy container, snapshots both volumes under fixed archive roots `data/` and `letsencrypt/`, and creates a mode-`600` archive, external manifest, and SHA-256 sidecar in a mode-`700` destination. The complete set is validated before publication, the checksum is published last, and any publication or restart failure removes the set. A trap restores the exact prior running/stopped state. Each timestamp creates a new backup.

Credentials are deliberately **not** included. Preserve `.secrets/npm-admin.env` separately as operator-held material with mode `600`; never attach it to backup tickets. Restore requires all three same-basename, caller-owned mode-`600` files plus matching format, reviewed image, and owner. It first copies the set into a new mode-`700` private directory, makes that copy read-only, and validates and extracts only the copy. Validation bounds sidecar and archive bytes, raw expansion, members, paths, individual and cumulative logical sizes, and rejects sparse files, absolute/traversal/duplicate/out-of-root members, hard links, devices, FIFOs, sockets, and unsafe symlinks. Relative `letsencrypt/` symlinks are accepted only when they stay inside that archive root, are never path ancestors, and resolve to an archived regular file. Available disk is checked before copying, extraction, and rollback snapshots.

After validation, rollback snapshots are taken, both trees are replaced, and readiness/credentials/full verification run when started. A failed restore reports every rollback stop, mount, delete, extract, and restart result. It never restarts after a partial rollback, retains snapshots under the reported `.state/restore-rollback.*` path, and prints manual recovery commands; preserve that directory until both volumes are confirmed recovered. Use `--start` to start a previously stopped service.

For disaster recovery, restore the repository at the same canonical path (the owner identity is path-bound), create the exact private `.env`, restore the separately held credential file, deploy empty owned resources, and then run the validated restore. Never extract a backup directly into a live volume. A different owner/path is intentionally rejected; do not relabel around it.

## Tailnet-only administration and remote gate

Validate the installed Tailscale CLI first:

```bash
tailscale version
tailscale serve --help
tailscale serve --bg --tcp 18081 tcp://127.0.0.1:18081
tailscale serve status --json
```

The forwarding target must be exactly `tcp://127.0.0.1:18081`, never a LAN address; a LAN firewall opening is not an alternative. From genuinely separate tailnet and LAN clients run:

```bash
RUN_LIVE_TESTS=1 RUN_REMOTE_LIVE_TESTS=1 \
TAILNET_TEST_SSH='user@tailnet-client' LAN_TEST_SSH='user@lan-client' \
TAILSCALE_GATEWAY_HOST='gateway-tail-name' LAN_TARGET_HOST='server-lan-address' \
bash tests/live/remote_test.sh
```

The gate requires tailnet gateway administration access, rejects direct LAN administration access, and confirms public `80`/`443`. Timeouts, ambiguous/same hosts, or missing forwarding fail.

## Tests, upgrades, troubleshooting

```bash
make test                         # unit/static only; never mutates Podman or uses SSH
bash tests/run.sh gates           # live tiers explicitly SKIP without opt-in
RUN_LIVE_TESTS=1 bash tests/live/local_test.sh  # destructive, expendable version-matched host only
```

The local live tier exercises repeated deploy, verify, systemd restart, backup/restore, preserve removal/redeploy, and repeated purge. Never set its gate on a production host. Remote tests additionally require their own explicit gate and four host values.

For upgrades, repeat the official release, registry digest, independent pull, platform, and in-image health-probe procedure in [image-pin.md](image-pin.md); review and commit the new literal digest before deployment. For failures, run `./scripts/verify.sh`, check version/sysctl and listener conflicts, then inspect redacted container status—not secret files. Do not enable tracing. No lifecycle command adopts foreign names; resolve ownership conflicts explicitly outside automation.
