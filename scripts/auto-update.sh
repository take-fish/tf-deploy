#!/usr/bin/env bash
# FishMatrix 集中机自动更新：轮询 ghcr 私有镜像，发现新版本自动重建应用服务
#
# 设计取舍：
#   - 只更新显式列入 APP_SERVICES / AGENT_SERVICES 的服务；MySQL / Redis / ES / Nacos 等
#     基础中间件刻意不自动更新（镜像 tag 可变，无人值守升级有数据风险，升级走人工评估）
#   - 业务应用加载 base 与 services 两个 compose 文件；agent 在 GPU 节点独立的
#     fishmatrix-llm 项目（docker-compose.llm.yml），与 vLLM 同文件但只重建 agent
#   - "最新版本"的来源是 ghcr 上的 :latest（compose 中的 TF_*_TAG 未固定时）
#   - 与设计文档 5.3「agent 轮询制品库自动更新」同构：先在本机以脚本实现，将来由 agent 接管
#
# 调用方式：systemd 定时器（scripts/install-auto-update.sh 一键安装）/ cron / 手动执行
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_DIR"

# 应用服务与 agent 属于不同 compose 项目：agent 在 GPU 节点的 fishmatrix-llm
# 项目里（与 vLLM 同文件），不能和业务服务共用一套 -f 参数。
APP_COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.services.yml)
APP_SERVICES=(gateway console web user chat reader game music)

AGENT_COMPOSE_FILES=(-f docker-compose.llm.yml)
AGENT_SERVICES=(agent)

log() { echo "[fm-auto-update] $(date '+%F %T') $*"; }

# 防止 timer / cron 与手动执行重叠
LOCK_FILE="${TMPDIR:-/tmp}/fm-auto-update.lock"
exec 9>"$LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || { log "上一轮更新仍在运行，跳过本轮"; exit 0; }
fi

# update_group <名称> <compose 参数...> -- <服务...>
update_group() {
  local label="$1"; shift
  local -a compose_args=()
  while [ "$1" != "--" ]; do
    compose_args+=("$1"); shift
  done
  shift
  local -a services=("$@")

  log "轮询${label}镜像：${services[*]}"
  if ! docker compose "${compose_args[@]}" pull -q "${services[@]}"; then
    log "ERROR: ${label}镜像拉取失败——检查 ghcr 凭据（docker login ghcr.io）与网络"
    return 1
  fi

  for svc in "${services[@]}"; do
    cid=$(docker compose "${compose_args[@]}" ps -q "$svc" || true)
    if [ -z "$cid" ]; then
      log "服务 $svc 未在运行，跳过"
      continue
    fi

    before=$(docker inspect --format '{{.Image}}' "$cid")
    # --no-deps：只动目标服务，不牵连依赖的中间件
    docker compose "${compose_args[@]}" up -d --no-deps "$svc" >/dev/null

    cid=$(docker compose "${compose_args[@]}" ps -q "$svc")
    after=$(docker inspect --format '{{.Image}}' "$cid")
    if [ "$before" != "$after" ]; then
      log "服务 $svc 已更新：${before:0:19} -> ${after:0:19}"
    else
      log "服务 $svc 已是最新"
    fi
  done
}

# 两组互不阻塞：业务应用拉取失败时仍尝试更新 agent，反之亦然
update_group "应用" "${APP_COMPOSE_FILES[@]}" -- "${APP_SERVICES[@]}" \
  || log "应用服务本轮未全部更新"
update_group "agent" "${AGENT_COMPOSE_FILES[@]}" -- "${AGENT_SERVICES[@]}" \
  || log "agent 本轮未更新"

log "本轮完成"
