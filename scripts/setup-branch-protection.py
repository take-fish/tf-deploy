#!/usr/bin/env python3
"""FishMatrix GitHub 仓库治理脚本：转 public + 配置 master 分支保护 + 仓库合并设置。

用法：
    python scripts/setup-branch-protection.py                 # 处理全部 10 个仓库
    python scripts/setup-branch-protection.py tf-gateway      # 只处理指定仓库
    DRY_RUN=1 python scripts/setup-branch-protection.py       # 只打印将要做的修改
    PUBLICIZE=0 python scripts/setup-branch-protection.py     # 跳过"转 public"步骤

PAT 要求（二选一）：
    - fine-grained token：Administration: Read and write + Contents: Read and write（限定 10 个仓库）
    - classic token：repo 范围

PAT 提供方式（任选其一）：
    - 环境变量：GH_PAT=xxx
    - 文件：~/.fishmatrix-pat（脚本自动读取，避免 PAT 出现在命令行历史里）

前置条件：
    master 分支上 CI 的 check（job 名 build）至少成功运行过一次，
    否则无法把它设为 required status check（配置会指向一个永不满足的检查）。
"""
import json
import os
import sys
import urllib.error
import urllib.request

OWNER = os.environ.get("OWNER", "take-fish")
BRANCH = os.environ.get("BRANCH", "master")
DRY_RUN = os.environ.get("DRY_RUN") == "1"
PUBLICIZE = os.environ.get("PUBLICIZE", "1") == "1"
API = "https://api.github.com"
GRAPHQL = "https://api.github.com/graphql"
ACTIONS_APP_ID = 15368  # GitHub Actions 的 app_id，锁定 required check 必须来自 Actions

REPOS = [
    "tf-gateway", "tf-edge-node",
    "tf-user", "tf-chat", "tf-reader", "tf-game", "tf-music",
    "tf-agent", "tf-web", "tf-deploy",
]
# tf-deploy 例外：允许管理员绕过保护直推 master（供各仓发版后自动 bump submodule 指针）
ENFORCE_ADMINS_EXCEPTIONS = {"tf-deploy"}


def get_pat() -> str:
    pat = os.environ.get("GH_PAT", "").strip()
    if pat:
        return pat
    path = os.path.join(os.path.expanduser("~"), ".fishmatrix-pat")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    sys.exit("错误：未找到 PAT。请设置 GH_PAT 环境变量，或把 PAT 写入 ~/.fishmatrix-pat")


PAT = get_pat()


