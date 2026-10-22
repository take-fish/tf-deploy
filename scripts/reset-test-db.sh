#!/usr/bin/env bash
# 清空并重建测试 MySQL 中的业务库（只允许操作 fm-test-mysql）
#
# 会删除以下测试库中的全部数据：
#   fm_test_user / fm_test_chat / fm_test_reader / fm_test_game / fm_test_music
# 不会删除账号、不会操作生产 fm-mysql。
#
# 用法：
#   bash scripts/backup-mysql.sh test          # 建议先备份
#   bash scripts/reset-test-db.sh --yes        # 交互输入确认短语
#   FM_TEST_RESET_CONFIRM="RESET fm-test-mysql" bash scripts/reset-test-db.sh --yes
#
# 三重保护：
#   1. 容器名必须为 fm-test-mysql，且 /var/lib/mysql 必须挂载
#      fishmatrix_test-mysql-data 数据卷
#   2. 必须显式传入 --yes
#   3. 必须输入/提供确认短语 RESET fm-test-mysql
#
# 重置后重新启动测试栈，db-migrate-* 任务会通过 Flyway 重建表结构。
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
CONTAINER="fm-test-mysql"
EXPECTED_VOLUME="fishmatrix_test-mysql-data"
CONFIRM_PHRASE="RESET fm-test-mysql"
DBS=(fm_test_user fm_test_chat fm_test_reader fm_test_game fm_test_music)

log() { echo "[reset-test-db] $*"; }

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

assume_yes=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数：$arg" >&2; usage; exit 1 ;;
  esac
done

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

if [ "$assume_yes" != "1" ]; then
  echo "拒绝执行：这是破坏性操作，必须显式传入 --yes。" >&2
  echo "建议先执行：bash scripts/backup-mysql.sh test" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$CONTAINER 未运行，请先执行：docker compose -f docker-compose.middleware.yml up -d mysql-test" >&2
  exit 1
fi

mounted_volume=$(docker inspect "$CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}')
if [ "$mounted_volume" != "$EXPECTED_VOLUME" ]; then
  echo "拒绝执行：$CONTAINER 的数据目录挂载为 '${mounted_volume:-<none>}'，" >&2
  echo "预期为 '$EXPECTED_VOLUME'。为避免误删生产数据，已中止。" >&2
  exit 1
fi

if [ -t 0 ]; then
  read -r -p "确认清空测试库？请输入 \"$CONFIRM_PHRASE\"：" reply
else
  reply="${FM_TEST_RESET_CONFIRM:-}"
fi
if [ "$reply" != "$CONFIRM_PHRASE" ]; then
  echo "确认短语不匹配，已中止。" >&2
  exit 1
fi

log "清空并重建测试库：${DBS[*]}"
docker exec -i -e MYSQL_PWD="$TEST_MYSQL_ROOT_PASSWORD" "$CONTAINER" mysql -uroot <<SQL
$(for db in "${DBS[@]}"; do
  echo "DROP DATABASE IF EXISTS \`$db\`;"
  echo "CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
done)
SQL

remaining=$(docker exec -e MYSQL_PWD="$TEST_MYSQL_ROOT_PASSWORD" "$CONTAINER" mysql -uroot -N -e \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ('fm_test_user','fm_test_chat','fm_test_reader','fm_test_game','fm_test_music');")
if [ "${remaining:-0}" != "0" ]; then
  echo "重建后仍存在 ${remaining} 张表，请检查。" >&2
  exit 1
fi

log "完成：5 个测试库已清空，账号保持不变。"
log "下一步（在 tf-deploy 目录执行）："
log "  docker compose -f docker-compose.test.yml up --force-recreate db-migrate-user db-migrate-chat db-migrate-reader"
log "  docker compose -f docker-compose.test.yml up -d --no-deps --force-recreate user chat reader"
log "user 重启后会由 AdminSeeder 重建测试管理员。"
