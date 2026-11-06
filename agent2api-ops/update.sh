#!/usr/bin/env bash
# Agent2API 部署 / 更新脚本 —— 通用版，不写死任何路径、不依赖包的文件名。
#
#   bash update.sh                     # 全自动：用脚本所在目录里最新的 *.tar.gz，tag 从 docker load 输出里取
#   bash update.sh 包.tar.gz           # 指定包，tag 仍然自动取
#   bash update.sh 包.tar.gz <tag>     # 包和 tag 都指定
#   DEPLOY_DIR=/别的/目录 bash update.sh
#
# 目录规则：默认 = 脚本自己所在的目录（compose、.env、data/、backups/ 都在那里）。
# 换个地方部署？把 4 个文件一起拷过去，直接 `bash update.sh`，不用改任何东西。
#
# 它做的事：
#   1. docker load 导入镜像，并从输出里读回真实镜像名/标签（所以重命名包也没影响）；
#   2. 停容器 → 备份 ./data（SQLite 必须停机快照；首次为空则跳过）；
#   3. 把 .env 的 IMAGE_TAG 改成实际标签；
#   4. docker compose up -d（数据卷不动，账号/Key 都留着）；
#   5. 轮询 /health，失败就打印日志和回滚命令；
#   6. 清理旧备份与旧镜像（保留最近 N 份，可回滚）。
#
# 回滚：把 .env 的 IMAGE_TAG 改回旧标签 → docker compose up -d（旧镜像还在本地）。

set -euo pipefail

# ── 路径与参数（全部可覆盖，没有硬编码）──────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${DEPLOY_DIR:-$SCRIPT_DIR}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
KEEP_BACKUPS="${KEEP_BACKUPS:-7}"
PROXY_PORT="${PROXY_PORT:-3065}"

die() { echo "错误：$*" >&2; exit 1; }
say() { echo "==> $*"; }

PACKAGE="${1:-}"
TAG="${2:-}"

case "${PACKAGE:-}" in -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

[[ -f "$DEPLOY_DIR/docker-compose.yml" ]] \
  || die "$DEPLOY_DIR 里没有 docker-compose.yml（用 DEPLOY_DIR=... 指定部署目录）"
cd "$DEPLOY_DIR"

# ── 找包：没给就用本目录最新的 *.tar.gz / *.tar ─────────────────
if [[ -z "$PACKAGE" ]]; then
  PACKAGE="$(ls -1t "$DEPLOY_DIR"/*.tar.gz "$DEPLOY_DIR"/*.tar 2>/dev/null | head -n1 || true)"
  [[ -n "$PACKAGE" ]] || die "$DEPLOY_DIR 里找不到 *.tar.gz 镜像包（也可以显式给路径：bash update.sh 包.tar.gz）"
fi
[[ -f "$PACKAGE" ]] || die "找不到镜像包：$PACKAGE"

say "部署目录：$DEPLOY_DIR"
say "镜像包：$PACKAGE"
[ -f "$DEPLOY_DIR/.env" ] || die "没有 .env：先 cp .env.example .env 并填 A2A_ADMIN_PASSWORD"

# ── compose 命令（老机器可能只有 docker-compose）────────────────
if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  die "docker compose 不可用（docker compose / docker-compose 都找不到）"
fi

# ── 1. 导入镜像，并读回真实镜像引用 ────────────────────────────
say "导入镜像"
if ! LOAD_OUT="$(docker load -i "$PACKAGE" 2>&1)"; then
  printf '%s\n' "$LOAD_OUT"
  die "docker load 失败。常见原因：包不是完整镜像归档（嵌套 tar 会报 unrecognized image format）→ 重新构建或重新上传"
fi
printf '%s\n' "$LOAD_OUT"

IMAGE_REF="$(printf '%s\n' "$LOAD_OUT" | sed -n 's/^Loaded image: //p' | tail -n1)"
if [[ -z "$IMAGE_REF" ]]; then
  # 老 docker ≤ 19 的输出形如 "Loaded image ID: sha256:..."，没有名字
  die "没从 docker load 输出里读到镜像名。包可能不是本工具的产物（嵌套 tar 会报 unrecognized image format）"
fi

