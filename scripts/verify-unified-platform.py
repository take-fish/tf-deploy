#!/usr/bin/env python3
"""统一权限、Reader/Music 双库与访问申请的测试栈端到端验证。

只访问测试栈（18080），凭据从 tf-deploy/.env 读取；全程不打印 token 或密码。
用法：python scripts/verify-unified-platform.py
"""

from __future__ import annotations

import json
import os
import random
import re
import string
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE = os.environ.get("VERIFY_BASE_URL", "http://127.0.0.1:18080")
ROOT = Path(__file__).resolve().parents[1]
FAILURES: list[str] = []


def load_env() -> dict[str, str]:
    values: dict[str, str] = {}
    env_file = ROOT / ".env"
    if not env_file.exists():
        raise SystemExit("缺少 tf-deploy/.env")
    for raw in env_file.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key.strip()] = value
    return values


ENV = load_env()


def request(method: str, path: str, token: str | None = None, body: object | None = None,
            headers: dict[str, str] | None = None, base: str = BASE) -> tuple[int, dict, bytes]:
    data = None
    final_headers = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        final_headers["Content-Type"] = "application/json"
    if token:
        final_headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=data, headers=final_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()
    except urllib.error.URLError as exc:
        raise SystemExit(f"无法连接 {base}: {exc.reason}") from exc


def multipart(path: str, token: str, fields: dict[str, str], filename: str,
              content: bytes, content_type: str) -> tuple[int, dict, bytes]:
    boundary = "----fm-" + uuid.uuid4().hex
    chunks: list[bytes] = []
    for key, value in fields.items():
        chunks.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'
            .encode("utf-8"))
    chunks.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode("utf-8"))
    chunks.append(content)
    chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    data = b"".join(chunks)
    req = urllib.request.Request(
        BASE + path, data=data, method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(data)),
        })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read()


def parse(body: bytes) -> dict:
    try:
        value = json.loads(body or b"{}")
        return value if isinstance(value, dict) else {}
    except json.JSONDecodeError:
        return {}


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"  PASS {name}")
    else:
        print(f"  FAIL {name}{(' · ' + detail) if detail else ''}")
        FAILURES.append(name)


def error_detail(body: bytes) -> str:
    payload = parse(body)
    return str(payload.get("error") or payload.get("message") or "")[:200]


def login(username: str, password: str) -> tuple[int, str, dict]:
    status, _, body = request("POST", "/api/v1/user/auth/login",
                              body={"username": username, "password": password})
    payload = parse(body)
    return status, str(payload.get("token") or ""), payload.get("user") or {}


def register_random_user(prefix: str) -> tuple[str, str, int]:
    suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
    username = f"{prefix}{suffix}"
    password = "E2e!" + "".join(random.choices(string.ascii_letters + string.digits, k=12))
    status, _, body = request("POST", "/api/v1/user/auth/register",
                              body={"username": username, "password": password})
    if status != 201:
        raise SystemExit(f"注册测试用户失败：{status} {error_detail(body)}")
    return username, password, status


def approve_user(admin_token: str, username: str) -> int:
    status, _, body = request("GET", f"/api/v1/user/admin/users?q={username}&size=20",
                              token=admin_token)
    if status != 200:
        raise SystemExit(f"查询用户失败：{status} {error_detail(body)}")
    payload = parse(body)
    items = payload.get("items") or payload.get("users") or []
    target = next((item for item in items if item.get("username") == username), None)
    if target is None:
        raise SystemExit("管理员列表中找不到新注册用户")
    status, _, body = request("POST", f"/api/v1/user/admin/users/{target['id']}/approve",
                              token=admin_token)
    if status != 200:
        raise SystemExit(f"审批用户失败：{status} {error_detail(body)}")
    return int(target["id"])


def chapter_text() -> bytes:
    return (
        "第一章 开端\n"
        "摸鱼矩阵的统一权限从用户中台出发，业务服务只消费身份快照。\n"
        "第二章 落地\n"
        "公共库开放上传，私有库只对本人与获批访客可见。\n"
        "第三章 收束\n"
        "访问申请由 owner 决定，分享链接本身不等于授权。\n"
    ).encode("utf-8")


def wav_bytes() -> bytes:
    sample_rate = 8000
    data = bytes(1200)
    header = (
        b"RIFF" + (36 + len(data)).to_bytes(4, "little") + b"WAVE"
        + b"fmt " + (16).to_bytes(4, "little") + (1).to_bytes(2, "little")
        + (1).to_bytes(2, "little") + sample_rate.to_bytes(4, "little")
        + (sample_rate * 2).to_bytes(4, "little") + (2).to_bytes(2, "little")
        + (16).to_bytes(2, "little") + b"data" + len(data).to_bytes(4, "little"))
    return header + data


