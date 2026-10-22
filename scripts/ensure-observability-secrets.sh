#!/usr/bin/env bash
# 为日志检索与 Grafana 补齐口令（只生成缺失或为空的项）
#
# - TF_CONSOLE_LOG_TOKEN：流水线中台“日志检索”访问口令
# - GRAFANA_ADMIN_PASSWORD：Grafana 管理员密码（仅本机回环端口可登录）
# - 全程不打印口令；已有值保持不变
#
# 用法：
#   bash scripts/ensure-observability-secrets.sh
#   ENV_FILE=/path/to/.env bash scripts/ensure-observability-secrets.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

log() { echo "[ensure-observability-secrets] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$REPO_DIR/.env.example" ]; then
    cp "$REPO_DIR/.env.example" "$ENV_FILE"
    log "未找到 .env，已依据 .env.example 创建"
  else
    log "ERROR: 未找到 $ENV_FILE 与 .env.example"
    exit 1
  fi
fi

# 只使用字母数字，避免 .env / compose / 前端输入中的引号与转义问题
generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
  fi
}

value_of() {
  grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true
}

set_value() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    !done && index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

ensure_key() {
  local key="$1"
  local fallback="$2"
  local current
  current=$(value_of "$key")
  if [ -n "$current" ]; then
    log "$key 已存在，保留"
    return
  fi
  if grep -q "^$key=" "$ENV_FILE"; then
    set_value "$key" "$fallback"
    log "$key 为空，已生成"
  else
    printf '\n%s=%s\n' "$key" "$fallback" >> "$ENV_FILE"
    log "$key 缺失，已生成"
  fi
}

ensure_key TF_CONSOLE_LOG_TOKEN "$(generate_secret)"
ensure_key GRAFANA_ADMIN_PASSWORD "$(generate_secret)"

if command -v chmod >/dev/null 2>&1; then
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

log "完成。重建控制台以加载检索口令："
log "  docker compose -f docker-compose.yml up -d --no-deps --force-recreate console"
log "口令仅保存在 $ENV_FILE，请勿提交或外传。"
