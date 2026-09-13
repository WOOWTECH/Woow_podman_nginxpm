# Secure OpenClaw Nginx Proxy Manager Deployment Design

## Goal

Harden `Woow_podman_nginxpm` for a rootless Podman production deployment on the OpenClaw host. HTTP and HTTPS remain available on all host interfaces while the administration UI is available only on loopback and through a Headscale-managed Tailscale gateway.

## Network boundary

- Publish HTTP as `0.0.0.0:80 -> 80`.
- Publish HTTPS as `0.0.0.0:443 -> 443`.
- Publish the administration UI as `127.0.0.1:18081 -> 81`.
- Do not publish the default administration port on LAN interfaces.
- The Tailscale gateway forwards tailnet TCP port `18081` to host loopback port `18081`.

## Security and persistence

Use project-owned volumes for `/data` and `/etc/letsencrypt`. Generate deployment credentials into mode-`600` files, rotate the upstream default administrator password after first startup, and never print credentials in deployment output. Resource ownership checks must reject containers, networks, or volumes belonging to another checkout. Pin the NPM image to an explicit release and digest after validating the available upstream image.

## Lifecycle

Provide idempotent deploy, verify, backup, restore, remove, and user-systemd tooling. The admin password rotation is part of deployment success: a deployment that leaves the upstream default password active fails. Backups are mode `600`, validate archive paths before extraction, and cover both application data and certificates.

## Verification

Render and validate Compose before mutation. Live tests cover HTTP/HTTPS listeners, loopback-only admin binding, application readiness, credential rotation, restart persistence, backup validation, exact resource ownership, and absence of secrets in logs. A separate Tailscale client must reach the admin endpoint through the gateway while direct LAN access to port `18081` remains unavailable.
