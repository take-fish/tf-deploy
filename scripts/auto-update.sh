#!/usr/bin/env bash
# FishMatrix 集中机自动更新：轮询 ghcr 私有镜像，发现新版本自动重建应用服务
#
# 设计取舍：
#   - 只更新显式列入 APP_SERVICES 的应用服务；MySQL / Redis / ES / Nacos 等基础中间件
#     刻意不自动更新（镜像 tag 可变，无人值守升级有数据风险，升级走人工评估）
#   - "最新版本"的来源是 ghcr 上的 :latest（docker-compose.yml 中 TF_GATEWAY_TAG 未固定时）
#   - 与设计文档 5.3「agent 轮询制品库自动更新」同构：先在本机以脚本实现，将来由 agent 接管
#
# 调用方式：systemd 定时器（scripts/install-auto-update.sh 一键安装）/ cron / 手动执行
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

# 需要自动更新的应用服务；新的业务服务编排进 compose 后，把服务名追加到这里即可
APP_SERVICES=(gateway)

log() { echo "[fm-auto-update] $(date '+%F %T') $*"; }

# 防止 timer / cron 与手动执行重叠
LOCK_FILE="${TMPDIR:-/tmp}/fm-auto-update.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { log "上一轮更新仍在运行，跳过本轮"; exit 0; }
fi

log "轮询应用镜像：${APP_SERVICES[*]}"
if ! docker compose pull -q "${APP_SERVICES[@]}"; then
  log "ERROR: 镜像拉取失败——检查 ghcr 凭据（docker login ghcr.io）与网络"
  exit 1
fi

for svc in "${APP_SERVICES[@]}"; do
  cid=$(docker compose ps -q "$svc" || true)
  if [ -z "$cid" ]; then
    log "服务 $svc 未在运行，跳过"
    continue
  fi

  before=$(docker inspect --format '{{.Image}}' "$cid")
  # --no-deps：只动目标服务，不牵连依赖的中间件
  docker compose up -d --no-deps "$svc" >/dev/null

  cid=$(docker compose ps -q "$svc")
  after=$(docker inspect --format '{{.Image}}' "$cid")
  if [ "$before" != "$after" ]; then
    log "服务 $svc 已更新：${before:0:19} -> ${after:0:19}"
  else
    log "服务 $svc 已是最新"
  fi
done

log "本轮完成"
