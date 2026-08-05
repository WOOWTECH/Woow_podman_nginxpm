# Nginx Proxy Manager Docker Compose

Production-ready Docker Compose setup for **Nginx Proxy Manager** with built-in SQLite database.

適用於生產環境的 **Nginx Proxy Manager** Docker Compose 部署方案，使用內建 SQLite 資料庫。

---

## Table of Contents / 目錄

- [English](#english)
- [繁體中文](#繁體中文)

---

## English

### What is Nginx Proxy Manager?

[Nginx Proxy Manager](https://nginxproxymanager.com/) (NPM) is a reverse proxy management system that provides:

- **Web-based Admin UI** — Manage proxy hosts, SSL certificates, and access lists through an intuitive web interface on port 81
- **Reverse Proxy** — Route incoming HTTP/HTTPS traffic to internal services by domain name
- **Free SSL Certificates** — Automatic Let's Encrypt SSL certificate provisioning and renewal
- **Access Lists** — Restrict access to proxied services by IP or HTTP authentication
- **Redirection Hosts** — Redirect domains to other URLs
- **404 Hosts** — Custom 404 pages for unused domains
- **Streams** — TCP/UDP port forwarding for non-HTTP services

### Why SQLite (No External Database Needed)?

NPM uses **SQLite by default** — the database file is stored inside the `/data` volume. This is the recommended approach for most deployments because:

- NPM stores minimal data (proxy host configs, SSL cert metadata, access lists)
- No additional container, memory, or password management overhead
- One less service to monitor and maintain
- Fully production-stable for typical reverse proxy workloads

> **Note:** NPM also supports PostgreSQL and MySQL/MariaDB as optional external backends for very large-scale deployments, but SQLite handles the vast majority of use cases.

### Architecture

```
┌──────────────────────────────────────────────┐
│              Docker Compose Stack             │
│                                              │
│  ┌──────────────────────────────────────┐    │
│  │     Nginx Proxy Manager (app)        │    │
│  │     Ports: 80, 443, 81              │    │
│  │     Image: jc21/nginx-proxy-manager  │    │
│  │     Database: SQLite (built-in)      │    │
│  └──────────────────────────────────────┘    │
│                                              │
│  Volumes: npm-app-data, npm-letsencrypt      │
└──────────────────────────────────────────────┘
```

### File Structure

```
.
├── docker-compose.yml    # Main orchestration file / 主要編排檔案
├── .env.example          # Configuration template / 環境變數範本
├── .env                  # Your configuration (git-ignored) / 你的設定檔（不納入版控）
├── .gitignore            # Git ignore rules / Git 忽略規則
└── README.md             # This documentation / 本說明文件
```

### Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

#### Via Git Repository (Recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_nginxpm` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

#### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_nginxpm/podman/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the content from the URL above using `curl` or your browser, paste into the editor
4. Set environment variables (refer to `.env.example`)
5. Click **Deploy the stack**


### Prerequisites

| Requirement | Minimum Version |
|-------------|----------------|
| Docker Engine | 20.10+ |
| Docker Compose | v2.0+ |
| RAM | 512 MB |
| Disk Space | 1 GB |

> **Note:** This setup is also compatible with **Podman** and `podman compose`.

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/WOOWTECH/Woow_podman_nginxpm.git
   cd Woow_podman_nginxpm
   ```

2. **Configure environment variables (optional):**
   ```bash
   cp .env.example .env
   # Edit .env to customize ports or timezone if needed
   nano .env
   ```

3. **Start the service:**
   ```bash
   docker compose up -d
   ```
   Or with Podman:
   ```bash
   podman compose up -d
   ```

4. **Access the Admin UI:**
   - URL: `http://<your-server-ip>:81`
   - Default Email: `admin@example.com`
   - Default Password: `changeme`
   - **Change the default credentials immediately after first login!**

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NPM_HTTP_PORT` | `80` | Host port for HTTP traffic |
| `NPM_HTTPS_PORT` | `443` | Host port for HTTPS traffic |
| `NPM_ADMIN_PORT` | `81` | Host port for Admin UI |
| `TZ` | `Asia/Taipei` | Container timezone |

### Common Commands

| Command | Description |
|---------|-------------|
| `docker compose up -d` | Start service in background |
| `docker compose down` | Stop and remove container |
| `docker compose logs -f` | Follow live logs |
| `docker compose restart` | Restart service |
| `docker compose pull` | Pull latest image |
| `docker compose up -d --pull always` | Update and restart |

### Data Persistence

Data is stored in two Docker named volumes:

| Volume | Purpose | Container Path |
|--------|---------|----------------|
| `npm-app-data` | NPM configuration, proxy hosts, access lists, SQLite database | `/data` |
| `npm-letsencrypt` | SSL certificates from Let's Encrypt | `/etc/letsencrypt` |

### Backup & Restore

#### Volume Backup

```bash
# Stop service first
docker compose down

# Backup all volumes
docker run --rm -v npm-app-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/npm-app-data_$(date +%Y%m%d).tar.gz -C /data .

docker run --rm -v npm-letsencrypt:/data -v $(pwd):/backup alpine \
  tar czf /backup/npm-letsencrypt_$(date +%Y%m%d).tar.gz -C /data .

# Restart service
docker compose up -d
```

#### Volume Restore

```bash
docker compose down

docker run --rm -v npm-app-data:/data -v $(pwd):/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/npm-app-data_YYYYMMDD.tar.gz -C /data"

docker run --rm -v npm-letsencrypt:/data -v $(pwd):/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/npm-letsencrypt_YYYYMMDD.tar.gz -C /data"

docker compose up -d
```

### Troubleshooting

| Issue | Diagnostic Command | Solution |
|-------|-------------------|----------|
| Container won't start | `docker compose logs app` | Check environment variables in `.env` |
| Port 80/443 already in use | `sudo ss -tlnp \| grep ':80'` | Change `NPM_HTTP_PORT` / `NPM_HTTPS_PORT` in `.env` |
| Port 81 already in use | `sudo ss -tlnp \| grep ':81'` | Change `NPM_ADMIN_PORT` in `.env` |
| Cannot access admin UI | `docker compose ps` | Ensure container is running |
| SSL certificate issues | `docker compose logs app` | Check DNS points to server, ports 80/443 open |

### How It Works — Setup Guide

1. **Single container startup** — `docker compose up -d` pulls the NPM image and starts the container with the configured ports and volumes.

2. **Built-in SQLite database** — NPM automatically creates and manages a SQLite database at `/data/database.sqlite` inside the container. No external database configuration needed.

3. **First-time initialization** — On first launch, NPM creates its database schema and a default admin user (`admin@example.com` / `changeme`).

4. **Proxy management** — Access the web UI on port 81 to configure reverse proxy hosts, SSL certificates, and access control rules.

5. **SSL certificates** — Add proxy hosts with Let's Encrypt SSL. NPM handles certificate issuance and auto-renewal. Certificates are persisted in the `npm-letsencrypt` volume.

---

## 繁體中文

### 什麼是 Nginx Proxy Manager？

[Nginx Proxy Manager](https://nginxproxymanager.com/)（NPM）是一套反向代理管理系統，提供以下功能：

- **網頁管理介面** — 透過直覺的網頁介面（連接埠 81）管理代理主機、SSL 憑證及存取控制清單
- **反向代理（Reverse Proxy）** — 依據網域名稱將 HTTP/HTTPS 流量路由到內部服務
- **免費 SSL 憑證** — 自動取得及續約 Let's Encrypt SSL 憑證
- **存取控制清單（Access Lists）** — 透過 IP 或 HTTP 驗證限制服務存取
- **重導向主機（Redirection Hosts）** — 將網域重導向至其他 URL
- **404 主機** — 為未使用的網域設定自訂 404 頁面
- **串流轉發（Streams）** — 支援非 HTTP 服務的 TCP/UDP 連接埠轉發

### 為什麼使用 SQLite（不需要外部資料庫）？

NPM **預設使用 SQLite** — 資料庫檔案存放在 `/data` 磁碟區內。這是大多數部署的建議方式，因為：

- NPM 儲存的資料量很小（代理主機設定、SSL 憑證資訊、存取清單）
- 不需要額外的容器、記憶體或密碼管理
- 少一個需要監控和維護的服務
- 對一般的反向代理工作負載完全穩定可靠

> **備註：** NPM 也支援 PostgreSQL 和 MySQL/MariaDB 作為可選的外部資料庫後端，但 SQLite 能應付絕大多數的使用情境。

### 系統架構

```
┌──────────────────────────────────────────────┐
│            Docker Compose 服務堆疊            │
│                                              │
│  ┌──────────────────────────────────────┐    │
│  │   Nginx Proxy Manager（app 服務）     │    │
│  │   連接埠：80、443、81                 │    │
│  │   映像檔：jc21/nginx-proxy-manager   │    │
│  │   資料庫：SQLite（內建）              │    │
│  └──────────────────────────────────────┘    │
│                                              │
│  磁碟區：npm-app-data、npm-letsencrypt       │
└──────────────────────────────────────────────┘
```

### 檔案結構

```
.
├── docker-compose.yml    # 主要編排檔案
├── .env.example          # 環境變數範本
├── .env                  # 你的設定檔（不納入版控）
├── .gitignore            # Git 忽略規則
└── README.md             # 本說明文件
```

### 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能，可透過 GitHub Repository 網址快速部署本專案。

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#一鍵部署至-portainer)

#### 使用 Git Repository 部署（推薦）

1. 登入你的 Portainer 管理介面
2. 進入 **Stacks** → **Add stack**
3. 選擇 **Repository**
4. 填入以下資訊：

   | 欄位 | 值 |
   |------|-----|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_nginxpm` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. 點擊 **Deploy the stack**

#### 使用 Web Editor 部署

1. 複製 `docker-compose.yml` 的 Raw URL：

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_nginxpm/podman/docker-compose.yml
   ```

2. 登入 Portainer → **Stacks** → **Add stack** → **Web editor**
3. 使用 `curl` 或瀏覽器取得上述 URL 的內容，貼入編輯器
4. 設定環境變數（參考 `.env.example`）
5. 點擊 **Deploy the stack**


### 系統需求

| 需求項目 | 最低版本 |
|---------|---------|
| Docker Engine | 20.10+ |
| Docker Compose | v2.0+ |
| 記憶體（RAM） | 512 MB |
| 磁碟空間 | 1 GB |

> **備註：** 本方案亦相容 **Podman** 與 `podman compose`。

### 快速開始

1. **複製儲存庫：**
   ```bash
   git clone https://github.com/WOOWTECH/Woow_podman_nginxpm.git
   cd Woow_podman_nginxpm
   ```

2. **設定環境變數（選擇性）：**
   ```bash
   cp .env.example .env
   # 如需調整連接埠或時區，請編輯 .env
   nano .env
   ```

3. **啟動服務：**
   ```bash
   docker compose up -d
   ```
   使用 Podman：
   ```bash
   podman compose up -d
   ```

4. **存取管理介面：**
   - 網址：`http://<你的伺服器 IP>:81`
   - 預設信箱：`admin@example.com`
   - 預設密碼：`changeme`
   - **首次登入後請立即更改預設帳號密碼！**

### 環境變數說明

| 變數名稱 | 預設值 | 說明 |
|----------|--------|------|
| `NPM_HTTP_PORT` | `80` | 主機的 HTTP 連接埠 |
| `NPM_HTTPS_PORT` | `443` | 主機的 HTTPS 連接埠 |
| `NPM_ADMIN_PORT` | `81` | 主機的管理介面連接埠 |
| `TZ` | `Asia/Taipei` | 容器時區 |

### 常用指令

| 指令 | 說明 |
|------|------|
| `docker compose up -d` | 在背景啟動服務 |
| `docker compose down` | 停止並移除容器 |
| `docker compose logs -f` | 即時追蹤日誌 |
| `docker compose restart` | 重新啟動服務 |
| `docker compose pull` | 拉取最新映像檔 |
| `docker compose up -d --pull always` | 更新映像檔並重新啟動 |

### 資料持久化

資料儲存於兩個 Docker 具名磁碟區：

| 磁碟區名稱 | 用途 | 容器內路徑 |
|-----------|------|-----------|
| `npm-app-data` | NPM 設定、代理主機、存取清單、SQLite 資料庫 | `/data` |
| `npm-letsencrypt` | Let's Encrypt SSL 憑證 | `/etc/letsencrypt` |

### 備份與還原

#### 磁碟區備份

```bash
# 先停止服務
docker compose down

# 備份所有磁碟區
docker run --rm -v npm-app-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/npm-app-data_$(date +%Y%m%d).tar.gz -C /data .

docker run --rm -v npm-letsencrypt:/data -v $(pwd):/backup alpine \
  tar czf /backup/npm-letsencrypt_$(date +%Y%m%d).tar.gz -C /data .

# 重新啟動服務
docker compose up -d
```

#### 磁碟區還原

```bash
docker compose down

docker run --rm -v npm-app-data:/data -v $(pwd):/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/npm-app-data_YYYYMMDD.tar.gz -C /data"

docker run --rm -v npm-letsencrypt:/data -v $(pwd):/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/npm-letsencrypt_YYYYMMDD.tar.gz -C /data"

docker compose up -d
```

### 疑難排解

| 問題 | 診斷指令 | 解決方式 |
|------|---------|---------|
| 容器無法啟動 | `docker compose logs app` | 檢查 `.env` 中的環境變數 |
| 連接埠 80/443 被占用 | `sudo ss -tlnp \| grep ':80'` | 修改 `.env` 中的 `NPM_HTTP_PORT` / `NPM_HTTPS_PORT` |
| 連接埠 81 被占用 | `sudo ss -tlnp \| grep ':81'` | 修改 `.env` 中的 `NPM_ADMIN_PORT` |
| 無法存取管理介面 | `docker compose ps` | 確認容器正在執行 |
| SSL 憑證問題 | `docker compose logs app` | 確認 DNS 指向伺服器，連接埠 80/443 已開啟 |

### 架設方式說明

1. **單一容器啟動** — `docker compose up -d` 拉取 NPM 映像檔並以設定的連接埠和磁碟區啟動容器。

2. **內建 SQLite 資料庫** — NPM 自動在容器內的 `/data/database.sqlite` 建立並管理 SQLite 資料庫，不需要任何外部資料庫設定。

3. **首次初始化** — 首次啟動時，NPM 會自動建立資料庫結構及預設管理帳號（`admin@example.com` / `changeme`）。

4. **代理管理** — 透過連接埠 81 的網頁介面設定反向代理主機、SSL 憑證及存取控制規則。

5. **SSL 憑證** — 新增代理主機時可啟用 Let's Encrypt SSL。NPM 會處理憑證的簽發和自動續約。憑證存放在 `npm-letsencrypt` 磁碟區。

---

### AI Deployment Guide / AI 部署指南

For AI-assisted deployment, here are the structured specifications:

```yaml
# Service Expectations
services:
  app:
    expected_state: running
    health_indicator: HTTP 200 on port 81
    startup_time: ~30 seconds
    database: SQLite (built-in, no external DB needed)

# Optional Environment Variables (all have defaults)
optional:
  - NPM_HTTP_PORT   # default: 80
  - NPM_HTTPS_PORT  # default: 443
  - NPM_ADMIN_PORT  # default: 81
  - TZ              # default: Asia/Taipei

# Volumes
volumes:
  npm-app-data: /data (config + SQLite DB)
  npm-letsencrypt: /etc/letsencrypt (SSL certs)

# External Ports
ports: [80, 443, 81]
```

---

## Other deployment platforms / 其他部署平台

This repository (`Woow_podman_nginxpm`) hosts the Docker/Podman Compose deployment.
Nginx Proxy Manager is also available on other platforms — each maintained in its
own repository:

本倉庫（`Woow_podman_nginxpm`）提供 Docker/Podman Compose 部署方案。
Nginx Proxy Manager 亦支援其他平台，各平台維護於獨立倉庫：

| Platform / 平台 | Repository / 倉庫 |
|---|---|
| K3s / Kubernetes (Helm chart) | [Woow_k3s_nginxpm](https://github.com/WOOWTECH/Woow_k3s_nginxpm) |
| Home Assistant add-on | [Woow_ha_nginxpm](https://github.com/WOOWTECH/Woow_ha_nginxpm) |
