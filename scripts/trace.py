#!/usr/bin/env python3
"""按链路编号查询集中日志（调用 tf-console 的日志检索接口）。

编号来自前端错误提示（编号 xxx）或响应头 X-Trace-ID。
控制台地址与口令从环境变量 / tf-deploy/.env 读取：

  CONSOLE_URL             默认 http://127.0.0.1:8301
  TF_CONSOLE_LOG_TOKEN    与控制台配置一致

示例：
  python3 scripts/trace.py 4bf92f3577b34da6a3ce929d0e0e4736
  python3 scripts/trace.py "发送失败（编号 4bf9...）" --env prod --lines 100
  python3 scripts/trace.py 4bf9... --range 7d --json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

DEFAULT_CONSOLE_URL = "http://127.0.0.1:8301"
ID_PATTERN = re.compile(r"[0-9a-fA-F]{8,64}")
MAX_ID_LENGTH = 64


def load_env_file() -> None:
    """读取 tf-deploy/.env，但不覆盖进程里已设置的环境变量。"""
    env_file = Path(__file__).resolve().parent.parent / ".env"
    if not env_file.is_file():
        return
    try:
        lines = env_file.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            os.environ.setdefault(key, value)


def normalize_id(raw: str) -> str:
    match = ID_PATTERN.search(raw.strip())
    if not match:
        return ""
    value = match.group(0).lower()
    if not 8 <= len(value) <= MAX_ID_LENGTH:
        return ""
    return value


def format_time(raw: str) -> str:
    if not raw:
        return "-"
    try:
        moment = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        moment = moment.astimezone()
        return moment.strftime("%Y-%m-%d %H:%M:%S.") + f"{moment.microsecond // 1000:03d}"
    except ValueError:
        return raw


def request_logs(console_url: str, token: str, params: dict[str, str]) -> dict:
    query = urllib.parse.urlencode(params)
    url = f"{console_url.rstrip('/')}/api/v1/logs/search?{query}"
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        request.add_header("X-Log-Token", token)
    try:
        with urllib.request.urlopen(request, timeout=40) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        try:
            body = json.load(exc)
            message = body.get("message") or body.get("error") or str(exc)
        except Exception:
            message = str(exc)
        if exc.code == 401:
            message += "（请检查 TF_CONSOLE_LOG_TOKEN 或运行 scripts/ensure-observability-secrets.sh）"
        raise SystemExit(f"日志检索失败：HTTP {exc.code} {message}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"无法连接流水线中台 {console_url}：{exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise SystemExit(f"日志服务返回了无法解析的数据：{exc}") from exc


def main() -> int:
    # Windows 控制台默认使用本地代码页，直接运行时中文会乱码。
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            try:
                reconfigure(encoding="utf-8")
            except (OSError, ValueError):
                pass

    load_env_file()

    parser = argparse.ArgumentParser(
        description="按链路编号查询 FishMatrix 集中日志",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("id", help="链路编号 / 请求 ID（可直接粘贴带“编号”的错误提示）")
    parser.add_argument("--env", choices=["all", "prod", "test"], default="all", help="环境")
    parser.add_argument(
        "--lines", type=int, choices=[30, 50, 100], default=30, help="命中行上下各取多少行"
    )
    parser.add_argument(
        "--range", choices=["1h", "6h", "24h", "7d", "14d"], default="24h", help="时间范围"
    )
    parser.add_argument(
        "--console-url",
        default=os.environ.get("CONSOLE_URL", DEFAULT_CONSOLE_URL),
        help="流水线中台地址",
    )
    parser.add_argument("--raw", action="store_true", help="输出原始 JSON 日志行")
    parser.add_argument("--json", action="store_true", help="输出接口原始 JSON 响应")
    args = parser.parse_args()

    trace_id = normalize_id(args.id)
    if not trace_id:
        parser.error("编号必须是 8-64 位十六进制字符")

    token = os.environ.get("TF_CONSOLE_LOG_TOKEN", "")
    result = request_logs(
        args.console_url,
        token,
        {"id": trace_id, "env": args.env, "lines": str(args.lines), "range": args.range},
    )

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get("entries") else 1

    entries = result.get("entries") or []
    environment = {"all": "全部", "prod": "生产", "test": "测试"}.get(result.get("env"), result.get("env"))
    print(f"编号  {result.get('id', trace_id)}")
    print(
        f"环境  {environment}   范围  {result.get('range')}   上下文  ±{result.get('contextLines')} 行"
    )
    print(
        f"命中  {result.get('matched', 0)} 条 / {result.get('streams', 0)} 个来源 / "
        f"共 {len(entries)} 行"
    )
    for warning in result.get("warnings") or []:
        print(f"警告  {warning}")
    if result.get("truncated"):
        print("警告  结果达到上限，已截断；请缩小时间范围或环境后重试")
    print("---")

    for entry in entries:
        if args.raw:
            print(entry.get("line", ""))
            continue
        marker = "*" if entry.get("matched") else " "
        level = (entry.get("level") or "info").upper()
        service = entry.get("service") or "unknown"
        message = (entry.get("message") or "").rstrip("\n")
        print(f"{marker} {format_time(entry.get('timestamp', ''))} {level:<7} {service:<12} {message}")

    if not entries:
        print("未找到日志。请确认编号、环境与时间范围。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
