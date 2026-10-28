#!/usr/bin/env bash
# 预建 FishMatrix RocketMQ 基础 topic（幂等，可重复执行）。
#
# 用法（在 tf-deploy 目录）：
#   bash scripts/init-rocketmq.sh test
#   bash scripts/init-rocketmq.sh prod
#
# broker 明确关闭了自动创建 topic，新增业务事件时在此登记 topic 并重跑脚本。
set -euo pipefail

ENV_NAME="${1:-test}"
case "$ENV_NAME" in
  prod) PREFIX="FM_" ;;
  test) PREFIX="FM_TEST_" ;;
  *)
    echo "用法: bash scripts/init-rocketmq.sh [test|prod]" >&2
    exit 1
    ;;
esac

NAMESRV="rocketmq-nameserver:9876"
CLUSTER="fishmatrix"
BROKER_CONTAINER="fm-rocketmq-broker"

# 业务事件 topic 在此登记：新增事件类型时追加，重跑本脚本即可。
TOPICS=(
  "${PREFIX}SYSTEM_PROBE"
  "${PREFIX}READER_ACCESS_REQUESTED"
  "${PREFIX}READER_ACCESS_DECIDED"
)

if ! docker inspect -f '{{.State.Running}}' "$BROKER_CONTAINER" 2>/dev/null | grep -q true; then
  echo "RocketMQ broker 未运行，请先执行：" >&2
  echo "  docker compose -f docker-compose.middleware.yml up -d rocketmq-nameserver rocketmq-broker" >&2
  exit 1
fi

run_mqadmin() {
  docker exec "$BROKER_CONTAINER" bash -c \
    'if command -v mqadmin >/dev/null 2>&1; then exec mqadmin "$@"; else exec /home/rocketmq/rocketmq-5.3.3/bin/mqadmin "$@"; fi' \
    -- "$@"
}

for topic in "${TOPICS[@]}"; do
  echo "预建 topic: $topic (集群 $CLUSTER, nameserver $NAMESRV)"
  run_mqadmin updateTopic -n "$NAMESRV" -c "$CLUSTER" -t "$topic"
done

echo "当前 topic 列表："
EXISTING="$(run_mqadmin topicList -n "$NAMESRV" -c "$CLUSTER")"
echo "$EXISTING"

for topic in "${TOPICS[@]}"; do
  if ! grep -qE "(^|[[:space:]])${topic}[[:space:]]*$" <<< "$EXISTING"; then
    echo "topic 校验失败：$topic 不存在" >&2
    exit 1
  fi
done
echo "RocketMQ $ENV_NAME 环境 topic 就绪（${#TOPICS[@]} 个）"
