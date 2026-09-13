# Nginx Proxy Manager image pin

- Discovery date (UTC): 2026-08-27
- Official release: [v2.15.1](https://github.com/NginxProxyManager/nginx-proxy-manager/releases/tag/v2.15.1) (not a prerelease)
- Registry: the official `jc21/nginx-proxy-manager` Docker Hub repository linked by the project
- Target: `linux/amd64` (`x86_64`)
- Immutable multi-platform index digest: `sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb`
- Linux/amd64 child manifest: `sha256:99a885f56ca2203a2eb352a5f9e2cd5c1e25786508debd725ad48ebe955d114f`

Final reference:

```text
docker.io/jc21/nginx-proxy-manager:2.15.1@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb
```

## Reproduction

The release tag was obtained from the project's official GitHub release API. The digest was obtained from Docker Registry v2 over TLS using a scoped bearer token; the returned `Docker-Content-Digest` was checked against the downloaded OCI index bytes. The index maps `linux/amd64` to the child manifest above. On the version-matched host, run:

```bash
podman version
podman info --format '{{.Host.Arch}}'
podman pull docker.io/jc21/nginx-proxy-manager:2.15.1
podman image inspect docker.io/jc21/nginx-proxy-manager:2.15.1 \
  --format '{{range .RepoDigests}}{{println .}}{{end}}'
podman image inspect docker.io/jc21/nginx-proxy-manager:2.15.1 \
  --format '{{.Os}}/{{.Architecture}} {{.Digest}}'
podman pull docker.io/jc21/nginx-proxy-manager@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb
podman run --rm --entrypoint /bin/sh \
  docker.io/jc21/nginx-proxy-manager@sha256:52b2c59994f3d36acfcf70a1626f29734df0ed8c71bacc0269f78b6f939858bb \
  -c 'test -x /usr/bin/check-health'
```

The health probe path is also present in the official release tag's source at `docker/rootfs/usr/bin/check-health`. The local implementation environment did not contain Podman, so the pull/run commands above remain a required staging-host gate; no remote host was contacted or mutated.

When upgrading, repeat all checks, review the OCI index/platform mapping, verify the probe in the pulled image, update the exact pin in this document and `.env.example`, and commit that change before deployment.
