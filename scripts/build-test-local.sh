#!/usr/bin/env bash
# 本地构建并部署测试栈（GHCR 镜像拉取受限时的备用通道）
#
# 用法：
#   bash scripts/build-test-local.sh                  # 构建全部 5 个 Java 服务
#   bash scripts/build-test-local.sh user chat        # 只构建指定服务
#
# 说明：
#   - 从各仓库当前工作树构建，便于在 feature 分支上验证尚未合并的代码
#   - 以生产 :latest 镜像为基底覆盖 app.jar，不需要拉取基础镜像
#   - 仅重建指定的测试服务，不影响生产容器与共享中间件
#
# 相关环境变量：
#   CODE_ROOT   服务仓库根目录，默认 /d/code/cloud-take-fish
#   BUILD_ROOT  构建上下文目录，默认 /d/develop/fm-test-build
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CODE_ROOT="${CODE_ROOT:-/d/code/cloud-take-fish}"
BUILD_ROOT="${BUILD_ROOT:-/d/develop/fm-test-build}"

SERVICES=("$@")
if [ "${#SERVICES[@]}" -eq 0 ]; then
  SERVICES=(user chat reader game music)
fi

log() { echo "[build-test-local] $*"; }

for svc in "${SERVICES[@]}"; do
  repo="$CODE_ROOT/tf-$svc"
  base="ghcr.io/take-fish/tf-$svc:latest"

  if [ ! -f "$repo/pom.xml" ]; then
    log "跳过 $svc：未找到 $repo/pom.xml"
    continue
  fi
  if ! docker image inspect "$base" >/dev/null 2>&1; then
    log "跳过 $svc：缺少基底镜像 $base（先等待生产自动更新拉取）"
    continue
  fi

  log "构建 tf-$svc ..."
  (cd "$repo" && mvn -B -ntp -DskipTests package)

  ctx="$BUILD_ROOT/$svc"
  mkdir -p "$ctx"
  cp "$repo/target/tf-$svc.jar" "$ctx/app.jar"
  cat > "$ctx/Dockerfile" <<EOF
FROM $base
COPY app.jar /app/app.jar
EOF
  docker build --platform linux/amd64 -t "ghcr.io/take-fish/tf-$svc:test" "$ctx"
  log "镜像已更新：ghcr.io/take-fish/tf-$svc:test"
done

log "重建测试服务：${SERVICES[*]}"
(cd "$REPO_DIR" && docker compose -f docker-compose.test.yml up -d --no-deps "${SERVICES[@]}")
log "完成"
