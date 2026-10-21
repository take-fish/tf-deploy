#!/bin/sh
# FishMatrix 共享中间件 MySQL 首次初始化（仅在数据卷为空时由 MySQL 镜像执行）
#
# 创建：
#   - 生产库 fm_user / fm_chat / fm_reader / fm_game / fm_music
#   - 测试库 fm_test_user / fm_test_chat / fm_test_reader / fm_test_game / fm_test_music
#   - 生产账号 fm_app，只授权生产库
#   - 测试账号 fm_test_app，只授权 fm_test_% 库
#
# 已存在的数据卷不会执行本脚本；增量修复请使用：
#   bash scripts/init-db.sh
#   bash scripts/init-test-db.sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD 未配置}"
: "${MYSQL_APP_USER:?MYSQL_APP_USER 未配置}"
: "${MYSQL_APP_PASSWORD:?MYSQL_APP_PASSWORD 未配置}"

MYSQL_TEST_APP_USER="${MYSQL_TEST_APP_USER:-fm_test_app}"
MYSQL_TEST_APP_PASSWORD="${MYSQL_TEST_APP_PASSWORD:-}"

log() { echo "[fm-middleware-init] $*"; }

prod_dbs="fm_user fm_chat fm_reader fm_game fm_music"
test_dbs="fm_test_user fm_test_chat fm_test_reader fm_test_game fm_test_music"

for db in $prod_dbs; do
  echo "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
done > /tmp/fm-prod-dbs.sql
for db in $test_dbs; do
  echo "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
done > /tmp/fm-test-dbs.sql

MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot < /tmp/fm-prod-dbs.sql
MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot < /tmp/fm-test-dbs.sql
rm -f /tmp/fm-prod-dbs.sql /tmp/fm-test-dbs.sql

MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
ALTER USER '${MYSQL_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`fm_user\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_chat\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_reader\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_game\`.* TO '${MYSQL_APP_USER}'@'%';
GRANT ALL PRIVILEGES ON \`fm_music\`.* TO '${MYSQL_APP_USER}'@'%';
SQL
log "生产库与账号 ${MYSQL_APP_USER} 已初始化"

if [ -n "$MYSQL_TEST_APP_PASSWORD" ]; then
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot <<SQL
CREATE USER IF NOT EXISTS '${MYSQL_TEST_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_TEST_APP_PASSWORD}';
ALTER USER '${MYSQL_TEST_APP_USER}'@'%' IDENTIFIED BY '${MYSQL_TEST_APP_PASSWORD}';
GRANT ALL PRIVILEGES ON \`fm\_test\_%\`.* TO '${MYSQL_TEST_APP_USER}'@'%';
FLUSH PRIVILEGES;
SQL
  log "测试库与账号 ${MYSQL_TEST_APP_USER} 已初始化"
else
  log "MYSQL_TEST_APP_PASSWORD 为空，跳过测试账号；稍后执行 scripts/init-test-db.sh 补齐"
fi
