#!/usr/bin/env bash
# FishMatrix 集中机数据库初始化（幂等）
#
# 作用：
#   - 创建生产库 fm_user / fm_chat / fm_reader / fm_game / fm_music
#   - 创建/同步生产 fm_app 账号密码（与 .env 保持一致）
#   - 授予 fm_app 对生产库的 DDL/DML 权限（tf-reader 启动时自动建表）
#
# 测试库位于同一套共享中间件的 fm-mysql 中，由 scripts/init-test-db.sh 管理；
# 本脚本不创建或授权任何 fm_test_* 库。
#
# 用法：bash scripts/init-db.sh
# 前置：docker compose -f docker-compose.middleware.yml up -d mysql 且容器 healthy
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$REPO_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "未找到 $ENV_FILE，请先复制 .env.example 为 .env 并填写凭据" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source <(tr -d '\r' < "$ENV_FILE")
set +a

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD 未配置}"
: "${MYSQL_APP_USER:?MYSQL_APP_USER 未配置}"
: "${MYSQL_APP_PASSWORD:?MYSQL_APP_PASSWORD 未配置}"

if ! [[ "$MYSQL_APP_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "MYSQL_APP_USER 只允许字母、数字与下划线" >&2
  exit 1
fi
if ! [[ "$MYSQL_APP_PASSWORD" =~ ^[A-Za-z0-9_.!@#%^*()+-]+$ ]]; then
  echo "MYSQL_APP_PASSWORD 含有未支持的字符（引号/反斜杠等），请更换密码" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'fm-mysql'; then
  echo "fm-mysql 未运行，请先执行：docker compose -f docker-compose.middleware.yml up -d mysql" >&2
  exit 1
fi

echo "等待 fm-mysql 健康检查..."
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

echo "初始化数据库与账号 ${MYSQL_APP_USER} ..."
# 旧方案曾授予 fm_app 对 fm\_% 的通配权限（包含 fm_test_%）。先撤销通配授权，
# 再按生产库逐个授权；--force 允许 REVOKE 在授权不存在时继续执行后续 GRANT。
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql mysql --force -uroot <<SQL
CREATE DATABASE IF NOT EXISTS fm_user CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_chat CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_reader CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_game CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_music CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
REVOKE ALL PRIVILEGES ON \`fm\_%\`.* FROM '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_user\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_chat\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_reader\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_game\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_music\`.* TO '${MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "完成。当前授权："
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql \
  mysql -uroot -N -e "SHOW GRANTS FOR '${MYSQL_APP_USER}'@'%';"

echo "验证 ${MYSQL_APP_USER} 账号可通过 TCP 登录..."
docker exec -e MYSQL_PWD="$MYSQL_APP_PASSWORD" fm-mysql \
  mysql -h 127.0.0.1 -u"${MYSQL_APP_USER}" -N -e "SELECT 'AUTH_OK';"
echo "提示：tf-reader 首次启动会自动执行 schema.sql / data.sql 建表并写入演示数据。"
