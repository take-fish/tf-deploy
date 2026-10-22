#!/usr/bin/env bash
# FishMatrix 生产 MySQL（fm-mysql）每服务账号初始化/修复（幂等）
#
# 作用：
#   - 创建/同步 fm_user / fm_chat / fm_reader / fm_game / fm_music
#   - 为每个服务创建运行时账号（只授 DML）和迁移账号（只授本库 DDL）
#   - 旧 fm_app 账号保留不撤销，作为切换回滚窗口；确认无引用后按第 20.4.4 节退场
#
# 注意：本脚本只改账号和库，不执行 Flyway，不改业务数据。
# 生产切换前先备份，并按 scripts/migrate-db.sh prod 执行迁移任务。
#
# 用法：bash scripts/init-db.sh
# 前置：fm-mysql 已启动且 healthy，.env 中已生成每服务账号密码。
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "未找到 $ENV_FILE，请先复制 .env.example 为 .env 并填写凭据" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source <(tr -d '\r' < "$ENV_FILE")
set +a

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD 未配置}"

FM_USER_DB_USER="${FM_USER_DB_USER:-fm_user_app}"
FM_USER_DB_PASSWORD="${FM_USER_DB_PASSWORD:-}"
FM_USER_DB_MIGRATE_USER="${FM_USER_DB_MIGRATE_USER:-fm_user_migrate}"
FM_USER_DB_MIGRATE_PASSWORD="${FM_USER_DB_MIGRATE_PASSWORD:-}"

FM_CHAT_DB_USER="${FM_CHAT_DB_USER:-fm_chat_app}"
FM_CHAT_DB_PASSWORD="${FM_CHAT_DB_PASSWORD:-}"
FM_CHAT_DB_MIGRATE_USER="${FM_CHAT_DB_MIGRATE_USER:-fm_chat_migrate}"
FM_CHAT_DB_MIGRATE_PASSWORD="${FM_CHAT_DB_MIGRATE_PASSWORD:-}"

FM_READER_DB_USER="${FM_READER_DB_USER:-fm_reader_app}"
FM_READER_DB_PASSWORD="${FM_READER_DB_PASSWORD:-}"
FM_READER_DB_MIGRATE_USER="${FM_READER_DB_MIGRATE_USER:-fm_reader_migrate}"
FM_READER_DB_MIGRATE_PASSWORD="${FM_READER_DB_MIGRATE_PASSWORD:-}"

FM_GAME_DB_USER="${FM_GAME_DB_USER:-fm_game_app}"
FM_GAME_DB_PASSWORD="${FM_GAME_DB_PASSWORD:-}"
FM_GAME_DB_MIGRATE_USER="${FM_GAME_DB_MIGRATE_USER:-fm_game_migrate}"
FM_GAME_DB_MIGRATE_PASSWORD="${FM_GAME_DB_MIGRATE_PASSWORD:-}"

FM_MUSIC_DB_USER="${FM_MUSIC_DB_USER:-fm_music_app}"
FM_MUSIC_DB_PASSWORD="${FM_MUSIC_DB_PASSWORD:-}"
FM_MUSIC_DB_MIGRATE_USER="${FM_MUSIC_DB_MIGRATE_USER:-fm_music_migrate}"
FM_MUSIC_DB_MIGRATE_PASSWORD="${FM_MUSIC_DB_MIGRATE_PASSWORD:-}"

