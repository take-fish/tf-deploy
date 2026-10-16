#!/usr/bin/env bash
# 在集中机安装 FishMatrix 自动更新定时器（systemd）
#
# 用法：sudo bash scripts/install-auto-update.sh
# 卸载：sudo systemctl disable --now fm-auto-update.timer
#       sudo rm /etc/systemd/system/fm-auto-update.service /etc/systemd/system/fm-auto-update.timer
#       sudo systemctl daemon-reload
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UNIT_DIR=/etc/systemd/system

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行：sudo bash scripts/install-auto-update.sh" >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "未检测到 systemd；可改用 cron 方案（见 docs/自动更新说明.md）" >&2
  exit 1
fi

echo "仓库路径：$REPO_DIR"

# 渲染 @REPO_DIR@ 占位符后落盘
sed "s|@REPO_DIR@|$REPO_DIR|g" "$REPO_DIR/deploy/systemd/fm-auto-update.service" > "$UNIT_DIR/fm-auto-update.service"
cp "$REPO_DIR/deploy/systemd/fm-auto-update.timer" "$UNIT_DIR/fm-auto-update.timer"

systemctl daemon-reload
systemctl enable --now fm-auto-update.timer

echo ""
echo "已安装并启用。定时器会立即触发一轮（OnBootSec 已过），可留意日志。"
echo "提示：定时器以 root 运行，拉取私有镜像需先登录：sudo docker login ghcr.io"
echo ""
systemctl list-timers fm-auto-update.timer --no-pager
echo "查看运行日志：journalctl -u fm-auto-update.service -f"