def request(method: str, path: str, payload=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {PAT}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode()
            return resp.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, {"message": body}


def setup_repo(repo: str) -> bool:
    print(f"── {repo}")
    status, info = request("GET", f"/repos/{OWNER}/{repo}")
    if status == 404:
        print("   ✗ 仓库不存在，或 PAT 无权限访问")
        return False
    if status != 200:
        print(f"   ✗ 查询失败 HTTP {status}: {info.get('message')}")
        return False

    # 0. 转 public（GitHub Free 的私有仓库不支持分支保护）
    if info.get("private"):
        if not PUBLICIZE:
            print("   - 仓库仍为 private（PUBLICIZE=0 已跳过，注意私有仓无法配置分支保护）")
        elif DRY_RUN:
            print("   [dry-run] 将转为 public")
        else:
            st, resp = request("PATCH", f"/repos/{OWNER}/{repo}", {"private": False})
            if st != 200:
                print(f"   ✗ 转 public 失败 HTTP {st}: {resp.get('message')}")
                return False
            print("   ✓ 已转为 public")

    # 1. 校正默认分支
    if info.get("default_branch") != BRANCH:
        if DRY_RUN:
            print(f"   [dry-run] 默认分支 {info.get('default_branch')} → {BRANCH}")
        else:
            st, resp = request("PATCH", f"/repos/{OWNER}/{repo}", {"default_branch": BRANCH})
            if st != 200:
                print(f"   ✗ 修改默认分支失败 HTTP {st}: {resp.get('message')}")
                return False
            print(f"   ✓ 默认分支已改为 {BRANCH}")

    # 2. 发现 master 上真实存在的 check 名（不能凭空写，否则 PR 会永久 pending）
    st, runs = request("GET", f"/repos/{OWNER}/{repo}/commits/{BRANCH}/check-runs?per_page=100")
    if st != 200:
        print(f"   ✗ 查询 check-runs 失败 HTTP {st}: {runs.get('message')}")
        return False
    names = sorted({
        c["name"] for c in runs.get("check_runs", [])
        if (c.get("app") or {}).get("slug") == "github-actions"
    })
    if not names:
        print(f"   ✗ {BRANCH} 上还没有 GitHub Actions 的 check —— 请先让 CI 在该分支跑过一次再执行本脚本")
        return False
    print(f"   发现 check：{', '.join(names)}")

    # 3. 配置分支保护（REST 不接受 0 个 approve，PR 要求部分用 GraphQL 兜底）
    payload = {
        "required_status_checks": {
            "strict": True,
            "checks": [{"context": n, "app_id": ACTIONS_APP_ID} for n in names],
        },
        "enforce_admins": repo not in ENFORCE_ADMINS_EXCEPTIONS,
        "restrictions": None,
        "allow_force_pushes": False,
        "allow_deletions": False,
    }
    if DRY_RUN:
        print("   [dry-run] 保护 payload：", json.dumps(payload, ensure_ascii=False))
    else:
        st, resp = request("PUT", f"/repos/{OWNER}/{repo}/branches/{BRANCH}/protection", payload)
        if st != 200:
            msg = json.dumps(resp, ensure_ascii=False)
            if "Upgrade to GitHub Pro" in msg:
                print("   ✗ 403：GitHub Free 的私有仓库不支持分支保护，请先转 public 或升级 Pro")
            else:
                print(f"   ✗ 保护配置失败 HTTP {st}: {msg}")
            return False
        print("   ✓ 基础保护已配置（required checks / 禁强推 / 禁删除）")

        # "必须走 PR、0 个 approve" —— REST 传 0 会 422，用 GraphQL 表达
        node_id = info.get("node_id")
        query = (
            'mutation { updateBranchProtectionRule(input: { repositoryId: "%s", pattern: "%s",'
            " requiresApprovingReviews: true, requiredApprovingReviewCount: 0 }) { clientMutationId } }"
            % (node_id, BRANCH)
        )
        st, resp = request("POST", GRAPHQL, {"query": query})
        if st == 200 and not resp.get("errors"):
            print("   ✓ 已要求必须通过 PR 合并（0 个 approve）")
        else:
            print(f"   ✗ 设置 PR 门禁失败：{json.dumps(resp, ensure_ascii=False)[:300]}")
            return False

    # 4. 合并方式：仅 squash、合并后自动删分支
    merge_payload = {
        "allow_squash_merge": True,
        "allow_merge_commit": False,
        "allow_rebase_merge": False,
        "delete_branch_on_merge": True,
    }
    if DRY_RUN:
        print("   [dry-run] 合并设置：", json.dumps(merge_payload))
    else:
        st, resp = request("PATCH", f"/repos/{OWNER}/{repo}", merge_payload)
        if st == 200:
            print("   ✓ 合并方式已设为 squash-only，合并后自动删分支")
        else:
            print(f"   ⚠ 合并设置更新失败 HTTP {st}: {resp.get('message')}")

    # 5. 回读验证
    if not DRY_RUN:
        st, prot = request("GET", f"/repos/{OWNER}/{repo}/branches/{BRANCH}/protection")
        if st != 200:
            print(f"   ✗ 回读保护配置失败 HTTP {st}")
            return False
        rsc = prot.get("required_status_checks") or {}
        contexts = [c.get("context") for c in (rsc.get("checks") or [])] or (rsc.get("contexts") or [])
        print(
            "   保护验证："
            f"checks={contexts}, strict={rsc.get('strict')}, "
            f"enforce_admins={(prot.get('enforce_admins') or {}).get('enabled')}, "
            f"force_push={(prot.get('allow_force_pushes') or {}).get('enabled')}, "
            f"deletions={(prot.get('allow_deletions') or {}).get('enabled')}, "
            f"pr_required={'required_pull_request_reviews' in prot}"
        )
    return True


def main() -> None:
    targets = sys.argv[1:] or REPOS
    print(f"目标仓库（{OWNER}）：{' '.join(targets)}"
          + ("  [DRY-RUN]" if DRY_RUN else ""))
    ok, fail = [], []
    for repo in targets:
        (ok if setup_repo(repo) else fail).append(repo)
    print("\n===== 汇总 =====")
    print(f"成功 {len(ok)}：{' '.join(ok) or '-'}")
    print(f"失败 {len(fail)}：{' '.join(fail) or '-'}")
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
