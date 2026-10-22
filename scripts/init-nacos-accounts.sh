#!/usr/bin/env bash
# 创建/更新 Nacos 分级账号、角色与 namespace 权限（幂等）
#
# 账号：
#   fm-gateway-ro-prod / fm-gateway-ro-test  目标 namespace 只读
#   fm-app-rw-prod / fm-app-rw-test          目标 namespace 读写（配置读 + 注册写）
#   fm-config-admin                          fm-prod / fm-test 配置读写
#
# 说明：
#   - 需要 Nacos 管理员账号，仅用于创建账号；应用与网关不再使用管理员
#   - 密码从 .env 读取，不打印
#   - 权限粒度为 namespace 级，符合底座优化文档 8.2 的取舍
#
# 用法：
#   bash scripts/ensure-nacos-secrets.sh
#   bash scripts/init-nacos-accounts.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"
NACOS_HOST="${NACOS_HOST:-127.0.0.1:8848}"
NACOS_CONTEXT="${NACOS_CONTEXT:-/nacos}"
BASE_URL="http://${NACOS_HOST}${NACOS_CONTEXT}"

log() { echo "[init-nacos-accounts] $*"; }
fail() { echo "[init-nacos-accounts] ERROR: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || fail "未找到 $ENV_FILE，请先运行 ensure-nacos-secrets.sh"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

[ "${NACOS_AUTH_ENABLE:-false}" = "true" ] || fail "NACOS_AUTH_ENABLE 未开启，分级账号不会生效"
ADMIN_USER="${NACOS_USERNAME:-nacos}"
ADMIN_PASS="${NACOS_ADMIN_PASSWORD:-}"
[ -n "$ADMIN_PASS" ] || fail "NACOS_ADMIN_PASSWORD 为空"

for key in GATEWAY_NACOS_USERNAME GATEWAY_NACOS_PASSWORD TEST_GATEWAY_NACOS_USERNAME TEST_GATEWAY_NACOS_PASSWORD \
  FM_APP_NACOS_USERNAME FM_APP_NACOS_PASSWORD TEST_FM_APP_NACOS_USERNAME TEST_FM_APP_NACOS_PASSWORD \
  FM_CONFIG_ADMIN_USERNAME FM_CONFIG_ADMIN_PASSWORD; do
  [ -n "${!key:-}" ] || fail "$key 为空，请先运行 ensure-nacos-secrets.sh"
done

TOKEN=""
TMP_BODY=$(mktemp)
trap 'rm -f "$TMP_BODY"' EXIT HUP INT TERM

login() {
  local username="$1" password="$2"
  local response token
  response=$(curl -sS -X POST "${BASE_URL}/v1/auth/login" \
    --data-urlencode "username=${username}" \
    --data-urlencode "password=${password}" 2>/dev/null || true)
  token=$(printf '%s' "$response" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || return 1
  TOKEN="$token"
}

api_get() {
  local path="$1"
  shift
  curl -sS --get "${BASE_URL}${path}" "$@" --data-urlencode "accessToken=${TOKEN}"
}

api_post() {
  local path="$1"
  shift
  curl -sS -X POST "${BASE_URL}${path}" "$@" --data-urlencode "accessToken=${TOKEN}"
}

api_delete() {
  local path="$1"
  shift
  curl -sS -X DELETE --get "${BASE_URL}${path}" "$@" --data-urlencode "accessToken=${TOKEN}"
}

total_count() {
  sed -n 's/.*"totalCount":\([0-9][0-9]*\).*/\1/p' | head -n1
}

ensure_user() {
  local username="$1" password="$2" body total result
  body=$(api_get "/v1/auth/users" \
    --data-urlencode "username=${username}" \
    --data-urlencode "search=accurate" \
    --data-urlencode "pageNo=1" \
    --data-urlencode "pageSize=10")
  total=$(printf '%s' "$body" | total_count)
  if [ "${total:-0}" = "0" ]; then
    result=$(api_post "/v1/auth/users" \
      --data-urlencode "username=${username}" \
      --data-urlencode "password=${password}")
    case "$result" in
      *"create user ok"*) log "已创建用户：${username}" ;;
      *) fail "创建用户 ${username} 失败" ;;
    esac
  else
    result=$(curl -sS -X PUT --get "${BASE_URL}/v1/auth/users" \
      --data-urlencode "username=${username}" \
      --data-urlencode "newPassword=${password}" \
      --data-urlencode "accessToken=${TOKEN}")
    case "$result" in
      *"update user ok"*) log "已同步用户密码：${username}" ;;
      *) fail "更新用户 ${username} 密码失败" ;;
    esac
  fi
}

