#!/usr/bin/env bash
# FishMatrix 测试环境自动更新：轮询 ghcr 的 :test 镜像并重建测试容器
#
# 设计：
#   - 只操作 docker-compose.test.yml 中的测试栈，不触碰生产容器与中间件
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

log() { echo "[fm-auto-update-test] $(date '+%F %T') $*"; }

LOCK_FILE="${TMPDIR:-/tmp}/fm-auto-update-test.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { log "上一轮更新仍在运行，跳过本轮"; exit 0; }
fi

if [ -z "$(docker compose "${COMPOSE_FILES[@]}" ps -q 2>/dev/null | tr -d '[:space:]')" ]; then
  log "测试栈未运行，跳过"
  exit 0
fi

log "轮询测试镜像：${APP_SERVICES[*]}"
if ! docker compose "${COMPOSE_FILES[@]}" pull -q "${APP_SERVICES[@]}"; then
  log "ERROR: 测试镜像拉取失败——检查 ghcr 凭据与 :test 镜像是否已构建"
  exit 1
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
