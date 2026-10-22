#!/bin/sh
# FishMatrix 生产 MySQL 首次初始化（仅在数据卷为空时由 MySQL 镜像执行）
#
# 只创建生产库；每服务运行时账号与迁移账号由 scripts/init-db.sh 在实例
# healthy 后创建，避免把密码写进 MySQL 容器环境。
#
# 已存在的数据卷不会执行本脚本；增量修复请使用：
#   bash scripts/init-db.sh
set -eu

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD 未配置}"

log() { echo "[fm-middleware-init] $*"; }

prod_dbs="fm_user fm_chat fm_reader fm_game fm_music"

for db in $prod_dbs; do
  echo "CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
done > /tmp/fm-prod-dbs.sql

MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=socket -uroot < /tmp/fm-prod-dbs.sql
rm -f /tmp/fm-prod-dbs.sql

log "生产库已创建：${prod_dbs}"
log "请执行 scripts/init-db.sh 创建每服务账号与迁移账号。"
