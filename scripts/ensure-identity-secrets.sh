#!/usr/bin/env bash
# 为网关与业务服务补齐统一身份签名密钥
#
# - FM_IDENTITY_SECRET：生产网关 + 业务服务共用的 HMAC 密钥
# - TEST_FM_IDENTITY_SECRET：测试栈专用密钥，必须与生产不同
# - 只补齐缺失或为空的项，已有值保持不变；全程不打印密钥
#
# 用法：
#   bash scripts/ensure-identity-secrets.sh
#   ENV_FILE=/path/to/.env bash scripts/ensure-identity-secrets.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

log() { echo "[ensure-identity-secrets] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$REPO_DIR/.env.example" ]; then
    cp "$REPO_DIR/.env.example" "$ENV_FILE"
    log "未找到 .env，已依据 .env.example 创建"
  else
    log "ERROR: 未找到 $ENV_FILE 与 .env.example"
    exit 1
  fi
fi

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64
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
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

ensure_key() {
  local key="$1"
  local current
  current=$(value_of "$key")
  if [ -n "$current" ]; then
    log "$key 已存在，保留"
    return
  fi
  if grep -q "^$key=" "$ENV_FILE"; then
    set_value "$key" "$(generate_secret)"
    log "$key 为空，已生成"
  else
    printf '\n%s=%s\n' "$key" "$(generate_secret)" >> "$ENV_FILE"
    log "$key 缺失，已生成"
  fi
}

ensure_key FM_IDENTITY_SECRET
ensure_key TEST_FM_IDENTITY_SECRET

if [ "$(value_of FM_IDENTITY_SECRET)" = "$(value_of TEST_FM_IDENTITY_SECRET)" ]; then
  log "ERROR: 生产与测试身份密钥相同，请手工重置其中一个"
  exit 1
fi

if command -v chmod >/dev/null 2>&1; then
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

log "完成。重建网关与业务服务后生效："
log "  docker compose -f docker-compose.test.yml up -d --force-recreate gateway user chat reader game music"
log "生产发布前请确认 gateway 与各业务服务读到同一个 FM_IDENTITY_SECRET。"
log "密钥仅保存在 $ENV_FILE，请勿提交或外传。"
