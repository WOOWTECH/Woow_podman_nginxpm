# 安全的 NPM 維運手冊（繁體中文）

## 需求與固定拓撲

使用無 root 的 Podman **4.9.3**、直接執行 `podman-compose` **1.0.6**，並準備 Python 3、curl、tar/gzip、sha256sum、`ss`、`flock` 與使用者 systemd。不可變的 NPM 版本、digest 與驗證流程見 [image-pin.md](image-pin.md)。不得使用浮動映像或未審查的 digest。

公開監聽固定為 `0.0.0.0:80` 與 `0.0.0.0:443`；管理介面僅限 `127.0.0.1:18081`，對應容器連接埠 `81`。主機連接埠 `81` 不存在，`.env` 也無法覆寫連接埠。無 root 綁定要求 `net.ipv4.ip_unprivileged_port_start <= 80`。若需開機啟動，sysctl 與使用者 lingering 必須由管理員設定，腳本不會代為提權。

精確資源清單為容器 `npm-app`、網路 `npm-network`、磁碟區 `npm-app-data` 與 `npm-letsencrypt`。每項都必須有 `io.woow.nginxpm.managed=true` 及本 checkout 的精確不透明 owner 標籤。既有資源若缺少或不符標籤，任何修改前都會以 fail-closed 方式拒絕。

## 第一次部署與憑證

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env                 # 僅修改 TZ 與 NPM_ADMIN_EMAIL
./scripts/deploy.sh
./scripts/verify.sh
```

`.env` 僅允許 `NPM_IMAGE`、`TZ` 與 `NPM_ADMIN_EMAIL`，映像必須等於已審查 pin。部署會先驗證版本、無 root、低連接埠、Compose render 與 ownership，才會 pull/start。Podman 4.9 可能無法把自動 health scheduler 連到使用者 systemd，因此部署與驗證會主動執行 `podman healthcheck run npm-app`，並同時要求命令成功退出及 inspect 狀態為 `healthy`。接著等待 loopback API readiness，並以密碼學安全亂數建立管理憑證。舊版仍透過 API 輪替上游初始憑證。v2.15.1 若產生、初始與可恢復過渡憑證全遭拒絕，部署會停止常態容器，以唯讀方式證明 `user` 與 `auth` 都是空的，才啟動使用精確映像、磁碟區與網路的暫時 bootstrap。其管理埠僅綁 loopback、機密 env file 為 `600`，並以 `--log-driver=none` 避免保存上游明文 setup 訊息。暫時容器與 env file 刪除後，才重建不含 `INITIAL_ADMIN_*` 的常態 Compose 容器；中斷的轉換會在下次 deploy 清理並收斂。任何不明確或非空狀態都 fail closed。

操作者憑證位於 `.secrets/npm-admin.env`；目錄權限 `700`、檔案 `600`。僅在必要時於私密本機終端查看，不要把它印成診斷資訊。**絕不可把憑證貼到日誌、命令列參數、聊天、issue 或支援工單。** 正常腳本輸出只有階段名稱。

## 日常生命週期

所有命令皆可重複執行，並共用單一 lifecycle lock：

```bash
./scripts/deploy.sh
./scripts/verify.sh
./scripts/backup.sh
./scripts/restore.sh backups/npm-backup-YYYYMMDDTHHMMSSZ.tar.gz
./scripts/remove.sh                    # 移除容器/網路，保留資料、憑證與備份
./scripts/remove.sh --purge-data --yes # 再刪除精確自有磁碟區與本機憑證/狀態，仍保留備份
```

驗證會檢查精確標籤、running/healthy、精確綁定/監聽與 mount、loopback readiness、產生憑證成功、初始密碼拒絕，以及容器日誌沒有已知憑證 canary。

## 使用者 systemd

```bash
./scripts/install-systemd.sh
systemctl --user status nginx-proxy-manager.service
systemctl --user status nginx-proxy-manager-healthcheck.timer
systemctl --user restart nginx-proxy-manager.service
```

安裝器會驗證精確執行版本及 rootless/低連接埠前提，以絕對路徑原子寫入主服務、由 timer 觸發的 health oneshot 及 timer；daemon-reload 後 enable 主服務與 timer。主服務每次成功 start／restart 時，都會在部署成功後由 `ExecStartPost` 啟動或重新掛載 timer。無主服務依賴的 timer 會定期觸發精確自有的 `npm-app` healthcheck oneshot；oneshot 仍排在主服務之後並綁定主服務。停止主服務時會先停止 timer 與 health oneshot，再移除限定範圍的 stack；health oneshot 不會被直接 enable 或管理。安裝器不會提權。若 `loginctl show-user "$USER" -p Linger` 顯示 `no`，請管理員啟用 lingering。

## 備份、還原與災難復原

備份會短暫停止健康且執行中的容器，把兩個磁碟區放在固定 archive 根 `data/` 與 `letsencrypt/`，並在權限 `700` 的目的目錄建立均為 `600` 的 archive、外部 manifest 與 SHA-256 sidecar。完整集合會在發布前驗證，checksum 最後發布；發布或重新啟動失敗時會移除整個集合。trap 會恢復原本 running/stopped 狀態，每個時間戳建立新備份。

管理帳密刻意**不放入**備份。請把 `.secrets/npm-admin.env` 當作權限 `600` 的操作者資料分開保管，絕不可附在備份工單。還原要求三個同 basename、由呼叫者擁有且權限 `600` 的檔案，以及格式、已審查映像與 owner 全部一致。系統會先把完整集合複製進新建的 `700` 私密目錄、改成唯讀，之後只驗證及解開這份副本。驗證會限制 sidecar/archive bytes、raw expansion、成員數、路徑長度、單一與累積 logical size，並拒絕 sparse file、絕對路徑、traversal、重複/越界成員、hardlink、device、FIFO、socket 及不安全的 symlink。`letsencrypt/` 內的相對 symlink 不得成為其他路徑的 ancestor，且必須解析至已封存一般檔案。複製、解開與 rollback snapshot 前都會檢查可用空間。

驗證後才建立 rollback snapshot 並替換兩棵資料樹；啟動時會執行 readiness、帳密與完整 verify。還原失敗會逐項報告 rollback 的 stop、mount、delete、extract 與 restart 結果；部分 rollback 後絕不重新啟動，並在所報告的 `.state/restore-rollback.*` 路徑保留 snapshot 及印出人工復原命令。在兩個磁碟區都確認復原前請保留該目錄。`--start` 可啟動原先停止的服務。

災難復原時，把 repository 放回相同 canonical path（owner identity 綁定路徑），建立精確且私密的 `.env`、還原分開保管的 credential file、先 deploy 空的自有資源，再執行驗證還原。絕不可直接解壓至 live volume。不同 owner/path 會刻意遭拒，請勿用重新貼標籤繞過。

## 僅 tailnet 可管理與遠端 gate

先驗證已安裝 Tailscale CLI：

```bash
tailscale version
tailscale serve --help
tailscale serve --bg --tcp 18081 tcp://127.0.0.1:18081
tailscale serve status --json
```

forward target 必須精確為 `tcp://127.0.0.1:18081`，絕不可指向 LAN；開放 LAN firewall 不是替代方案。由真正分離的 tailnet/LAN client 執行：