ensure_role() {
  local role="$1" username="$2" body total result
  body=$(api_get "/v1/auth/roles" \
    --data-urlencode "username=${username}" \
    --data-urlencode "search=accurate" \
    --data-urlencode "pageNo=1" \
    --data-urlencode "pageSize=20")
  total=$(printf '%s' "$body" | total_count)
  if [ "${total:-0}" != "0" ] && printf '%s' "$body" | grep -q "\"role\":\"${role}\""; then
    log "角色已绑定：${role} -> ${username}"
    return
  fi
  result=$(api_post "/v1/auth/roles" \
    --data-urlencode "role=${role}" \
    --data-urlencode "username=${username}")
  case "$result" in
    *"add role ok"*) log "已绑定角色：${role} -> ${username}" ;;
    *) fail "绑定角色 ${role} -> ${username} 失败" ;;
  esac
}

ensure_permission() {
  local role="$1" resource="$2" action="$3" body total result
  body=$(api_get "/v1/auth/permissions" \
    --data-urlencode "role=${role}" \
    --data-urlencode "resource=${resource}" \
    --data-urlencode "action=${action}" \
    --data-urlencode "search=accurate" \
    --data-urlencode "pageNo=1" \
    --data-urlencode "pageSize=20")
  total=$(printf '%s' "$body" | total_count)
  if [ "${total:-0}" != "0" ]; then
    log "权限已存在：${role} ${resource} ${action}"
    return
  fi
  result=$(api_post "/v1/auth/permissions" \
    --data-urlencode "role=${role}" \
    --data-urlencode "resource=${resource}" \
    --data-urlencode "action=${action}")
  case "$result" in
    *"add permission ok"*) log "已授权：${role} ${resource} ${action}" ;;
    *) fail "授权 ${role} ${resource} ${action} 失败" ;;
  esac
}

ensure_account() {
  local username="$1" password="$2" role="$3" namespace="$4"
  shift 4
  ensure_user "$username" "$password"
  ensure_role "$role" "$username"
  # Nacos 的权限 action 按操作精确匹配：读写账号必须分别授予 r 和 w，
  # 只给 rw 时配置发布会被 403 拒绝（实测 Nacos 2.5.1）。
  local action
  for action in "$@"; do
    ensure_permission "$role" "${namespace}:*:*" "$action"
  done
}

login "$ADMIN_USER" "$ADMIN_PASS" || fail "Nacos 管理员登录失败"

ensure_account "$GATEWAY_NACOS_USERNAME" "$GATEWAY_NACOS_PASSWORD" fm-gateway-ro-prod fm-prod r
ensure_account "$TEST_GATEWAY_NACOS_USERNAME" "$TEST_GATEWAY_NACOS_PASSWORD" fm-gateway-ro-test fm-test r
ensure_account "$FM_APP_NACOS_USERNAME" "$FM_APP_NACOS_PASSWORD" fm-app-rw-prod fm-prod r w
ensure_account "$TEST_FM_APP_NACOS_USERNAME" "$TEST_FM_APP_NACOS_PASSWORD" fm-app-rw-test fm-test r w
ensure_user "$FM_CONFIG_ADMIN_USERNAME" "$FM_CONFIG_ADMIN_PASSWORD"
ensure_role fm-config-admin "$FM_CONFIG_ADMIN_USERNAME"
ensure_permission fm-config-admin "fm-prod:*:*" r
ensure_permission fm-config-admin "fm-prod:*:*" w
ensure_permission fm-config-admin "fm-test:*:*" r
ensure_permission fm-config-admin "fm-test:*:*" w

# ── 测试 namespace 权限验证 ──
PROBE_DATA_ID="__fm_auth_probe__"
# 使用临时服务名：探针只验证临时实例注册权限。
# Spring Cloud Alibaba 默认注册临时实例（ephemeral=true）；持久实例依赖 Raft，
# 单机 Nacos 的 naming_persistent_service_v2 可能无 Leader，不适合作为权限探针。
PROBE_SERVICE="__fm_auth_probe_eph__"

