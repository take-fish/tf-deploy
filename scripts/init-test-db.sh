#!/usr/bin/env bash
# 独立测试 MySQL（fm-test-mysql）库与账号初始化/修复（幂等）
#
# 作用：
#   - 创建 fm_test_user / fm_test_chat / fm_test_reader /
#     fm_test_game / fm_test_music
#   - 为每个服务创建运行时账号（只授 DML）和迁移账号（只授本库 DDL）
#   - 不再创建或使用 fm_test_app 这个跨库账号；旧账号保留用于回滚
#
# 用法：bash scripts/init-test-db.sh
# 前置：
#   - scripts/ensure-test-secrets.sh 已生成测试密码
#   - fm-test-mysql 已启动且 healthy：
#       docker compose -f docker-compose.middleware.yml up -d mysql-test
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "未找到 $ENV_FILE，请先复制 .env.example 为 .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source <(tr -d '\r' < "$ENV_FILE")
set +a

TEST_MYSQL_ROOT_PASSWORD="${TEST_MYSQL_ROOT_PASSWORD:-}"

: "${TEST_MYSQL_ROOT_PASSWORD:?TEST_MYSQL_ROOT_PASSWORD 未配置，请执行 scripts/ensure-test-secrets.sh}"

TEST_FM_USER_DB_USER="${TEST_FM_USER_DB_USER:-fm_test_user_app}"
TEST_FM_USER_DB_PASSWORD="${TEST_FM_USER_DB_PASSWORD:-}"
TEST_FM_USER_DB_MIGRATE_USER="${TEST_FM_USER_DB_MIGRATE_USER:-fm_test_user_migrate}"
TEST_FM_USER_DB_MIGRATE_PASSWORD="${TEST_FM_USER_DB_MIGRATE_PASSWORD:-}"

TEST_FM_CHAT_DB_USER="${TEST_FM_CHAT_DB_USER:-fm_test_chat_app}"
TEST_FM_CHAT_DB_PASSWORD="${TEST_FM_CHAT_DB_PASSWORD:-}"
TEST_FM_CHAT_DB_MIGRATE_USER="${TEST_FM_CHAT_DB_MIGRATE_USER:-fm_test_chat_migrate}"
TEST_FM_CHAT_DB_MIGRATE_PASSWORD="${TEST_FM_CHAT_DB_MIGRATE_PASSWORD:-}"

TEST_FM_READER_DB_USER="${TEST_FM_READER_DB_USER:-fm_test_reader_app}"
TEST_FM_READER_DB_PASSWORD="${TEST_FM_READER_DB_PASSWORD:-}"
TEST_FM_READER_DB_MIGRATE_USER="${TEST_FM_READER_DB_MIGRATE_USER:-fm_test_reader_migrate}"
TEST_FM_READER_DB_MIGRATE_PASSWORD="${TEST_FM_READER_DB_MIGRATE_PASSWORD:-}"

TEST_FM_GAME_DB_USER="${TEST_FM_GAME_DB_USER:-fm_test_game_app}"
TEST_FM_GAME_DB_PASSWORD="${TEST_FM_GAME_DB_PASSWORD:-}"
TEST_FM_GAME_DB_MIGRATE_USER="${TEST_FM_GAME_DB_MIGRATE_USER:-fm_test_game_migrate}"
TEST_FM_GAME_DB_MIGRATE_PASSWORD="${TEST_FM_GAME_DB_MIGRATE_PASSWORD:-}"

TEST_FM_MUSIC_DB_USER="${TEST_FM_MUSIC_DB_USER:-fm_test_music_app}"
TEST_FM_MUSIC_DB_PASSWORD="${TEST_FM_MUSIC_DB_PASSWORD:-}"
TEST_FM_MUSIC_DB_MIGRATE_USER="${TEST_FM_MUSIC_DB_MIGRATE_USER:-fm_test_music_migrate}"
TEST_FM_MUSIC_DB_MIGRATE_PASSWORD="${TEST_FM_MUSIC_DB_MIGRATE_PASSWORD:-}"

TEST_FM_AGENT_DB_USER="${TEST_FM_AGENT_DB_USER:-fm_test_agent_app}"
TEST_FM_AGENT_DB_PASSWORD="${TEST_FM_AGENT_DB_PASSWORD:-}"
TEST_FM_AGENT_DB_MIGRATE_USER="${TEST_FM_AGENT_DB_MIGRATE_USER:-fm_test_agent_migrate}"
TEST_FM_AGENT_DB_MIGRATE_PASSWORD="${TEST_FM_AGENT_DB_MIGRATE_PASSWORD:-}"