```bash
RUN_LIVE_TESTS=1 RUN_REMOTE_LIVE_TESTS=1 \
TAILNET_TEST_SSH='user@tailnet-client' LAN_TEST_SSH='user@lan-client' \
TAILSCALE_GATEWAY_HOST='gateway-tail-name' LAN_TARGET_HOST='server-lan-address' \
bash tests/live/remote_test.sh
```

Gate 要求 tailnet gateway 可存取管理介面、LAN 直接管理連線失敗，且公開 `80`/`443` 仍可達。timeout、模糊/相同主機或缺少 forwarding 都會失敗。

## 測試、升級與疑難排解

```bash
make test                              # 僅 unit/static，不修改 Podman、不使用 SSH
bash tests/run.sh gates                # 未 opt-in 時 live tier 明確 SKIP
RUN_LIVE_TESTS=1 bash tests/live/local_test.sh # 僅限可拋棄、版本相符主機；具破壞性
```

本機 live tier 涵蓋重複 deploy、verify、systemd restart、backup/restore、保留資料移除/再部署與重複 purge。絕不可在 production host 開啟。Remote test 還需要第二個明確 gate 與四個主機值。

升級時，依 [image-pin.md](image-pin.md) 重做官方 release、registry digest、獨立 pull、platform 與映像內 health probe 流程；審查並 commit 新 literal digest 後才能部署。故障時先執行 `./scripts/verify.sh`，檢查版本/sysctl/監聽衝突，再查看經遮蔽的容器狀態，不要查看或輸出 secret file，也不要啟用 tracing。生命週期命令不會接管外來名稱；ownership 衝突須由操作者在自動化外明確處理。
