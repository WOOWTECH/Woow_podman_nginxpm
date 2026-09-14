# Nginx Proxy Manager on rootless Podman (Quadlet)

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![NPM](https://img.shields.io/badge/nginx--proxy--manager-2.15.1-brightgreen)](https://nginxproxymanager.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**English** · [繁體中文](README_zh-TW.md)

[Nginx Proxy Manager](https://nginxproxymanager.com/) (NPM) packaged as a
**Quadlet + systemd** deployment for **rootless Podman**: reverse proxy hosts,
Let's Encrypt certificates and access lists, supervised by the user's systemd
with `Restart=always` and lingering, so it comes back after a crash and after a
reboot.

> **Docker / compose users:** this repository is Quadlet-only from this version
> on. The last commit with `docker-compose.yml` is tagged
> [`compose-final`](https://github.com/WOOWTECH/Woow_podman_nginxpm/tree/compose-final):
> `git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_nginxpm.git`.
> It is not maintained.

---

## What you get

| | |
|---|---|
| **Container** | `npm-app` from `docker.io/jc21/nginx-proxy-manager:2.15.1` (pinned; the digest is asserted by the smoke test) |
| **Ports** | HTTP and HTTPS on every interface, extra host ports on request, and the **admin UI on `127.0.0.1` only** |
| **Data** | the existing named volumes `npm-app-data` (database, proxy hosts, access lists, JWT keys) and `npm-letsencrypt` |
| **Network** | its own `npm-network`, plus the optional `pi-agent` network for the pi-web front |
| **Supervision** | `systemd --user` units generated from Quadlet: `Restart=always`, health check from the image (`/usr/bin/check-health`) |
| **Scripts** | install, upgrade (with rollback), backup, restore, uninstall, and a migration from a compose/manual deployment |

---

## Prerequisites

- Rootless Podman ≥ 4.4 for Quadlet; tested on Podman 4.9.3 / systemd 255
  (Ubuntu 24.04), which is what the WOOWTECH hosts run.
- **Low ports**: rootless Podman can only bind 80/443 when the host allows it:

  ```bash
  cat /proc/sys/net/ipv4/ip_unprivileged_port_start        # must be <= 80
  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rootless-podman-ports.conf
  sudo sysctl --system
  ```

  `install.sh` checks this and prints those lines; it never uses `sudo` itself.
  A host that must not change the sysctl can publish 8080/8443 instead
  (`NPM_HTTP_PORT`, `NPM_HTTPS_PORT`) — and must then move `NPM_ADMIN_PORT` too,
  since being bound to `127.0.0.1` does not exempt port 81 from the sysctl.
- Lingering, so the units run without a login session: `install.sh` enables it,
  or `sudo loginctl enable-linger <user>` if polkit refuses.

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nginxpm.git
cd Woow_podman_nginxpm
./scripts/install.sh                      # add --with-pi-web-front on a pi-agent host
```

On the first run it creates `~/.config/npm/npm.env` (mode 0600) from
`config/npm.env.example`, renders the units from it, checks them with the
Quadlet generator and `systemd-analyze --user verify`, pulls the pinned image,
installs the units, starts them and runs `tests/smoke.sh`. Re-running it after a
`git pull` or an env change restarts only what actually changed.

Then open the admin UI **through loopback** and change the default credentials
at once:

```bash
ssh -L 8181:127.0.0.1:81 <user>@<host>     # then http://127.0.0.1:8181/
# fresh volume: admin@example.com / changeme
```

Other ways in: a tailnet `tailscale serve --tcp=81 tcp://127.0.0.1:81`, or an NPM
proxy host with an access list in front of the admin UI. The admin port is never
published on a LAN interface.

### Settings

`~/.config/npm/npm.env` is read by the install and upgrade scripts only; they
render the values into the unit (decision D2), and neither systemd nor Podman
reads the file. Change a value, then run `./scripts/install.sh` again. It holds
no secret: NPM keeps its admin users, access lists and keys inside
`npm-app-data`.

| Key | Default | Effect |
|---|---|---|
| `NPM_TZ` | `Asia/Taipei` | container timezone |
| `NPM_HTTP_PORT` | `80` | host port for the HTTP listener, on every interface |
| `NPM_HTTPS_PORT` | `443` | host port for the HTTPS listener, on every interface |
| `NPM_ADMIN_PORT` | `81` | host port for the admin UI, always bound to `127.0.0.1` |
| `NPM_EXTRA_HTTP_PORTS` | *(empty)* | extra host ports into the same HTTP listener, space separated (for example `30142` for a Cloudflare route that targets `localhost:30142`) |
| `NPM_PI_WEB_FRONT` | `false` | see below; `install.sh --with-pi-web-front` sets it |

## The pi-web front

[Woow_podman_pi_agent_package](https://github.com/WOOWTECH/Woow_podman_pi_agent_package)
publishes pi-web on `127.0.0.1:30141` and ships no proxy. pi-web rejects any
`Host` that is not loopback or a raw IP and any `Origin` that does not match, so
a proxy host that forwards the browser's Host renders the UI and answers `403
Untrusted API request` on every `/api/*` route. NPM emits its own
`proxy_set_header Host $host` inside `location /`, and nginx does not inherit a
server-level `proxy_set_header` into a location that sets one, so overriding it
from the Advanced tab does not work.

`./scripts/install.sh --with-pi-web-front` therefore:

- joins the `pi-agent` network (ordering on `pi-agent-network.service`, never a
  hard dependency, and an `ExecStartPre` that creates the network if the
  pi-agent package was never installed), so NPM can reach `pi-web:30141` by
  name — a rootless bridge cannot reach the host's `127.0.0.1`;
- installs `~/.config/npm/pi-web-front/proxy.conf` over the image's
  `conf.d/include/proxy.conf`: the stock file with `Host` and `Origin` taken
  from two maps;
- installs `maps.conf`, which defines those maps **keyed on `$server`** — the
  proxy host's Forward Hostname. Forward to `pi-web` and you get
  `Host: localhost` with a blank `Origin`; every other upstream keeps the stock
  behaviour. Nothing in the file is deployment-specific.

Then create the proxy host: Forward Hostname **`pi-web`**, Forward Port
`30141`, Websockets on, and an **access list** — pi-web has no authentication of
its own and its browser terminal is a shell on the host account.

Both mounts are read-write on purpose: NPM 2.15.1 runs `chown -R` over
`/etc/nginx/conf.d` at start, and a `:ro` bind makes that fail with EROFS.
`tests/pi-web-front.sh` (and the `pi-web-front` workflow) fail the build if a new
NPM version changes the stock `proxy.conf` beyond those two lines.

That drift gate does **not** prove the rewrite works end to end — only that our
version of the file is still the stock one plus two lines. The proof is on the
host: create `~/.config/npm/smoke-pi.netrc` (mode 0600, one line
`machine <pi hostname> login <user> password <password>` with the access-list
credentials) and run

```bash
./tests/smoke.sh --pi-host pi.example.com
```

It sweeps the route unauthenticated (every answer must be a challenge, never a
502 and never a 200) and then asks for `/api/models` with the credentials, which
must answer 200. A 403 there means the Host/Origin rewrite did not apply.
Credentials are never printed. Treat that check as the go/no-go before and after
any change to this front.

## Upgrade

```bash
git pull
./scripts/upgrade.sh
```

Pulls the newly pinned image, gates it on the `proxy.conf` check when the front
is enabled, takes a cold backup, installs and smokes. If the new version does
not come up healthy it restores the previous units **and both volumes** (NPM's
database migrations only go forward) and restarts on the previous image.

Bumping a version means editing **two** lines of `quadlet/npm-app.container` in
the same commit: `Image=` and the `#   sha256:…` index digest above it, which
`tests/smoke.sh` asserts against the image that is actually running. Leave the
digest behind and the smoke check fails, and the upgrade rolls itself back.

## Backup and restore

```bash
./scripts/backup.sh                       # cold: a few seconds of downtime
./scripts/backup.sh --hot
./scripts/restore.sh ~/backups/npm/<timestamp>
```

Each run writes one timestamped directory with both volume exports, a copy of
`~/.config/npm` and a `.sha256` per file, 0600 in a 0700 directory. They contain
the access-list password hashes and the JWT keys; treat them as secrets.

## Uninstall

```bash
./scripts/uninstall.sh                    # stops and removes the units; keeps both volumes
./scripts/uninstall.sh --purge --yes      # also deletes the volumes, after a final export
```

Both volumes, the image and `~/.config/npm/npm.env` survive a plain uninstall;
the files this package installed under `~/.config/npm/pi-web-front/` are removed
with the units, and a re-install writes them again. `--purge` never touches the
`pi-agent` network, which belongs to the pi-agent package.

## Migrating an existing compose or manual deployment

`scripts/migrate-legacy.sh` adopts a running `npm-app` **in place**: same
volumes, same ports, same networks, no re-issued certificates.

```bash
./scripts/migrate-legacy.sh --dry-run              # what it would derive and do
./scripts/migrate-legacy.sh --pi-host pi.example.com
# ... verify ...
./scripts/migrate-legacy.sh --rollback             # any time during the soak period
```

It reads the legacy container (ports, networks, TZ, volumes) and the units that
start it, writes `~/.config/npm/npm.env` from that, records baseline checks,
backs up (inspect, CreateCommand, unit files, compose directory), then in one
short downtime: stops and disables the legacy unit(s), exports both volumes
cold, retires the container (Quadlet would delete a same-named one with
`--replace`) and runs `install.sh`. A failed install rolls back automatically.
Nothing of the legacy deployment is deleted beyond what the rollback shape below
requires: after the soak period, remove what is left, the unit file and the old
compose network by hand.

### How npm-app is kept for rollback

Renaming `npm-app` and leaving it stopped is a rollback path only while nothing
starts it again. The user unit `podman-restart.service` runs
`podman start --all --filter restart-policy=always` at boot, so on a host where
that unit is **enabled** a renamed, stopped container whose restart policy is
exactly `always` revives at the next boot and fights the new Quadlet container
for ports 80/443 and both volumes. podman 4.9.3 cannot repair that afterwards:
`podman update` only rewrites cgroup limits, and a restart policy is fixed at
create time.

The script therefore asks `ql_rollback_strategy` — which reads this host's real
state, never its name — and takes one of two paths. `--dry-run` prints which one
applies here.

| Answer | When | What the cutover does | What `--rollback` does |
|---|---|---|---|
| `rename` | the unit is disabled, or `npm-app`'s policy is not `always` | `podman rename npm-app npm-app-legacy-<date>`, left stopped | renames it back |
| `capture` | the unit is enabled **and** `npm-app`'s policy is `always` | writes `<backup>/legacy-container/npm-app/` (inspect, create command, image, policy, mounts, networks, published ports) and then a plain `podman rm` — never `podman rm -v`, which would delete the anonymous volumes | `ql_recreate_container` recreates it stopped, with its original restart policy |

`npm-app` is `unless-stopped` on both WOOWTECH hosts, so in practice both take
the `rename` path. What changed is that the script no longer merely *warns* when
`podman-restart.service` is enabled and then renames anyway — that warning fired
even for an `unless-stopped` container the unit never touches, and stayed a
warning in the one case where renaming really is unsafe.

The capture cannot bring back the container's **writable layer** — anything
written inside it that did not land in a volume or a bind mount. NPM keeps its
admin users, access lists, certificates and JWT keys in `npm-app-data` and
`npm-app-letsencrypt`, and the live container's writable layer holds only about
57 kB of runtime scratch under `/run` and `/var`, so nothing of value is lost.
(`ql_capture_container --commit` exists for a stack that mutates its own
container; NPM does not need it.) The container id and the IP/MAC lease are not
preserved either. `tests/rollback-model.sh` pins both paths.

### When it refuses: a host of a different lineage

`migrate-legacy.sh` adopts two shapes of `npm-app`: a podman-compose project, and a hand-made
`podman run`. Some hosts run neither. It **refuses** (it does not warn and carry on) when:

- **no unit that starts or stops `npm-app` was found, but a user unit runs a program out of a
  pre-Quadlet deployment tree** (a directory with a `.deployed-commit` stamp, or `scripts/deploy.sh`
  and no `scripts/lib/quadlet-lib.sh`). The refusal names those units and that tree. Migrating
  anyway would leave them enabled, and the next boot or timer tick would re-run that tree's
  `deploy.sh` and recreate `npm-app` against the Quadlet container's ports and volumes.
- **`npm-app` is attached to a network the Quadlet unit does not join.** The unit joins
  `npm.network`, plus `pi-agent` through `quadlet/fragments/pi-web-front.conf`. A third network has
  to be added to `quadlet/` first: nginx resolves upstream names at config load, so losing one is
  silent until the next reload.

Running any script out of such a tree is refused outright (`ql_require_own_lineage`): run it from a
fresh clone of this repo instead, and do **not** delete the host tree — live systemd units execute
scripts from it. `tests/host-tree.sh` pins all of this.

## Security

- **The admin UI is never published on a LAN interface.** It is bound to
  `127.0.0.1:81`; reach it with `ssh -L`, a tailnet `tailscale serve --tcp=81`,
  or an NPM proxy host with an access list. On a fresh volume it starts as
  `admin@example.com` / `changeme` — change it on the first login.
- **A proxy host in front of pi-web needs an access list.** pi-web ships no
  authentication and its browser terminal is a shell as the account that runs
  the containers, so the access list is the only thing between the route and
  that shell. For a public hostname, put Cloudflare Access in front as a second,
  independent layer. The authenticated smoke check above is how you prove the
  route still challenges.
- **Nothing secret lives in this repository or in a unit file.** NPM keeps its
  admin users, access lists, certificates and JWT keys inside the `npm-app-data`
  volume, and `~/.config/npm/npm.env` holds only ports and a timezone.
- **Backups are secrets**: the volume exports carry the access-list password
  hashes and the JWT keys. They are written 0600 in a 0700 directory; keep them
  that way. So is `~/.config/npm/smoke-pi.netrc`, which holds real credentials.
- **Rootless, so a container escape lands on an unprivileged account**, and the
  container gets no added capabilities. Low ports come from the sysctl, never
  from `sudo` or `setcap` on a podman binary.
- The image is pinned by tag **and** by index digest, both asserted after every
  (re)start.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `install.sh` refuses: legacy unit manages npm-app | use `scripts/migrate-legacy.sh`; it keeps the old unit and container for rollback |
| `install.sh` refuses: low ports not bindable | set `net.ipv4.ip_unprivileged_port_start`, or use high ports in `npm.env` |
| Proxy host to pi-web answers 403 on `/api/*` | Forward Hostname is not `pi-web`, or the front is not enabled |
| Proxy host answers 502 | NPM is not on the upstream's network, or the upstream is down |
| npm-app fails to start after editing the mounts | the pi-web-front mounts must stay read-write (EROFS from NPM's `chown -R`) |
| Admin UI not reachable from the LAN | by design: use `ssh -L`, a tailnet forward, or a proxy host with an access list |
| Ports free but `install.sh` says they are in use | another service holds them: `ss -tlnp` |

## Layout

```
quadlet/
  npm-app.container        the container unit, with @@TOKENS@@ for per-host values
  npm.network              NetworkName=npm-network
  npm-app-data.volume      VolumeName=npm-app-data      (adopts existing data)
  npm-letsencrypt.volume   VolumeName=npm-letsencrypt
  fragments/pi-web-front.conf   optional sections appended when NPM_PI_WEB_FRONT=true
  render-vars              the only variables install.sh may substitute
config/
  npm.env.example          -> ~/.config/npm/npm.env (0600)
  pi-web-front/*.conf      -> ~/.config/npm/pi-web-front/ (the Host/Origin rewrite)
scripts/
  install.sh upgrade.sh uninstall.sh backup.sh restore.sh migrate-legacy.sh
  common.sh render-args.sh
  lib/quadlet-lib.sh       vendored WOOWTECH Quadlet library (do not edit; CI checks its hash)
  lib/quadlet-lib.versions vendored version ledger; tests/lib-version.sh proves the lib above
                           really is the version it declares (CI)
tests/
  dryrun.sh dryrun.local.sh   render + quadlet -dryrun + systemd-analyze verify (CI)
  inspect-templates.sh     what migrate-legacy.sh derives from a captured `podman inspect`
  gotmpl.py                renders a --format template the way podman's Go templates do
  smoke.sh                 post-install checks on a real host
  pi-web-front.sh          proxy.conf drift gate against an image
  fixtures/                per-host variants, and other apps' units for the dry-run
.github/workflows/         quadlet-ci.yml (dry-run, shellcheck), pi-web-front.yml
```

## Other deployment platforms

| Platform | Repository |
|---|---|
| K3s / Kubernetes (Helm chart) | [Woow_k3s_nginxpm](https://github.com/WOOWTECH/Woow_k3s_nginxpm) |
| Home Assistant add-on | [Woow_ha_nginxpm](https://github.com/WOOWTECH/Woow_ha_nginxpm) |
| Docker / compose | this repository at tag `compose-final` (unmaintained) |

## License

MIT
