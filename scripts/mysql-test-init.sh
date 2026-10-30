#!/bin/sh
# FishMatrix 测试 MySQL 首次初始化（仅在测试数据卷为空时由 MySQL 镜像执行）
#
# 只创建测试库；账号由 scripts/init-test-db.sh 在实例 healthy 后创建，
# 避免把每服务账号/迁移账号密码写进 MySQL 容器环境。
#
# 已存在的数据卷不会执行本脚本；增量修复请使用：
#   bash scripts/init-test-db.sh
set -eu

log() { echo "[fm-test-mysql-init] $*"; }

test_dbs="fm_test_user fm_test_chat fm_test_reader fm_test_game fm_test_music fm_test_agent"

for db in $test_dbs; do
  echo "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
done > /tmp/fm-test-dbs.sql

MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot < /tmp/fm-test-dbs.sql
rm -f /tmp/fm-test-dbs.sql

log "测试库已创建：${test_dbs}"
log "请执行 scripts/init-test-db.sh 创建每服务账号与迁移账号。"
