# Nginx Proxy Manager on rootless Podman（Quadlet）

[![Podman](https://img.shields.io/badge/Podman-%E2%89%A54.4%20rootless-892CA0)](https://podman.io)
[![Quadlet](https://img.shields.io/badge/units-Quadlet%20%2B%20systemd-orange)](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
[![NPM](https://img.shields.io/badge/nginx--proxy--manager-2.15.1-brightgreen)](https://nginxproxymanager.com/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[English](README.md) · **繁體中文**

[Nginx Proxy Manager](https://nginxproxymanager.com/)（NPM）打包成 **rootless Podman** 上的 **Quadlet + systemd** 部署：反向代理主機、Let's Encrypt 憑證與存取控制清單，由使用者的 systemd 監管（`Restart=always` + lingering），容器掛掉會自動重啟，重開機也會自己回來。

> **Docker / compose 使用者**：本倉庫從這個版本起只提供 Quadlet。最後一個含 `docker-compose.yml` 的 commit 標記為 [`compose-final`](https://github.com/WOOWTECH/Woow_podman_nginxpm/tree/compose-final)：
> `git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_nginxpm.git`。該路徑不再維護。

---

## 提供什麼

| | |
|---|---|
| **容器** | `npm-app`，映像 `docker.io/jc21/nginx-proxy-manager:2.15.1`（釘選；digest 由 smoke 測試驗證） |
| **連接埠** | HTTP 與 HTTPS 綁在所有網卡，可再加額外的主機埠，**管理介面只綁 `127.0.0.1`** |
| **資料** | 沿用既有的具名 volume `npm-app-data`（資料庫、代理主機、存取清單、JWT 金鑰）與 `npm-letsencrypt` |
| **網路** | 自己的 `npm-network`，加上 pi-web front 選用的 `pi-agent` 網路 |
| **監管** | Quadlet 產生的 `systemd --user` unit：`Restart=always`，健康檢查用映像內建的 `/usr/bin/check-health` |
| **腳本** | 安裝、升級（含回滾）、備份、還原、移除，以及從 compose／手動部署遷移 |

---

## 系統需求

- rootless Podman ≥ 4.4（Quadlet）；在 Podman 4.9.3 / systemd 255（Ubuntu 24.04）測試，也就是 WOOWTECH 主機的版本。
- **低位連接埠**：rootless Podman 要綁 80/443，主機必須允許：

  ```bash
  cat /proc/sys/net/ipv4/ip_unprivileged_port_start        # 必須 <= 80
  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-rootless-podman-ports.conf
  sudo sysctl --system
  ```

  `install.sh` 會檢查並印出上面這兩行；它自己從不使用 `sudo`。不想動 sysctl 的主機可以改用 8080/8443（`NPM_HTTP_PORT`、`NPM_HTTPS_PORT`），此時 `NPM_ADMIN_PORT` 也要一起改：綁在 `127.0.0.1` 並不會讓 81 埠豁免這個 sysctl。
- lingering，讓 unit 不需登入 session 也能執行：`install.sh` 會啟用；polkit 擋下來時請執行 `sudo loginctl enable-linger <user>`。

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nginxpm.git
cd Woow_podman_nginxpm
./scripts/install.sh                      # 有 pi-agent 的主機加上 --with-pi-web-front
```

第一次執行會從 `config/npm.env.example` 建立 `~/.config/npm/npm.env`（權限 0600），用它渲染 unit，以 Quadlet generator 與 `systemd-analyze --user verify` 檢查，拉取釘選的映像，安裝並啟動 unit，最後跑 `tests/smoke.sh`。`git pull` 或改設定後重跑，只會重啟真正有變的東西。

接著**透過 loopback** 開管理介面，並立刻改掉預設帳密：

```bash
ssh -L 8181:127.0.0.1:81 <user>@<host>     # 然後開 http://127.0.0.1:8181/
# 全新 volume 的預設帳密：admin@example.com / changeme
```

其他進入方式：tailnet 的 `tailscale serve --tcp=81 tcp://127.0.0.1:81`，或在管理介面前面再放一個掛了 access list 的 NPM proxy host。管理埠永遠不會發佈到區網介面。

### 設定

`~/.config/npm/npm.env` 只有安裝與升級腳本會讀；它們把值渲染進 unit（決策 D2），systemd 與 Podman 都不讀這個檔。改完值再跑一次 `./scripts/install.sh`。這個檔不含任何機密：NPM 的管理者帳號、存取清單與金鑰都放在 `npm-app-data` 裡。

| Key | 預設 | 作用 |
|---|---|---|
| `NPM_TZ` | `Asia/Taipei` | 容器時區 |
| `NPM_HTTP_PORT` | `80` | HTTP listener 的主機埠，綁所有網卡 |
| `NPM_HTTPS_PORT` | `443` | HTTPS listener 的主機埠，綁所有網卡 |
| `NPM_ADMIN_PORT` | `81` | 管理介面的主機埠，永遠綁 `127.0.0.1` |
| `NPM_EXTRA_HTTP_PORTS` | *(空)* | 導向同一個 HTTP listener 的額外主機埠，以空白分隔（例如 Cloudflare 路由指向 `localhost:30142` 時填 `30142`） |
| `NPM_PI_WEB_FRONT` | `false` | 見下節；`install.sh --with-pi-web-front` 會設定它 |

## pi-web front

[Woow_podman_pi_agent_package](https://github.com/WOOWTECH/Woow_podman_pi_agent_package) 把 pi-web 發佈在 `127.0.0.1:30141`，本身不帶 proxy。pi-web 會拒絕任何非 loopback、非裸 IP 的 `Host`，以及對不起來的 `Origin`；所以直接把瀏覽器的 Host 轉過去的 proxy host，UI 畫得出來，但每個 `/api/*` 都會回 `403 Untrusted API request`。NPM 自己在 `location /` 內送出 `proxy_set_header Host $host`，而 nginx 不會把 server 層的 `proxy_set_header` 繼承進有自己設定的 location，所以從 Advanced 分頁蓋掉是沒用的。

因此 `./scripts/install.sh --with-pi-web-front` 會：

- 加入 `pi-agent` 網路（對 `pi-agent-network.service` 只有順序關係，不是硬相依；並加一個 `ExecStartPre` 在 pi-agent 套件沒安裝時自行建立網路），NPM 就能用名稱連到 `pi-web:30141`——rootless bridge 連不到主機的 `127.0.0.1`；
- 安裝 `~/.config/npm/pi-web-front/proxy.conf`，覆蓋映像內的 `conf.d/include/proxy.conf`：內容就是原廠檔案，只有 `Host` 與 `Origin` 改成由兩個 map 取值；
- 安裝 `maps.conf` 定義那兩個 map，**以 `$server`（proxy host 的 Forward Hostname）為 key**。轉給 `pi-web` 的就得到 `Host: localhost` 與空的 `Origin`，其他上游維持原廠行為。檔案裡沒有任何跟特定部署綁定的東西。

然後建立 proxy host：Forward Hostname 填 **`pi-web`**、Forward Port `30141`、開啟 Websockets，並掛上 **access list**——pi-web 自己沒有任何驗證，而它的瀏覽器終端機等同於主機帳號的 shell。

兩個掛載刻意是讀寫：NPM 2.15.1 啟動時會對 `/etc/nginx/conf.d` 跑 `chown -R`，`:ro` 會讓它以 EROFS 失敗。`tests/pi-web-front.sh`（以及 `pi-web-front` workflow）會在新版 NPM 把原廠 `proxy.conf` 改到超出那兩行時讓建置失敗。

這個漂移檢查**不能**證明改寫端到端有效，它只證明我們的檔案仍是「原廠檔案 + 兩行」。真正的證明在主機上：建立 `~/.config/npm/smoke-pi.netrc`（0600，一行 `machine <pi 主機名> login <帳號> password <密碼>`，用 access list 的帳密），然後執行

```bash
./tests/smoke.sh --pi-host pi.example.com
```

它會先不帶帳密掃過該路由（每一個回應都必須是驗證挑戰，不可以是 502，也不可以是 200），再帶著帳密要求 `/api/models`，必須回 200；回 403 就代表 Host/Origin 改寫沒有生效。帳密不會被印出來。這個檢查請當成這層 front 任何變更前後的放行判準。

## 升級

```bash
git pull
./scripts/upgrade.sh
```

拉取新釘選的映像，啟用 front 時先過 `proxy.conf` 檢查，做一次冷備份，安裝並跑 smoke。新版本沒有變 healthy 時，會還原先前的 unit **與兩個 volume**（NPM 的資料庫遷移只能往前），並以先前的映像重啟。

升版本要在同一個 commit 改 `quadlet/npm-app.container` 的**兩行**：`Image=` 與它上面的 `#   sha256:…` index digest — `tests/smoke.sh` 會拿它跟實際執行中的映像核對。忘了改 digest，smoke 就會失敗，升級也會自己回滾。

## 備份與還原

```bash
./scripts/backup.sh                       # 冷備份：停機數秒
./scripts/backup.sh --hot
./scripts/restore.sh ~/backups/npm/<timestamp>
```

每次執行會寫一個時間戳目錄，內含兩個 volume 的匯出、`~/.config/npm` 的副本，以及每個檔案的 `.sha256`；檔案 0600、目錄 0700。裡面有 access list 的密碼雜湊與 JWT 金鑰，請當成機密看待。

## 移除

```bash
./scripts/uninstall.sh                    # 停止並移除 unit；保留兩個 volume
./scripts/uninstall.sh --purge --yes      # 連 volume 一起刪（刪之前會先匯出）
```

一般的移除會保留兩個 volume、映像與 `~/.config/npm/npm.env`；本套件裝在 `~/.config/npm/pi-web-front/` 下的檔案會跟著 unit 一起移除，重新安裝時會再寫回來。`--purge` 永遠不會動 `pi-agent` 網路，那是 pi-agent 套件的東西。

## 從既有的 compose／手動部署遷移

`scripts/migrate-legacy.sh` 會**就地**接管正在跑的 `npm-app`：同樣的 volume、同樣的連接埠、同樣的網路，憑證不用重簽。

```bash
./scripts/migrate-legacy.sh --dry-run              # 顯示它會推導出什麼、會做什麼
./scripts/migrate-legacy.sh --pi-host pi.example.com
# ... 驗證 ...
./scripts/migrate-legacy.sh --rollback             # 觀察期內隨時可回滾
```

它會讀舊容器（連接埠、網路、TZ、volume）與啟動它的 unit，據此寫出 `~/.config/npm/npm.env`，記錄基準檢查，備份（inspect、CreateCommand、unit 檔、compose 目錄），然後在一次短停機內：停止並停用舊 unit、冷匯出兩個 volume、把容器改名為 `npm-app-legacy-<date>`（Quadlet 的 `--replace` 會刪掉同名容器），再執行 `install.sh`。安裝失敗會自動回滾。過程不刪任何東西：觀察期結束後，再自行移除舊容器、舊 unit 檔與舊的 compose 網路。

### 何時會拒絕：血統不同的主機

`migrate-legacy.sh` 只接管兩種 `npm-app`：podman-compose 專案，以及手工的 `podman run`。
遇到下列情況會**直接拒絕**（不是警告後繼續）：

- **找不到任何啟停 `npm-app` 的 unit，但有 user unit 執行 pre-Quadlet 部署樹裡的程式**
  （該目錄有 `.deployed-commit`，或有 `scripts/deploy.sh` 而沒有 `scripts/lib/quadlet-lib.sh`）。
  拒絕訊息會列出那些 unit 與該目錄。硬遷移會讓它們仍然 enabled，下次開機或 timer 觸發時
  會重跑該樹的 `deploy.sh`，與 Quadlet 容器搶同一組連接埠與 volume。
- **`npm-app` 接在 Quadlet unit 不會加入的網路上。** unit 只加入 `npm.network`，以及透過
  `quadlet/fragments/pi-web-front.conf` 加入的 `pi-agent`。第三個網路必須先加進 `quadlet/`：
  nginx 在載入設定時解析 upstream 名稱，少一個網路要到下次 reload 才會爆，屬於無聲失敗。

在那種目錄裡執行本套件的任何腳本都會被拒絕（`ql_require_own_lineage`）：請改用本 repo 的全新
clone 執行，而且**不要刪除**主機上的那棵樹——有正在運作的 systemd unit 會執行裡面的腳本。
以上行為由 `tests/host-tree.sh` 固定。

## 安全性

- **管理介面永遠不會發佈到 LAN 介面。** 它綁在 `127.0.0.1:81`；請用 `ssh -L`、tailnet 的 `tailscale serve --tcp=81`，或一個掛了 access list 的 NPM proxy host 連進去。全新 volume 的預設帳密是 `admin@example.com` / `changeme`，第一次登入就要改掉。
- **擋在 pi-web 前面的 proxy host 一定要掛 access list。** pi-web 自己沒有任何驗證，而它的瀏覽器終端機等同於跑這些容器的帳號的 shell，所以 access list 是這條路由與那個 shell 之間唯一的東西。對外主機名請再加一層 Cloudflare Access 作為獨立的第二層。上面那個帶帳密的 smoke 檢查，就是用來證明路由仍會要求驗證。
- **本倉與 unit 檔裡沒有任何機密。** NPM 的管理者帳號、access list、憑證與 JWT 金鑰都在 `npm-app-data` volume 裡，`~/.config/npm/npm.env` 只有連接埠與時區。
- **備份就是機密**：volume 匯出含有 access list 的密碼雜湊與 JWT 金鑰，它們以 0700 目錄下的 0600 檔案寫出，請維持這個權限。`~/.config/npm/smoke-pi.netrc` 裝的是真實帳密，同理。
- **rootless，所以容器逃逸落到的是一般帳號**，容器也沒有額外 capability。低位連接埠來自 sysctl，不是 `sudo`，也不是對 podman 執行檔 `setcap`。
- 映像同時以 tag 與 index digest 釘選，每次（重）啟動後都會驗證。

## 疑難排解

| 症狀 | 原因與解法 |
|---|---|
| `install.sh` 拒絕執行：legacy unit 管著 npm-app | 改用 `scripts/migrate-legacy.sh`，它會保留舊 unit 與容器供回滾 |
| `install.sh` 拒絕執行：低位埠綁不了 | 設定 `net.ipv4.ip_unprivileged_port_start`，或在 `npm.env` 改用高位埠 |
| 指向 pi-web 的 proxy host 在 `/api/*` 回 403 | Forward Hostname 不是 `pi-web`，或沒有啟用 front |
| proxy host 回 502 | NPM 不在上游的網路上，或上游沒在跑 |
| 改過掛載後 npm-app 起不來 | pi-web-front 的掛載必須維持讀寫（NPM 的 `chown -R` 會撞到 EROFS） |
| 區網連不到管理介面 | 設計如此：用 `ssh -L`、tailnet 轉發，或掛 access list 的 proxy host |
| 埠明明沒人用，`install.sh` 卻說被占用 | 有其他服務綁著：`ss -tlnp` |

## 目錄結構

```
quadlet/
  npm-app.container        容器 unit，主機專屬值以 @@TOKEN@@ 表示
  npm.network              NetworkName=npm-network
  npm-app-data.volume      VolumeName=npm-app-data      （沿用既有資料）
  npm-letsencrypt.volume   VolumeName=npm-letsencrypt
  fragments/pi-web-front.conf   NPM_PI_WEB_FRONT=true 時附加的段落
  render-vars              install.sh 唯一可代入的變數清單
config/
  npm.env.example          -> ~/.config/npm/npm.env（0600）
  pi-web-front/*.conf      -> ~/.config/npm/pi-web-front/（Host/Origin 轉寫）
scripts/
  install.sh upgrade.sh uninstall.sh backup.sh restore.sh migrate-legacy.sh
  common.sh render-args.sh
  lib/quadlet-lib.sh       vendored 的 WOOWTECH Quadlet 函式庫（不要改；CI 會檢查雜湊）
  lib/quadlet-lib.versions 版本帳本；tests/lib-version.sh 驗證上面那份函式庫
                           真的是它自稱的版本（CI）
tests/
  dryrun.sh dryrun.local.sh   渲染 + quadlet -dryrun + systemd-analyze verify（CI）
  inspect-templates.sh     migrate-legacy.sh 從擷取下來的 `podman inspect` 推導出什麼
  gotmpl.py                以 podman Go template 的規則算出 --format 的輸出
  smoke.sh                 真實主機上的安裝後檢查
  pi-web-front.sh          對映像比對 proxy.conf 是否漂移
  fixtures/                各主機的設定變體，以及 dry-run 需要的其他套件 unit
.github/workflows/         quadlet-ci.yml（dry-run、shellcheck）、pi-web-front.yml
```

## 其他部署平台

| 平台 | 倉庫 |
|---|---|
| K3s / Kubernetes（Helm chart） | [Woow_k3s_nginxpm](https://github.com/WOOWTECH/Woow_k3s_nginxpm) |
| Home Assistant add-on | [Woow_ha_nginxpm](https://github.com/WOOWTECH/Woow_ha_nginxpm) |
| Docker / compose | 本倉庫的 `compose-final` tag（不再維護） |

## 授權

MIT
