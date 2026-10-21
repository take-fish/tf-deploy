#!/usr/bin/env bash
# 共享中间件中的测试库初始化/修复（幂等）
#
# 作用：
#   - 在共享 fm-mysql 中创建 fm_test_user / fm_test_chat / fm_test_reader /
#     fm_test_game / fm_test_music
#   - 创建/同步测试专用 fm_test_app 账号（只授权 fm_test_% 库）
#   - 撤销旧 fm_app 对 fm_test_% 的授权（如果存在）
#   - 用于首次建库、修改 TEST_MYSQL_APP_PASSWORD 后同步账号
#
# 用法：bash scripts/init-test-db.sh
# 前置：共享中间件已启动且 fm-mysql healthy：
#   docker compose -f docker-compose.middleware.yml up -d mysql
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$REPO_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "未找到 $ENV_FILE，请先复制 .env.example 为 .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source <(tr -d '\r' < "$ENV_FILE")
set +a

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
TEST_MYSQL_APP_USER="${TEST_MYSQL_APP_USER:-fm_test_app}"
TEST_MYSQL_APP_PASSWORD="${TEST_MYSQL_APP_PASSWORD:-}"
PROD_APP_USER="${MYSQL_APP_USER:-fm_app}"

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD 未配置}"
: "${TEST_MYSQL_APP_PASSWORD:?TEST_MYSQL_APP_PASSWORD 未配置，请执行 scripts/ensure-test-secrets.sh}"

if ! [[ "$TEST_MYSQL_APP_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "TEST_MYSQL_APP_USER 只允许字母、数字与下划线" >&2
  exit 1
fi
if ! [[ "$PROD_APP_USER" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "MYSQL_APP_USER 只允许字母、数字与下划线" >&2
  exit 1
fi
if ! [[ "$TEST_MYSQL_APP_PASSWORD" =~ ^[A-Za-z0-9_.!@#%^*()+-]+$ ]]; then
  echo "TEST_MYSQL_APP_PASSWORD 含有未支持的字符（引号/反斜杠等），请更换密码" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx 'fm-mysql'; then
  echo "fm-mysql 未运行，请先执行：docker compose -f docker-compose.middleware.yml up -d mysql" >&2
  exit 1
fi

echo "等待 fm-mysql 健康检查..."
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

echo "初始化共享 MySQL 中的测试库与账号 ${TEST_MYSQL_APP_USER} ..."
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS fm_test_user CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_test_chat CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_test_reader CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_test_game CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS fm_test_music CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${TEST_MYSQL_APP_USER}'@'%' IDENTIFIED BY '${TEST_MYSQL_APP_PASSWORD}';
ALTER USER '${TEST_MYSQL_APP_USER}'@'%' IDENTIFIED BY '${TEST_MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`fm\_test\_%\`.* TO '${TEST_MYSQL_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# 旧方案中生产账号 fm_app 曾拥有 fm_test_% 授权；能撤销则撤销，避免生产凭据访问测试库。
# REVOKE 在授权不存在时会报错，这里单独执行并忽略错误。
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql mysql -uroot \
  -e "REVOKE ALL PRIVILEGES ON \`fm\_test\_%\`.* FROM '${PROD_APP_USER}'@'%';" 2>/dev/null || true
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" fm-mysql mysql -uroot \
  -e "REVOKE ALL PRIVILEGES ON \`fm\_test\_%\`.* FROM '${PROD_APP_USER}'@'localhost';" 2>/dev/null || true

echo "验证 ${TEST_MYSQL_APP_USER} 账号可通过 TCP 登录..."
docker exec -e MYSQL_PWD="$TEST_MYSQL_APP_PASSWORD" fm-mysql \
  mysql -h 127.0.0.1 -u"${TEST_MYSQL_APP_USER}" -N -e "SELECT 'AUTH_OK';"
echo "完成：测试库位于共享 fm-mysql，测试账号只授权 fm_test_% 库。"
