#!/usr/bin/env bash
# FishMatrix 测试环境自动更新：轮询 ghcr 的 :test 镜像并重建测试容器
#
# 设计：
#   - 只操作 docker-compose.test.yml 中的测试应用，不触碰生产容器与共享中间件
#   - 测试中间件由 docker-compose.middleware.yml 单独维护
#   - push test 分支 → CI 构建并推送 :test → 本脚本每 2 分钟拉取并重建有变化的服务
#   - 与 auto-update.sh 相同的 flock 防重入
#
# 调用方式：Windows 计划任务 FishMatrix-auto-update-test / cron / 手动执行
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

COMPOSE_FILES=(-f docker-compose.test.yml)

# 测试栈内的应用服务
APP_SERVICES=(gateway web user chat reader game music)
# 需要先执行 Flyway 迁移的数据库服务与对应一次性任务
MIGRATE_SERVICES=(user chat reader game)
MIGRATE_JOBS=(db-migrate-user db-migrate-chat db-migrate-reader db-migrate-game)
MIGRATE_MARKER="$REPO_DIR/.fm-test-migrated-images"

log() { echo "[fm-auto-update-test] $(date '+%F %T') $*"; }

LOCK_FILE="${TMPDIR:-/tmp}/fm-auto-update-test.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { log "上一轮更新仍在运行，跳过本轮"; exit 0; }
fi

if [ -z "$(docker compose "${COMPOSE_FILES[@]}" ps -q "${APP_SERVICES[@]}" 2>/dev/null | tr -d '[:space:]')" ]; then
  log "测试应用栈未运行，跳过"
  exit 0
fi

log "轮询测试镜像：${APP_SERVICES[*]}"
# ghcr 层下载在部分网络下极慢（实测约 20 KB/s），必须设置超时避免永久占用锁
PULL_TIMEOUT="${TEST_PULL_TIMEOUT:-180}"
if ! timeout "$PULL_TIMEOUT" docker compose "${COMPOSE_FILES[@]}" pull -q "${APP_SERVICES[@]}"; then
  log "ERROR: 测试镜像拉取失败或超时（${PULL_TIMEOUT}s）——检查 ghcr 凭据/网络；"
  log "       可改用本地构建部署：bash scripts/build-test-local.sh user chat reader game music"
  exit 1
fi

# 镜像变化时先跑迁移任务，再重建业务容器，避免新代码启动在旧 schema 上
image_ids=$(for svc in "${MIGRATE_SERVICES[@]}"; do
  ref=$(docker compose "${COMPOSE_FILES[@]}" config --images | grep -m1 "/tf-${svc}:")
  docker image inspect "$ref" --format '{{.Id}}'
done | sha256sum | cut -d' ' -f1)
previous_ids=$(cat "$MIGRATE_MARKER" 2>/dev/null || true)
if [ "$image_ids" != "$previous_ids" ]; then
  log "迁移服务镜像有变化，执行 Flyway：${MIGRATE_JOBS[*]}"
  docker compose "${COMPOSE_FILES[@]}" up --force-recreate "${MIGRATE_JOBS[@]}"
  printf '%s\n' "$image_ids" > "$MIGRATE_MARKER"
else
  log "迁移服务镜像未变化，跳过 Flyway"
fi

for svc in "${APP_SERVICES[@]}"; do
  cid=$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc" || true)
  if [ -z "$cid" ]; then
    log "服务 $svc 未在运行，跳过"
    continue
  fi

  before=$(docker inspect --format '{{.Image}}' "$cid")
  docker compose "${COMPOSE_FILES[@]}" up -d --no-deps "$svc" >/dev/null

  cid=$(docker compose "${COMPOSE_FILES[@]}" ps -q "$svc")
  after=$(docker inspect --format '{{.Image}}' "$cid")
  if [ "$before" != "$after" ]; then
    log "服务 $svc 已更新：${before:0:19} -> ${after:0:19}"
  else
    log "服务 $svc 已是最新"
  fi
done

log "本轮完成"
