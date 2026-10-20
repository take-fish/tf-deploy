#!/usr/bin/env bash
# 为测试栈准备专用中间件网络（幂等）
#
# 背景：生产 MySQL 未在集中机发布 3306 端口（仅通过 fishmatrix_default 网络暴露），
# 且宿主机 3306 已被本机 MySQL 占用，因此测试栈不能经 host.docker.internal 访问共享 MySQL。
# 方案：创建独立网络 fishmatrix-test-mw，把共享中间件容器接进来（不重启、不改生产编排），
# 测试栈只接入该网络，与生产业务容器仍保持网络隔离。
#
# 用法：bash scripts/connect-test-network.sh
set -euo pipefail

NETWORK="${TEST_MW_NETWORK:-fishmatrix-test-mw}"
MIDDLEWARE=(fm-mysql fm-redis fm-nacos)

log() { echo "[connect-test-network] $*"; }

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  docker network create "$NETWORK" >/dev/null
  log "已创建网络：$NETWORK"
else
  log "网络已存在：$NETWORK"
fi

for c in "${MIDDLEWARE[@]}"; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    log "容器 $c 未运行，跳过"
    continue
  fi

  if docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | grep -qw "$NETWORK"; then
    log "$c 已接入 $NETWORK"
  else
    docker network connect "$NETWORK" "$c"
    log "已接入：$c -> $NETWORK"
  fi
done

log "完成"