verify_read() {
  local username="$1" password="$2" token body
  login "$username" "$password" || fail "${username} 登录失败"
  body=$(api_get "/v1/cs/configs" \
    --data-urlencode "dataId=tf-gateway.yaml" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=fm-test")
  [ -n "$body" ] || fail "${username} 无法读取 fm-test/tf-gateway.yaml"
  log "验证通过：${username} 可读取 fm-test 配置"
}

verify_gateway_readonly() {
  local username="$1" password="$2" token result
  login "$username" "$password" || fail "${username} 登录失败"
  result=$(api_post "/v1/cs/configs" \
    --data-urlencode "dataId=${PROBE_DATA_ID}" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=fm-test" \
    --data-urlencode "type=yaml" \
    --data-urlencode "content=probe: true")
  if [ "$result" = "true" ] || printf '%s' "$result" | grep -q '"code":200'; then
    api_delete "/v1/cs/configs" \
      --data-urlencode "dataId=${PROBE_DATA_ID}" \
      --data-urlencode "group=FM" \
      --data-urlencode "tenant=fm-test" >/dev/null 2>&1 || true
    fail "${username} 不应拥有配置写权限"
  fi
  log "验证通过：${username} 无配置写权限"
}

verify_app_register() {
  local username="$1" password="$2" token result listing
  login "$username" "$password" || fail "${username} 登录失败"
  result=$(api_post "/v1/ns/instance" \
    --data-urlencode "serviceName=${PROBE_SERVICE}" \
    --data-urlencode "groupName=DEFAULT_GROUP" \
    --data-urlencode "namespaceId=fm-test" \
    --data-urlencode "ip=127.0.0.1" \
    --data-urlencode "port=1" \
    --data-urlencode "ephemeral=true")
  if ! printf '%s' "$result" | grep -Eq '(^ok$|"ok"|true)'; then
    fail "${username} 无法注册服务实例"
  fi
  # 临时实例写入 Distro 后经内部同步才可见，允许短暂延迟
  local attempt=0
  while [ "$attempt" -lt 5 ]; do
    listing=$(api_get "/v1/ns/instance/list" \
      --data-urlencode "serviceName=${PROBE_SERVICE}" \
      --data-urlencode "groupName=DEFAULT_GROUP" \
      --data-urlencode "namespaceId=fm-test")
    if printf '%s' "$listing" | grep -q '"ip":"127.0.0.1"'; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  if ! printf '%s' "$listing" | grep -q '"ip":"127.0.0.1"'; then
    fail "${username} 注册后实例列表不可见"
  fi
  api_delete "/v1/ns/instance" \
    --data-urlencode "serviceName=${PROBE_SERVICE}" \
    --data-urlencode "groupName=DEFAULT_GROUP" \
    --data-urlencode "namespaceId=fm-test" \
    --data-urlencode "ip=127.0.0.1" \
    --data-urlencode "port=1" \
    --data-urlencode "ephemeral=true" >/dev/null 2>&1 || true
  log "验证通过：${username} 可注册服务实例"
}

verify_config_admin_write() {
  local username="$1" password="$2" token result
  login "$username" "$password" || fail "${username} 登录失败"
  result=$(api_post "/v1/cs/configs" \
    --data-urlencode "dataId=${PROBE_DATA_ID}" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=fm-test" \
    --data-urlencode "type=yaml" \
    --data-urlencode "content=probe: true")
  if ! { [ "$result" = "true" ] || printf '%s' "$result" | grep -q '"code":200'; }; then
    fail "${username} 无法发布配置"
  fi
  api_delete "/v1/cs/configs" \
    --data-urlencode "dataId=${PROBE_DATA_ID}" \
    --data-urlencode "group=FM" \
    --data-urlencode "tenant=fm-test" >/dev/null 2>&1 || true
  log "验证通过：${username} 可发布配置"
}

verify_read "$TEST_GATEWAY_NACOS_USERNAME" "$TEST_GATEWAY_NACOS_PASSWORD"
verify_gateway_readonly "$TEST_GATEWAY_NACOS_USERNAME" "$TEST_GATEWAY_NACOS_PASSWORD"
verify_app_register "$TEST_FM_APP_NACOS_USERNAME" "$TEST_FM_APP_NACOS_PASSWORD"
verify_config_admin_write "$FM_CONFIG_ADMIN_USERNAME" "$FM_CONFIG_ADMIN_PASSWORD"

log "完成。生产/测试分级账号已就绪。"
log "下一步：将服务与网关的 NACOS_USERNAME/PASSWORD 切换为各自账号，并重建测试栈。"
