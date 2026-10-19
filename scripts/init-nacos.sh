#!/usr/bin/env bash
# FishMatrix Nacos 初始化（幂等）
#
# 作用：
#   - 创建 fm-prod / fm-test 命名空间（固定 namespace ID，便于各环境引用）
#   - 发布 deploy/nacos/{prod,test}/tf-*.yaml 到 group=FM
#   - 鉴权开启后自动登录；密码默认读取 .env 的 NACOS_ADMIN_PASSWORD
#
# 用法：
#   bash scripts/init-nacos.sh
#   NACOS_HOST=10.28.13.214:8848 NACOS_PASSWORD=*** bash scripts/init-nacos.sh
#
# 注意：Nacos standalone 的数据保存在容器 /home/nacos/data（compose 已挂载 nacos-data 卷）。
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="$REPO_DIR/.env"

NACOS_HOST="${NACOS_HOST:-127.0.0.1:8848}"
NACOS_CONTEXT="${NACOS_CONTEXT:-/nacos}"
NACOS_USERNAME="${NACOS_USERNAME:-nacos}"

if [ -z "${NACOS_PASSWORD:-}" ] && [ -f "$ENV_FILE" ]; then
  NACOS_PASSWORD=$(sed -n 's/^NACOS_ADMIN_PASSWORD=//p' "$ENV_FILE" | tr -d '\r' | tail -n1)
fi
NACOS_PASSWORD="${NACOS_PASSWORD:-}"

BASE_URL="http://${NACOS_HOST}${NACOS_CONTEXT}"
TOKEN=""

log() { echo "[init-nacos] $*"; }

login() {
  if [ -z "$NACOS_PASSWORD" ]; then
    log "未提供 NACOS_PASSWORD，按未开启鉴权处理"
    return 0
  fi

  local response
  response=$(curl -sS -X POST "${BASE_URL}/v1/auth/login" \
    --data-urlencode "username=${NACOS_USERNAME}" \
    --data-urlencode "password=${NACOS_PASSWORD}" || true)
  TOKEN=$(printf '%s' "$response" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
  if [ -n "$TOKEN" ]; then
    log "Nacos 登录成功：${NACOS_USERNAME}"
  else
    log "Nacos 登录失败（鉴权关闭时属正常；若已开启鉴权请检查账号密码）"
  fi
}

# GET 请求的鉴权查询串
auth_query() {
  if [ -n "$TOKEN" ]; then
    printf '?accessToken=%s' "$TOKEN"
  fi
}

# POST 请求：自动附加 accessToken
curl_post() {
  local url="$1"
  shift
  if [ -n "$TOKEN" ]; then
    curl -sS -X POST "$url" "$@" --data-urlencode "accessToken=${TOKEN}"
  else
    curl -sS -X POST "$url" "$@"
  fi
}

create_namespace() {
  local ns="$1" desc="$2" list result
  list=$(curl -sS "${BASE_URL}/v1/console/namespaces$(auth_query)")
  if printf '%s' "$list" | grep -q "\"namespace\":\"${ns}\""; then
    log "命名空间已存在：${ns}"
    return 0
  fi

  result=$(curl_post "${BASE_URL}/v1/console/namespaces" \
    --data-urlencode "customNamespaceId=${ns}" \
    --data-urlencode "namespaceName=${ns}" \
    --data-urlencode "namespaceDesc=${desc}")
  if ! printf '%s' "$result" | grep -q '"code":200'; then
    echo "[init-nacos] 创建命名空间 ${ns} 失败：${result}" >&2
    exit 1
  fi
  log "已创建命名空间：${ns}"
}

publish_config() {
  local ns="$1" file="$2" data_id result
  data_id=$(basename "$file")
  result=$(curl_post "${BASE_URL}/v1/cs/configs" \
    --data-urlencode "dataId=${data_id}" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=${ns}" \
    --data-urlencode "type=yaml" \
    --data-urlencode "content@${file}")
  if [ "$result" != "true" ]; then
    echo "[init-nacos] 发布配置失败 ${ns}/${data_id}（group=FM）：${result}" >&2
    exit 1
  fi
  log "已发布配置：${ns}/${data_id}（group=FM）"
}

summarize() {
  local ns="$1" total
  total=$(curl -sS "${BASE_URL}/v1/cs/configs?search=accurate&dataId=&group=FM&tenant=${ns}&pageNo=1&pageSize=100$( [ -n "$TOKEN" ] && printf '&accessToken=%s' "$TOKEN" )" \
    | grep -o '"dataId"' | wc -l | tr -d ' ')
  log "namespace ${ns} 当前配置数：${total}"
}

login
create_namespace fm-prod "FishMatrix 生产环境"
create_namespace fm-test "FishMatrix 测试环境"

shopt -s nullglob
for file in "$REPO_DIR"/deploy/nacos/prod/tf-*.yaml; do
  publish_config fm-prod "$file"
done
for file in "$REPO_DIR"/deploy/nacos/test/tf-*.yaml; do
  publish_config fm-test "$file"
done

summarize fm-prod
summarize fm-test
log "完成"
