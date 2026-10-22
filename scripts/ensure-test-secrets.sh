#!/usr/bin/env bash
# 为独立测试 MySQL 补齐专用密码
#
# - TEST_MYSQL_ROOT_PASSWORD：fm-test-mysql 的独立 root 密码
# - TEST_FM_<SVC>_DB_PASSWORD：测试每服务运行时 DML 账号密码
# - TEST_FM_<SVC>_DB_MIGRATE_PASSWORD：测试每服务迁移 DDL 账号密码
# - TEST_MYSQL_APP_PASSWORD：旧测试共享账号，仅保留用于回滚
# - 测试 Nacos 复用生产 Nacos 管理员（共享同一套中间件），不再生成独立管理员密码
# - 只补齐缺失或为空的项，已有值保持不变
# - 全程不打印密码/密钥
#
# 用法：
#   bash scripts/ensure-test-secrets.sh
#   ENV_FILE=/path/to/.env bash scripts/ensure-test-secrets.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

log() { echo "[ensure-test-secrets] $*"; }

if [ ! -f "$ENV_FILE" ]; then
  if [ -f "$REPO_DIR/.env.example" ]; then
    cp "$REPO_DIR/.env.example" "$ENV_FILE"
    log "未找到 .env，已依据 .env.example 创建"
  else
    log "ERROR: 未找到 $ENV_FILE 与 .env.example"
    exit 1
  fi
fi

generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
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

# 旧共享账号保留用于回滚
ensure_key TEST_MYSQL_APP_PASSWORD "$(generate_password)"

# 独立测试 MySQL 实例与每服务账号
ensure_key TEST_MYSQL_ROOT_PASSWORD "$(generate_password)"
for key in \
  TEST_FM_USER_DB_PASSWORD \
  TEST_FM_CHAT_DB_PASSWORD \
  TEST_FM_READER_DB_PASSWORD \
  TEST_FM_GAME_DB_PASSWORD \
  TEST_FM_MUSIC_DB_PASSWORD \
  TEST_FM_USER_DB_MIGRATE_PASSWORD \
  TEST_FM_CHAT_DB_MIGRATE_PASSWORD \
  TEST_FM_READER_DB_MIGRATE_PASSWORD \
  TEST_FM_GAME_DB_MIGRATE_PASSWORD \
  TEST_FM_MUSIC_DB_MIGRATE_PASSWORD; do
  ensure_key "$key" "$(generate_password)"
done

# 测试应用必须指向独立测试实例，不能继续使用旧共享 mysql。
current_host=$(value_of TEST_MYSQL_HOST)
if [ -z "$current_host" ] || [ "$current_host" = "mysql" ]; then
  set_value TEST_MYSQL_HOST mysql-test
  log "TEST_MYSQL_HOST 已切换为 mysql-test"
else
  log "TEST_MYSQL_HOST 已存在（$current_host），保留"
fi
if [ -z "$(value_of TEST_MYSQL_PORT)" ]; then
  set_value TEST_MYSQL_PORT 3306
  log "TEST_MYSQL_PORT 已设置为 3306"
fi

if command -v chmod >/dev/null 2>&1; then
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

log "完成。首次启动测试栈："
log "  cd tf-deploy"
log "  docker compose -f docker-compose.middleware.yml up -d mysql-test redis nacos"
log "  bash scripts/init-test-db.sh"
log "  bash scripts/migrate-db.sh test"
log "  docker compose -f docker-compose.test.yml up -d"
log "测试 Nacos 复用生产 Nacos 管理员（NACOS_ADMIN_PASSWORD），namespace=fm-test。"
log "密码仅保存在 $ENV_FILE，请勿提交或外传。"