def main() -> int:
    admin_user = ENV.get("USER_ADMIN_USERNAME", "admin")
    admin_password = ENV.get("TEST_USER_ADMIN_PASSWORD", "")
    if not admin_password:
        raise SystemExit("缺少 TEST_USER_ADMIN_PASSWORD")

    print("[1] 管理员身份与权限目录")
    status, admin_token, admin = login(admin_user, admin_password)
    check("管理员登录 200", status == 200)
    check("身份快照 role=ADMIN", admin.get("role") == "ADMIN")
    check("管理员拥有全部权限", len(admin.get("permissions") or []) >= 11)
    status, _, me_body = request("GET", "/api/v1/user/auth/me", token=admin_token)
    me = parse(me_body)
    check("GET /auth/me 200 且含 roles", status == 200 and bool(me.get("roles")))
    status, _, body = request("GET", "/api/v1/user/admin/permissions", token=admin_token)
    catalog = parse(body)
    roles = catalog.get("roles") or []
    role_names = {str(item.get("role")) for item in roles}
    check("权限目录 200 且含 USER/ADMIN", status == 200 and {"USER", "ADMIN"} <= role_names)

    print("[2] 未登录与伪造身份头一律拒绝")
    check("匿名 reader 401", request("GET", "/api/v1/reader/books")[0] == 401)
    check("匿名 music 401", request("GET", "/api/v1/music/tracks")[0] == 401)
    forged, _, _ = request(
        "GET", "/api/v1/reader/books",
        headers={"X-FM-User-Id": "1", "X-FM-Permissions": "reader.content.manage.any"},
        base="http://127.0.0.1:18103")
    check("直连服务伪造签名头 401", forged == 401)
    direct, _, _ = request("GET", "/api/v1/reader/books", token=admin_token,
                           base="http://127.0.0.1:18103")
    check("直连服务 Bearer 回退 200", direct == 200)

    print("[3] 注册、审批与普通用户身份")
    username, password, _ = register_random_user("e2e")
    approve_user(admin_token, username)
    status, user_token, user = login(username, password)
    check("普通用户登录 200", status == 200)
    check("普通用户 role=USER", user.get("role") == "USER")
    perms = set(user.get("permissions") or [])
    check("默认权限含 reader/music 上传与私有管理",
          {"reader.public.upload", "reader.private.manage", "music.public.upload",
           "music.private.manage"} <= perms)
    status, _, body = request("GET", "/api/v1/user/admin/permissions", token=user_token)
    check("普通用户读取权限目录 403", status == 403)

    print("[4] Reader 双库与访问申请")
    status, _, body = request("GET", "/api/v1/reader/books?scope=public", token=user_token)
    page = parse(body)
    check("公共书库 200", status == 200)
    check("公共书库含演示书籍", any("古文观止" in str(b.get("title")) for b in page.get("books", [])))
    status, _, body = multipart(
        "/api/v1/reader/books/import", user_token,
        {"scope": "private", "title": "E2E 私有书"}, "e2e-private.txt",
        chapter_text(), "text/plain")
    book = parse(body)
    book_id = book.get("id")
    check("上传私有书 201", status == 201, error_detail(body))
    check("私有书 mine=true 且 scope=PRIVATE",
          book.get("mine") is True and book.get("scope") == "PRIVATE")
    status, _, _ = request("GET", f"/api/v1/reader/books/{book_id}", token=admin_token)
    check("管理员未获批访问私有书 404", status == 404)
    status, _, body = request("POST", f"/api/v1/reader/books/{book_id}/share", token=user_token)
    share = parse(body).get("shareToken")
    check("owner 生成分享链接 200", status == 200 and bool(share))
    status, _, body = request("GET", f"/api/v1/reader/books/shared/{share}", token=admin_token)
    check("分享链接预览不含正文 200", status == 200 and "chapters" not in parse(body))
    status, _, body = request("POST", f"/api/v1/reader/books/{book_id}/access-requests",
                              token=admin_token, body={"shareToken": share, "message": "验证访问"})
    access_id = parse(body).get("id")
    check("发起访问申请 201 PENDING",
          status == 201 and parse(body).get("status") == "PENDING", error_detail(body))
    status, _, body = request("GET", "/api/v1/reader/access-requests/received",
                              token=user_token)
    check("owner 收到申请", status == 200 and any(
        item.get("id") == access_id for item in parse(body).get("requests", [])))
    status, _, body = request("POST", f"/api/v1/reader/access-requests/{access_id}/approve",
                              token=user_token)
    check("owner 同意申请", status == 200 and parse(body).get("status") == "APPROVED")
    status, _, _ = request("GET", f"/api/v1/reader/books/{book_id}", token=admin_token)
    check("获批后管理员可读书 200", status == 200)
    status, _, body = request(
        "GET", f"/api/v1/reader/books/{book_id}/chapters/0", token=admin_token)
    check("获批后可读章节正文", status == 200 and bool(parse(body).get("content")))
    status, _, body = request("POST", f"/api/v1/reader/access-requests/{access_id}/revoke",
                              token=user_token)
    check("owner 收回授权", status == 200 and parse(body).get("status") == "REVOKED")
    status, _, _ = request("GET", f"/api/v1/reader/books/{book_id}", token=admin_token)
    check("收回后重新 404", status == 404)

    print("[5] 权限隔离与个人书单")
    second_name, second_password, _ = register_random_user("e2f")
    approve_user(admin_token, second_name)
    _, second_token, second = login(second_name, second_password)
    check("第二个普通用户登录", bool(second_token) and second.get("role") == "USER")
    status, _, _ = request("GET", f"/api/v1/reader/books/{book_id}", token=second_token)
    check("其他普通用户访问私有书 404", status == 404)
    status, _, _ = request("DELETE", f"/api/v1/reader/books/{book_id}", token=second_token)
    check("其他普通用户删除私有书 404", status == 404)
    status, _, body = request("POST", "/api/v1/reader/shelves", token=user_token,
                              body={"name": "E2E 书单", "description": "验证"})
    shelf_id = parse(body).get("id")
    check("创建个人书单 201", status == 201 and bool(shelf_id))
    status, _, _ = request("POST", f"/api/v1/reader/shelves/{shelf_id}/books/{book_id}",
                           token=user_token)
    check("书单加入书籍 204", status == 204)
    status, _, _ = request("GET", f"/api/v1/reader/shelves/{shelf_id}", token=second_token)
    check("他人书单 404", status == 404)

    print("[6] Music 双库、歌单与流式播放")
    status, _, body = multipart(
        "/api/v1/music/tracks/import", user_token,
        {"scope": "private", "title": "E2E 私有曲", "artist": "Tester"}, "e2e-private.wav",
        wav_bytes(), "audio/wav")
    track = parse(body)
    track_id = track.get("id")
    check("上传私有曲目 201", status == 201, error_detail(body))
    check("私有曲目 mine=true", track.get("mine") is True and track.get("scope") == "PRIVATE")
    status, headers, body = request("GET", f"/api/v1/music/tracks/{track_id}/stream",
                                    token=user_token, headers={"Range": "bytes=0-99"})
    check("owner Range 播放 206 且 100 字节",
          status == 206 and len(body) == 100
          and str(headers.get("Accept-Ranges", "")).lower() == "bytes")
    status, _, _ = request("GET", f"/api/v1/music/tracks/{track_id}/stream", token=admin_token)
    check("未获批管理员播放私有曲 404", status == 404)
    status, _, body = request("POST", f"/api/v1/music/tracks/{track_id}/share", token=user_token)
    share = parse(body).get("shareToken")
    check("owner 生成曲目分享链接", status == 200 and bool(share))
    status, _, body = request("POST", f"/api/v1/music/tracks/{track_id}/access-requests",
                              token=admin_token, body={"shareToken": share, "message": "验证"})
    access_id = parse(body).get("id")
    check("发起曲目访问申请 201", status == 201, error_detail(body))
    status, _, _ = request("POST", f"/api/v1/music/access-requests/{access_id}/approve",
                           token=user_token)
    check("owner 同意曲目申请", status == 200)
    status, _, body = request("GET", f"/api/v1/music/tracks/{track_id}/stream",
                              token=admin_token, headers={"Range": "bytes=0-99"})
    check("获批后管理员 Range 播放 206", status == 206 and len(body) == 100)
    status, _, body = request("POST", "/api/v1/music/playlists", token=user_token,
                              body={"name": "E2E 歌单", "description": "验证"})
    playlist_id = parse(body).get("id")
    check("创建个人歌单 201", status == 201 and bool(playlist_id))
    status, _, _ = request("POST", f"/api/v1/music/playlists/{playlist_id}/tracks/{track_id}",
                           token=user_token)
    check("歌单加入曲目 204", status == 204)
    status, _, body = request("GET", f"/api/v1/music/playlists/{playlist_id}", token=second_token)
    check("他人歌单 404", status == 404)

    print("[7] 管理页静态入口")
    status, _, body = request("GET", "/api/v1/user/admin/index.html")
    html = body.decode("utf-8", errors="ignore")
    check("用户中台管理页 200", status == 200)
    check("管理页含角色权限标签", "角色权限" in html and "permissionsView" in html)

    print()
    if FAILURES:
        print(f"失败 {len(FAILURES)} 项：" + "；".join(FAILURES))
        return 1
    print(f"全部通过 · 测试用户 {username} / {second_name}（私有书 {book_id}，曲目 {track_id}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
