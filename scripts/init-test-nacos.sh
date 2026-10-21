#!/bin/sh
# 共享 Nacos 的测试配置初始化（在 fm-test-nacos-init 容器内执行）
#
# 作用：
#   - 使用生产 Nacos 管理员账号登录（共享中间件只有一套管理员）
#   - 创建/复用 namespace fm-test
#   - 发布 /configs 下的 tf-*.yaml 到 group=FM
#
# 该脚本可重复执行：namespace 已存在时复用，配置发布为覆盖写。
set -eu

NACOS_HOST="${NACOS_HOST:-nacos:8848}"
NACOS_CONTEXT="${NACOS_CONTEXT:-/nacos}"
NACOS_USERNAME="${NACOS_USERNAME:-nacos}"
NACOS_PASSWORD="${NACOS_PASSWORD:-}"
NACOS_AUTH_ENABLE="${NACOS_AUTH_ENABLE:-false}"
CONFIG_DIR="${CONFIG_DIR:-/configs}"

BASE_URL="http://${NACOS_HOST}${NACOS_CONTEXT}"
TOKEN=""
TMP_BODY="/tmp/fm-test-nacos-init.$$"
trap 'rm -f "$TMP_BODY"' EXIT HUP INT TERM

log() { echo "[init-test-nacos] $*"; }

login_with() {
  password="$1"
  [ -n "$password" ] || return 1
  code=$(curl -sS -o "$TMP_BODY" -w '%{http_code}' -X POST "${BASE_URL}/v1/auth/login" \
    --data-urlencode "username=${NACOS_USERNAME}" \
    --data-urlencode "password=${password}" 2>/dev/null || true)
  [ "$code" = "200" ] || return 1
  TOKEN=$(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$TMP_BODY")
  [ -n "$TOKEN" ]
}

if [ "$NACOS_AUTH_ENABLE" = "true" ]; then
  if [ -z "$NACOS_PASSWORD" ]; then
    log "ERROR: 共享 Nacos 已开启鉴权但 NACOS_ADMIN_PASSWORD 为空"
    exit 1
  fi
  # 共享 Nacos 可能刚启动，登录失败时重试，不做管理员初始化。
  attempt=0
  until login_with "$NACOS_PASSWORD"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 60 ]; then
      log "ERROR: 无法使用 NACOS_ADMIN_PASSWORD 登录共享 Nacos，请检查 .env 与 Nacos 鉴权配置"
      exit 1
    fi
    sleep 2
  done
  log "共享 Nacos 登录成功"
else
  log "Nacos 鉴权未开启，跳过登录"
fi

auth_query() {
  if [ -n "$TOKEN" ]; then
    printf '?accessToken=%s' "$TOKEN"
  fi
}

curl_post() {
  if [ -n "$TOKEN" ]; then
    curl -sS -X POST "$@" --data-urlencode "accessToken=${TOKEN}"
  else
    curl -sS -X POST "$@"
  fi
}

create_namespace() {
  ns="$1"
  list=$(curl -sS "${BASE_URL}/v1/console/namespaces$(auth_query)")
  if printf '%s' "$list" | grep -q "\"namespace\":\"${ns}\""; then
    log "命名空间已存在：${ns}"
    return 0
  fi

  result=$(curl_post "${BASE_URL}/v1/console/namespaces" \
    --data-urlencode "customNamespaceId=${ns}" \
    --data-urlencode "namespaceName=${ns}" \
    --data-urlencode "namespaceDesc=FishMatrix 测试环境")
  if [ "$result" != "true" ] && ! printf '%s' "$result" | grep -q '"code":200'; then
    log "ERROR: 创建命名空间 ${ns} 失败"
    exit 1
  fi
  log "已创建命名空间：${ns}"
}

publish_config() {
  file="$1"
  data_id=$(basename "$file")
  content=$(cat "$file")
  result=$(curl_post "${BASE_URL}/v1/cs/configs" \
    --data-urlencode "dataId=${data_id}" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=fm-test" \
    --data-urlencode "type=yaml" \
    --data-urlencode "content=${content}")
  if [ "$result" != "true" ] && ! printf '%s' "$result" | grep -q '"code":200'; then
    log "ERROR: 发布配置失败 fm-test/${data_id}（group=FM）"
    exit 1
  fi
  log "已发布配置：fm-test/${data_id}（group=FM）"
}

if [ ! -d "$CONFIG_DIR" ]; then
  log "ERROR: 配置目录不存在：$CONFIG_DIR"
  exit 1
fi

create_namespace fm-test

count=0
for file in "$CONFIG_DIR"/tf-*.yaml; do
  [ -f "$file" ] || continue
  publish_config "$file"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  log "ERROR: $CONFIG_DIR 下没有 tf-*.yaml"
  exit 1
fi

log "完成，共发布 ${count} 个配置"