DERIVED_REPO="${IMAGE_REF%:*}"
DERIVED_TAG="${IMAGE_REF##*:}"
[[ -n "$TAG" ]] || TAG="$DERIVED_TAG"

say "镜像：$IMAGE_REF"
say "使用标签：$TAG"

docker image inspect "$IMAGE_REF" >/dev/null 2>&1 \
  || die "镜像 $IMAGE_REF 不在本地，导入可能失败"

if [[ "$DERIVED_REPO" != "agent2api" ]]; then
  echo "提示：包里镜像叫 $DERIVED_REPO，而 compose 期望 agent2api:<tag>；改名后再导入即可" >&2
  docker tag "$IMAGE_REF" "agent2api:$TAG"
fi

# ── 2. 停容器 + 备份 data ──────────────────────────────────────
say "停容器并备份数据"
"${COMPOSE[@]}" stop || true
mkdir -p "$DEPLOY_DIR/data" "$DEPLOY_DIR/backups"
if [ -n "$(find "$DEPLOY_DIR/data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  tar -czf "$DEPLOY_DIR/backups/data-$ts.tar.gz" -C "$DEPLOY_DIR" data
  say "备份：$DEPLOY_DIR/backups/data-$ts.tar.gz"
else
  say "data/ 还是空的（首次部署），跳过备份"
fi

# ── 3. 写 IMAGE_TAG ────────────────────────────────────────────
say "写入 IMAGE_TAG=$TAG"
if grep -q '^IMAGE_TAG=' "$DEPLOY_DIR/.env"; then
  sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=$TAG|" "$DEPLOY_DIR/.env"
else
  printf 'IMAGE_TAG=%s\n' "$TAG" >> "$DEPLOY_DIR/.env"
fi

# 端口跟随 .env（有人会把网关改成别的端口）
_p="$(sed -n 's/^PROXY_PORT=//p' "$DEPLOY_DIR/.env" | tail -n1)"
[ -n "${_p:-}" ] && PROXY_PORT="$_p"

# ── 4. 启动 ────────────────────────────────────────────────────
say "启动"
"${COMPOSE[@]}" up -d --remove-orphans

# ── 5. 健康检查 ────────────────────────────────────────────────
say "健康检查 http://127.0.0.1:$PROXY_PORT/health"
ok=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [[ "$ok" != "1" ]]; then
  echo "健康检查失败，最近日志：" >&2
  "${COMPOSE[@]}" logs --tail=60 >&2
  echo >&2
  echo "回滚：sed -i 's|^IMAGE_TAG=.*|IMAGE_TAG=<旧标签>|' $DEPLOY_DIR/.env && cd $DEPLOY_DIR && docker compose up -d" >&2
  exit 1
fi
say "网关已就绪"

# ── 6. 清理 ────────────────────────────────────────────────────
say "清理旧备份与旧镜像（保留 $KEEP_BACKUPS 份备份 / $KEEP_IMAGES 个镜像）"
ls -1t "$DEPLOY_DIR"/backups/data-*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f || true

docker images agent2api --format '{{.Tag}}\t{{.CreatedAt}}' \
  | sort -k2,3 -r \
  | tail -n +$((KEEP_IMAGES + 1)) \
  | awk -v cur="$TAG" '$1 != cur {print $1}' \
  | while read -r old; do
      echo "    删除 agent2api:$old"
      docker rmi "agent2api:$old" >/dev/null 2>&1 || true
    done

say "当前状态"
"${COMPOSE[@]}" ps

# 面板端口到底在哪，直接问容器（env 里有 PANEL_PORT 就是分端口模式）。
# update.sh 自己只检查 /health，而 /health 两种模式下都在 3065，所以这里必须显式报出来。
cid="$("${COMPOSE[@]}" ps -q 2>/dev/null | head -n1)"
if [ -n "${cid:-}" ]; then
  panel_port="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^AGENT2API_PANEL_PORT=//p' | head -n1)"
  if [ -n "${panel_port:-}" ]; then
    say "面板：独立端口 $panel_port（管理面不在网关端口上）"
  else
    say "面板：与网关同端口 $PROXY_PORT（面板 / ，网关 /v1）"
  fi
fi

echo
echo "完成。网关 http://<主机>:$PROXY_PORT/v1  ·  回滚见 .env 里的 IMAGE_TAG"
