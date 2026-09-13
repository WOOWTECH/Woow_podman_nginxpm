# Secure rootless Nginx Proxy Manager / 安全的無 root Nginx Proxy Manager

This repository deploys Nginx Proxy Manager (NPM) with rootless **Podman 4.9.3** and **podman-compose 1.0.6**. The reviewed image is immutable; see [image-pin evidence](docs/image-pin.md).

本儲存庫使用無 root 的 **Podman 4.9.3** 與 **podman-compose 1.0.6** 部署 Nginx Proxy Manager（NPM）。映像已固定且不可變；請參閱[映像固定證據](docs/image-pin.md)。

## Security boundary / 安全邊界

- Public / 公開：`0.0.0.0:80` and / 與 `0.0.0.0:443`
- Administration / 管理：only / 僅限 `127.0.0.1:18081` → container / 容器 `81`
- There is no public/default host port `81`, no configurable port escape hatch, and no Docker/Portainer deployment path. / 不公開主機預設 `81`，無可調整連接埠的逃生設定，也不提供 Docker/Portainer 部署路徑。
- Deployment succeeds only after health/readiness, generated administrator authentication, and rejection of the upstream initial password are proven. Fresh v2.15.1 databases use a no-log, loopback-only transient bootstrap that is removed before steady state. / 僅在健康與就緒檢查、產生的管理者驗證成功，且上游初始密碼已遭拒絕後，部署才算成功。全新的 v2.15.1 資料庫使用不留日誌、僅限 loopback 的暫時 bootstrap，並在常態運行前移除。
- Exact labels bind `npm-app`, `npm-network`, `npm-app-data`, and `npm-letsencrypt` to one canonical checkout. Foreign resources are never adopted or mutated. / 精確標籤把上述四項資源綁定單一標準化 checkout；絕不接管或修改外來資源。

## Quick start / 快速開始

```bash
cp .env.example .env
chmod 600 .env
# Edit only TZ and NPM_ADMIN_EMAIL. Do not alter NPM_IMAGE.
# 僅修改 TZ 與 NPM_ADMIN_EMAIL；不可修改 NPM_IMAGE。
./scripts/deploy.sh
./scripts/verify.sh
```

Credentials are generated automatically in `.secrets/npm-admin.env` (mode `600`). Read them locally only when required; **never paste credentials or command output containing them into logs, chat, issues, or tickets**. / 憑證會自動產生於 `.secrets/npm-admin.env`（權限 `600`）。僅在需要時於本機讀取；**絕不可把憑證或包含憑證的輸出貼入日誌、聊天、issue 或工單**。

Rootless public ports require `/proc/sys/net/ipv4/ip_unprivileged_port_start` to be `80` or lower; an administrator must configure that and user login lingering. Scripts never invoke `sudo`. / 無 root 公開連接埠要求該 sysctl 為 `80` 以下；須由管理員設定此值與使用者 lingering。腳本絕不呼叫 `sudo`。

Full operations: [English](docs/operations.md) · [繁體中文](docs/operations.zh-TW.md)

Tests / 測試：

```bash
make test                    # non-destructive / 非破壞性
make test-gates              # proves live gates skip / 確認 live gate 預設略過
RUN_LIVE_TESTS=1 make test-live  # destructive on owned local resources / 會修改本機自有資源
```