log() { echo "[init-db] $*"; }

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
    echo "$label 未配置，请先写入 .env" >&2
    exit 1
  fi
  if ! [[ "$value" =~ ^[A-Za-z0-9_.!@#%^*()+-]+$ ]]; then
    echo "$label 含有未支持的字符（引号/反斜杠等），请更换密码" >&2
    exit 1
  fi
}

for pair in \
  "FM_USER_DB_USER:$FM_USER_DB_USER" \
  "FM_USER_DB_MIGRATE_USER:$FM_USER_DB_MIGRATE_USER" \
  "FM_CHAT_DB_USER:$FM_CHAT_DB_USER" \
  "FM_CHAT_DB_MIGRATE_USER:$FM_CHAT_DB_MIGRATE_USER" \
  "FM_READER_DB_USER:$FM_READER_DB_USER" \
  "FM_READER_DB_MIGRATE_USER:$FM_READER_DB_MIGRATE_USER" \
  "FM_GAME_DB_USER:$FM_GAME_DB_USER" \
  "FM_GAME_DB_MIGRATE_USER:$FM_GAME_DB_MIGRATE_USER" \
  "FM_MUSIC_DB_USER:$FM_MUSIC_DB_USER" \
  "FM_MUSIC_DB_MIGRATE_USER:$FM_MUSIC_DB_MIGRATE_USER"; do
  validate_identifier "${pair%%:*}" "${pair#*:}"
done

for pair in \
  "FM_USER_DB_PASSWORD:$FM_USER_DB_PASSWORD" \
  "FM_USER_DB_MIGRATE_PASSWORD:$FM_USER_DB_MIGRATE_PASSWORD" \
  "FM_CHAT_DB_PASSWORD:$FM_CHAT_DB_PASSWORD" \
  "FM_CHAT_DB_MIGRATE_PASSWORD:$FM_CHAT_DB_MIGRATE_PASSWORD" \
  "FM_READER_DB_PASSWORD:$FM_READER_DB_PASSWORD" \
  "FM_READER_DB_MIGRATE_PASSWORD:$FM_READER_DB_MIGRATE_PASSWORD" \
  "FM_GAME_DB_PASSWORD:$FM_GAME_DB_PASSWORD" \
  "FM_GAME_DB_MIGRATE_PASSWORD:$FM_GAME_DB_MIGRATE_PASSWORD" \
  "FM_MUSIC_DB_PASSWORD:$FM_MUSIC_DB_PASSWORD" \
  "FM_MUSIC_DB_MIGRATE_PASSWORD:$FM_MUSIC_DB_MIGRATE_PASSWORD"; do
  validate_password "${pair%%:*}" "${pair#*:}"
done

if ! docker ps --format '{{.Names}}' | grep -qx 'fm-mysql'; then
  echo "fm-mysql 未运行，请先执行：docker compose -f docker-compose.middleware.yml up -d mysql" >&2
  exit 1
fi

log "等待 fm-mysql 健康检查..."
status=""
for _ in $(seq 1 60); do
  status=$(docker inspect fm-mysql --format '{{.State.Health.Status}}' 2>/dev/null || true)
  if [ "$status" = "healthy" ]; then
    break
  fi
  sleep 2
done
if [ "${status:-}" != "healthy" ]; then
  echo "fm-mysql 未在 120 秒内变为 healthy（当前：${status:-unknown}）" >&2
  exit 1
fi

create_database_and_accounts() {
  local svc="$1" db="$2" app_user="$3" app_password="$4" migrate_user="$5" migrate_password="$6"
  log "初始化 ${svc}：${db} / ${app_user} / ${migrate_user}"

  docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${app_user}'@'%' IDENTIFIED BY '${app_password}';
ALTER USER '${app_user}'@'%' IDENTIFIED BY '${app_password}';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`${db}\`.* TO '${app_user}'@'%';

CREATE USER IF NOT EXISTS '${migrate_user}'@'%' IDENTIFIED BY '${migrate_password}';
ALTER USER '${migrate_user}'@'%' IDENTIFIED BY '${migrate_password}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${migrate_user}'@'%';
FLUSH PRIVILEGES;
SQL

  docker exec -e MYSQL_PWD="$app_password" fm-mysql \
    mysql -h 127.0.0.1 -u"${app_user}" -N -e "SELECT 'AUTH_OK';" >/dev/null
  docker exec -e MYSQL_PWD="$migrate_password" fm-mysql \
    mysql -h 127.0.0.1 -u"${migrate_user}" -N -e "SELECT 'AUTH_OK';" >/dev/null

  # 运行时账号必须没有 DDL：CREATE TABLE 应被拒绝。若意外成功则立即清理并失败。
  if docker exec -e MYSQL_PWD="$app_password" fm-mysql \
      mysql -h 127.0.0.1 -u"${app_user}" -e "CREATE TABLE \`${db}\`.__fm_privcheck (id INT);" >/dev/null 2>&1; then
    docker exec -e MYSQL_PWD="$app_password" fm-mysql \
      mysql -h 127.0.0.1 -u"${app_user}" -e "DROP TABLE \`${db}\`.__fm_privcheck;" >/dev/null 2>&1 || true
    echo "ERROR: ${app_user} 仍拥有 ${db} 的 DDL 权限" >&2
    exit 1
  fi
  log "${svc} 账号验证通过：运行时仅 DML，迁移账号可 DDL"
}

create_database_and_accounts user fm_user \
  "$FM_USER_DB_USER" "$FM_USER_DB_PASSWORD" \
  "$FM_USER_DB_MIGRATE_USER" "$FM_USER_DB_MIGRATE_PASSWORD"
create_database_and_accounts chat fm_chat \
  "$FM_CHAT_DB_USER" "$FM_CHAT_DB_PASSWORD" \
  "$FM_CHAT_DB_MIGRATE_USER" "$FM_CHAT_DB_MIGRATE_PASSWORD"
create_database_and_accounts reader fm_reader \
  "$FM_READER_DB_USER" "$FM_READER_DB_PASSWORD" \
  "$FM_READER_DB_MIGRATE_USER" "$FM_READER_DB_MIGRATE_PASSWORD"
create_database_and_accounts game fm_game \
  "$FM_GAME_DB_USER" "$FM_GAME_DB_PASSWORD" \
  "$FM_GAME_DB_MIGRATE_USER" "$FM_GAME_DB_MIGRATE_PASSWORD"
create_database_and_accounts music fm_music \
  "$FM_MUSIC_DB_USER" "$FM_MUSIC_DB_PASSWORD" \
  "$FM_MUSIC_DB_MIGRATE_USER" "$FM_MUSIC_DB_MIGRATE_PASSWORD"

log "完成：生产每服务运行时账号只授 DML，迁移账号只授本库 DDL。"
log "旧账号 ${MYSQL_APP_USER:-fm_app} 未做任何撤销，保留用于回滚；确认无引用后再执行退场。"
