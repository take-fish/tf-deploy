#!/usr/bin/env bash
# 备份生产或测试 MySQL 的业务库
#
# 用法：
#   bash scripts/backup-mysql.sh prod [输出目录]
#   bash scripts/backup-mysql.sh test [输出目录]
#
# 说明：
#   - 生产操作 fm-mysql，测试操作 fm-test-mysql，互不影响
#   - 密码通过容器的 MYSQL_PWD 环境变量传入，不出现在宿主机命令行
#   - 备份文件默认写入 tf-deploy/backups/，权限 600，并做 gzip 完整性校验
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

MODE="${1:-}"
OUT_DIR="${2:-$REPO_DIR/backups}"

case "$MODE" in
  prod)
    CONTAINER="fm-mysql"
    ROOT_PASSWORD_VAR="MYSQL_ROOT_PASSWORD"
    DBS=(fm_user fm_chat fm_reader fm_game fm_music)
    PREFIX="prod"
    ;;
  test)
    CONTAINER="fm-test-mysql"
    ROOT_PASSWORD_VAR="TEST_MYSQL_ROOT_PASSWORD"
    DBS=(fm_test_user fm_test_chat fm_test_reader fm_test_game fm_test_music)
    PREFIX="test"
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    echo "未知模式：$MODE" >&2
    usage
    exit 1
    ;;
esac

if [ ! -f "$ENV_FILE" ]; then
  echo "未找到 $ENV_FILE，请先复制 .env.example 为 .env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090,SC1091
source <(tr -d '\r' < "$ENV_FILE")
set +a

root_password="${!ROOT_PASSWORD_VAR:-}"
: "${root_password:?$ROOT_PASSWORD_VAR 未配置}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "$CONTAINER 未运行，无法备份。" >&2
  exit 1
fi

umask 077
mkdir -p "$OUT_DIR"

timestamp=$(date +%Y%m%d-%H%M%S)
backup_file="$OUT_DIR/${PREFIX}-mysql-${timestamp}.sql.gz"
tmp_file="${backup_file}.part"

echo "[backup-mysql] 备份 $CONTAINER 到 $backup_file"
docker exec -i -e MYSQL_PWD="$root_password" "$CONTAINER" \
  mysqldump -uroot \
    --default-character-set=utf8mb4 \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --no-tablespaces \
    --databases "${DBS[@]}" \
  | gzip -c > "$tmp_file"

if [ ! -s "$tmp_file" ]; then
  rm -f "$tmp_file"
  echo "备份失败：输出为空。" >&2
  exit 1
fi
if ! gzip -t "$tmp_file"; then
  rm -f "$tmp_file"
  echo "备份失败：gzip 完整性校验未通过。" >&2
  exit 1
fi

mv "$tmp_file" "$backup_file"
echo "[backup-mysql] 完成：$(du -h "$backup_file" | cut -f1)  $backup_file"
echo "[backup-mysql] 恢复示例：gunzip -c <file> | docker exec -i -e MYSQL_PWD=\"\$ROOT_PASSWORD\" $CONTAINER mysql -uroot"