log() { echo "[init-test-db] $*"; }

validate_identifier() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "$label 只允许字母、数字与下划线：$value" >&2
    exit 1
  fi
}

validate_password() {
  local label="$1" value="$2"
  if [ -z "$value" ]; then
    echo "$label 未配置，请执行 scripts/ensure-test-secrets.sh" >&2
    exit 1
  fi
  if ! [[ "$value" =~ ^[A-Za-z0-9_.!@#%^*()+-]+$ ]]; then
    echo "$label 含有未支持的字符（引号/反斜杠等），请更换密码" >&2
    exit 1
  fi
}

for pair in \
  "TEST_FM_USER_DB_USER:$TEST_FM_USER_DB_USER" \
  "TEST_FM_USER_DB_MIGRATE_USER:$TEST_FM_USER_DB_MIGRATE_USER" \
  "TEST_FM_CHAT_DB_USER:$TEST_FM_CHAT_DB_USER" \
  "TEST_FM_CHAT_DB_MIGRATE_USER:$TEST_FM_CHAT_DB_MIGRATE_USER" \
  "TEST_FM_READER_DB_USER:$TEST_FM_READER_DB_USER" \
  "TEST_FM_READER_DB_MIGRATE_USER:$TEST_FM_READER_DB_MIGRATE_USER" \
  "TEST_FM_GAME_DB_USER:$TEST_FM_GAME_DB_USER" \
  "TEST_FM_GAME_DB_MIGRATE_USER:$TEST_FM_GAME_DB_MIGRATE_USER" \
  "TEST_FM_MUSIC_DB_USER:$TEST_FM_MUSIC_DB_USER" \
  "TEST_FM_MUSIC_DB_MIGRATE_USER:$TEST_FM_MUSIC_DB_MIGRATE_USER" \
  "TEST_FM_AGENT_DB_USER:$TEST_FM_AGENT_DB_USER" \
  "TEST_FM_AGENT_DB_MIGRATE_USER:$TEST_FM_AGENT_DB_MIGRATE_USER"; do
  validate_identifier "${pair%%:*}" "${pair#*:}"
done

for pair in \
  "TEST_FM_USER_DB_PASSWORD:$TEST_FM_USER_DB_PASSWORD" \
  "TEST_FM_USER_DB_MIGRATE_PASSWORD:$TEST_FM_USER_DB_MIGRATE_PASSWORD" \
  "TEST_FM_CHAT_DB_PASSWORD:$TEST_FM_CHAT_DB_PASSWORD" \
  "TEST_FM_CHAT_DB_MIGRATE_PASSWORD:$TEST_FM_CHAT_DB_MIGRATE_PASSWORD" \
  "TEST_FM_READER_DB_PASSWORD:$TEST_FM_READER_DB_PASSWORD" \
  "TEST_FM_READER_DB_MIGRATE_PASSWORD:$TEST_FM_READER_DB_MIGRATE_PASSWORD" \
  "TEST_FM_GAME_DB_PASSWORD:$TEST_FM_GAME_DB_PASSWORD" \
  "TEST_FM_GAME_DB_MIGRATE_PASSWORD:$TEST_FM_GAME_DB_MIGRATE_PASSWORD" \
  "TEST_FM_MUSIC_DB_PASSWORD:$TEST_FM_MUSIC_DB_PASSWORD" \
  "TEST_FM_MUSIC_DB_MIGRATE_PASSWORD:$TEST_FM_MUSIC_DB_MIGRATE_PASSWORD" \
  "TEST_FM_AGENT_DB_PASSWORD:$TEST_FM_AGENT_DB_PASSWORD" \
  "TEST_FM_AGENT_DB_MIGRATE_PASSWORD:$TEST_FM_AGENT_DB_MIGRATE_PASSWORD"; do
  validate_password "${pair%%:*}" "${pair#*:}"
done

if ! docker ps --format '{{.Names}}' | grep -qx 'fm-test-mysql'; then
  echo "fm-test-mysql 未运行，请先执行：docker compose -f docker-compose.middleware.yml up -d mysql-test" >&2
  exit 1
fi

log "等待 fm-test-mysql 健康检查..."
status=""
for _ in $(seq 1 60); do
  status=$(docker inspect fm-test-mysql --format '{{.State.Health.Status}}' 2>/dev/null || true)
  if [ "$status" = "healthy" ]; then
    break
  fi
  sleep 2
done
if [ "${status:-}" != "healthy" ]; then
  echo "fm-test-mysql 未在 120 秒内变为 healthy（当前：${status:-unknown}）" >&2
  exit 1
fi

create_database_and_accounts() {
  local svc="$1" db="$2" app_user="$3" app_password="$4" migrate_user="$5" migrate_password="$6"
  log "初始化 ${svc}：${db} / ${app_user} / ${migrate_user}"

  docker exec -i -e MYSQL_PWD="$TEST_MYSQL_ROOT_PASSWORD" fm-test-mysql mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${app_user}'@'%' IDENTIFIED BY '${app_password}';
ALTER USER '${app_user}'@'%' IDENTIFIED BY '${app_password}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${db}\`.* TO '${app_user}'@'%';

CREATE USER IF NOT EXISTS '${migrate_user}'@'%' IDENTIFIED BY '${migrate_password}';
ALTER USER '${migrate_user}'@'%' IDENTIFIED BY '${migrate_password}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${migrate_user}'@'%';
FLUSH PRIVILEGES;
SQL

  docker exec -e MYSQL_PWD="$app_password" fm-test-mysql \
    mysql -h 127.0.0.1 -u"${app_user}" -N -e "SELECT 'AUTH_OK';" >/dev/null
  docker exec -e MYSQL_PWD="$migrate_password" fm-test-mysql \
    mysql -h 127.0.0.1 -u"${migrate_user}" -N -e "SELECT 'AUTH_OK';" >/dev/null

  # 运行时账号必须没有 DDL：CREATE TABLE 应被拒绝。若意外成功则立即清理并失败。
  if docker exec -e MYSQL_PWD="$app_password" fm-test-mysql \
      mysql -h 127.0.0.1 -u"${app_user}" -e "CREATE TABLE \`${db}\`.__fm_privcheck (id INT);" >/dev/null 2>&1; then
    docker exec -e MYSQL_PWD="$app_password" fm-test-mysql \
      mysql -h 127.0.0.1 -u"${app_user}" -e "DROP TABLE \`${db}\`.__fm_privcheck;" >/dev/null 2>&1 || true
    echo "ERROR: ${app_user} 仍拥有 ${db} 的 DDL 权限" >&2
    exit 1
  fi
  log "${svc} 账号验证通过：运行时仅 DML，迁移账号可 DDL"
}

create_database_and_accounts user fm_test_user \
  "$TEST_FM_USER_DB_USER" "$TEST_FM_USER_DB_PASSWORD" \
  "$TEST_FM_USER_DB_MIGRATE_USER" "$TEST_FM_USER_DB_MIGRATE_PASSWORD"
create_database_and_accounts chat fm_test_chat \
  "$TEST_FM_CHAT_DB_USER" "$TEST_FM_CHAT_DB_PASSWORD" \
  "$TEST_FM_CHAT_DB_MIGRATE_USER" "$TEST_FM_CHAT_DB_MIGRATE_PASSWORD"
create_database_and_accounts reader fm_test_reader \
  "$TEST_FM_READER_DB_USER" "$TEST_FM_READER_DB_PASSWORD" \
  "$TEST_FM_READER_DB_MIGRATE_USER" "$TEST_FM_READER_DB_MIGRATE_PASSWORD"
create_database_and_accounts game fm_test_game \
  "$TEST_FM_GAME_DB_USER" "$TEST_FM_GAME_DB_PASSWORD" \
  "$TEST_FM_GAME_DB_MIGRATE_USER" "$TEST_FM_GAME_DB_MIGRATE_PASSWORD"
create_database_and_accounts music fm_test_music \
  "$TEST_FM_MUSIC_DB_USER" "$TEST_FM_MUSIC_DB_PASSWORD" \
  "$TEST_FM_MUSIC_DB_MIGRATE_USER" "$TEST_FM_MUSIC_DB_MIGRATE_PASSWORD"
create_database_and_accounts agent fm_test_agent \
  "$TEST_FM_AGENT_DB_USER" "$TEST_FM_AGENT_DB_PASSWORD" \
  "$TEST_FM_AGENT_DB_MIGRATE_USER" "$TEST_FM_AGENT_DB_MIGRATE_PASSWORD"

log "完成：测试库位于独立实例 fm-test-mysql；每服务运行时账号只授 DML，迁移账号只授本库 DDL。"
log "旧账号 fm_test_app 仍保留在旧共享 MySQL 中，仅用于回滚。"
