# agent2api-ops —— 构建 / 部署脚本（通用版，不写死路径）

| 文件 | 用途 | 跑在哪 |
| --- | --- | --- |
| `build.ps1` | 构建镜像 → 导出 `out/agent2api-<tag>.tar.gz` →（可选）上传+上线 | Windows |
| `update.sh` | 导入镜像 → 备份 data → 换 tag → 重启 → 健康检查 → 清旧镜像 | 服务器 |
| `docker-compose.yml` | 单容器：网关 3065 / 面板 3066（只绑回环） | 服务器 |
| `.env.example` | 复制成 `.env`：`IMAGE_TAG` + 管理员账号密码 | 服务器 |
| `nginx-snippet.conf` | `/v1` 反代（关缓冲，SSE 必需） | 服务器 |

## 三个「不写死」

| 以前 | 现在 |
| --- | --- |
| 部署目录写死 `/opt/agent2api` | 默认 = **脚本自己所在的目录**，`DEPLOY_DIR=/别的/目录` 可覆盖 |
| 包名要手打全（含 UUID） | 不带参数就**自动用本目录最新的 `*.tar.gz`**；包随便改名都没关系 |
| tag 要手填 | 从 `docker load` 的输出 `Loaded image: agent2api:<tag>` 里**自动读** |

## 服务器上怎么用

```bash
cd ~/agent2api      # 放 update.sh / docker-compose.yml / .env / 镜像包的目录
bash update.sh                        # 一条到底：自动找包、自动取 tag
bash update.sh 某个包.tar.gz           # 指定包，tag 照样自动
bash update.sh 某个包.tar.gz <tag>     # 两个都指定
sudo bash update.sh                   # ubuntu 不在 docker 组时
```

`.env` 必须有（`cp .env.example .env` 后填 `A2A_ADMIN_PASSWORD`），否则脚本直接报错退出。

回滚：把 `.env` 的 `IMAGE_TAG` 改回旧 tag → `docker compose up -d`（旧镜像还在本地）。

## 本地怎么构建

```powershell
cd F:\api-network\agent2api-ops
.\build.ps1                            # 仓库默认取同级目录的 Agent2API
.\build.ps1 -BuildUi                   # 改了 ui-islands/src 或 i18n/i18n-src 时必带
.\build.ps1 -DryRun                    # 只打印要执行的命令
.\build.ps1 -Upload -Server root@IP -RemoteDir /home/ubuntu/agent2api
```

- `-Platform linux/arm64`：服务器是 ARM 时用（先 `uname -m`）。
- 打包是把 `docker save` 的字节流直接 gzip。**别改成 `tar -czf 文件`** —— 那会压出嵌套包，
  `docker load` 只回一句 `unrecognized image format`（2026-10-26 踩过）。脚本末尾有自检。

## 排错要点

| 现象 | 处理 |
| --- | --- |
| `docker load` 报 `unrecognized image format` | 包是嵌套的旧包，用 `build.ps1` 重打或重传 |
| `没从 docker load 输出里读到镜像名` | 同上，或镜像名不是 `agent2api:*`（脚本会提示并 `docker tag` 改名） |
| `permission denied ... docker.sock` | `sudo bash update.sh` 或把用户加进 docker 组 |
| 健康检查失败 | 看脚本打印的 60 行日志；常见是端口占用、`data` 权限、`AGENT2API_PANEL_PORT` 与主端口相同 |
| 面板打不开 | 只绑 `127.0.0.1:3066`，先建隧道 `ssh -L 3066:127.0.0.1:3066 ...` |
| 流式回复卡住 | nginx 没关 `proxy_buffering` |
| 更新后账号全丢 | 只搬了 `agent2api.db` 没搬 `account.key`，两个必须一起走 |
