#!/usr/bin/env python3
"""FishMatrix GitHub 仓库治理脚本：转 public + 配置 master 分支保护 + 仓库合并设置。

用法：
    python scripts/setup-branch-protection.py                 # 处理全部 11 个仓库
    python scripts/setup-branch-protection.py tf-gateway      # 只处理指定仓库
    DRY_RUN=1 python scripts/setup-branch-protection.py       # 只打印将要做的修改
    PUBLICIZE=0 python scripts/setup-branch-protection.py     # 跳过"转 public"步骤

PAT 要求（二选一）：
    - fine-grained token：Administration: Read and write + Contents: Read and write（限定 11 个仓库）
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

# Windows 控制台默认 GBK，强制 UTF-8 输出（含中文与符号），避免打印崩溃
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

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
    "tf-agent", "tf-web", "tf-console", "tf-deploy",
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

# Windows 上 urllib 默认会读取系统代理设置（如 Clash 未运行时请求会一直挂起），
# 这里显式禁用代理，走直连（git/curl 均能直连访问 GitHub）。
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


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
        with OPENER.open(req, timeout=30) as resp:
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

    # 2. 确定 required check 名单：以约定为准（默认 build），接口发现仅作校验。
    #    注意：不能把发现到的全部 check 都设为必过 —— 例如 release 只在 master 上运行，
    #    若设为必过，PR 上永远不会上报，会永久卡住合并。
    names = [n.strip() for n in os.environ.get("REQUIRED_CHECKS", "build").split(",") if n.strip()]
    st, runs = request("GET", f"/repos/{OWNER}/{repo}/commits/{BRANCH}/check-runs?per_page=100")
    if st == 200:
        discovered = sorted({
            c["name"] for c in runs.get("check_runs", [])
            if (c.get("app") or {}).get("slug") == "github-actions"
        })
        missing = [n for n in names if n not in discovered]
        if missing:
            print(f"   ✗ {BRANCH} 上未发现约定的 check：{', '.join(missing)}"
                  f"（现有：{', '.join(discovered) or '无'}）—— 请先让 CI 在该分支跑过一次")
            return False
        others = [n for n in discovered if n not in names]
        print(f"   ✓ 已确认必过 check：{', '.join(names)}"
              + (f"（忽略：{', '.join(others)}）" if others else ""))
    else:
        # PAT 可能缺少 Checks 读取权限；按约定直接使用
        print(f"   ⚠ 无法读取 check 列表（HTTP {st}: {runs.get('message')}），按约定使用：{', '.join(names)}")

    # 3. 配置分支保护。目标形态："必须走 PR、0 个 approve"。
    #    REST 的 required_pull_request_reviews 字段必须显式提供；若 REST 不接受 0，
    #    先用 1 建立规则，再用 GraphQL 把 approve 数降为 0。
    def protection_payload(review_count):
        return {
            "required_status_checks": {
                "strict": True,
                "checks": [{"context": n, "app_id": ACTIONS_APP_ID} for n in names],
            },
            "enforce_admins": repo not in ENFORCE_ADMINS_EXCEPTIONS,
            "required_pull_request_reviews": {
                "dismiss_stale_reviews": False,
                "require_code_owner_reviews": False,
                "required_approving_review_count": review_count,
            },
            "restrictions": None,
            "allow_force_pushes": False,
            "allow_deletions": False,
        }

    def set_approvals_to_zero():
        """GraphQL 把 approve 数设为 0（REST 不接受 0 时的兜底）。"""
        node_id = info.get("node_id")
        query = (
            'mutation { updateBranchProtectionRule(input: { repositoryId: "%s", pattern: "%s",'
            " requiresApprovingReviews: true, requiredApprovingReviewCount: 0 }) { clientMutationId } }"
            % (node_id, BRANCH)
        )
        st2, resp2 = request("POST", GRAPHQL, {"query": query})
        if st2 == 200 and not resp2.get("errors"):
            print("   ✓ 已要求必须通过 PR 合并（0 个 approve，GraphQL 设置）")
            return True
        print(f"   ✗ 设置 PR 门禁为 0 approve 失败：{json.dumps(resp2, ensure_ascii=False)[:300]}")
        return False

    if DRY_RUN:
        print("   [dry-run] 保护 payload：", json.dumps(protection_payload(0), ensure_ascii=False))
    else:
        st, resp = request("PUT", f"/repos/{OWNER}/{repo}/branches/{BRANCH}/protection",
                           protection_payload(0))
        if st == 200:
            print("   ✓ 分支保护已配置（必走 PR、0 approve、build 必过、禁强推/禁删除）")
        elif st == 422:
            # REST 不接受 0 个 approve：先以 1 建立规则，再降为 0
            st, resp = request("PUT", f"/repos/{OWNER}/{repo}/branches/{BRANCH}/protection",
                               protection_payload(1))
            if st != 200:
                print(f"   ✗ 保护配置失败 HTTP {st}: {json.dumps(resp, ensure_ascii=False)[:300]}")
                return False
            print("   · REST 不接受 0 个 approve，改用 GraphQL 兜底…")
            if not set_approvals_to_zero():
                return False
        else:
            msg = json.dumps(resp, ensure_ascii=False)
            if "Repository has been locked" in msg:
                print("   ✗ 仓库刚转 public，GitHub 短暂锁定中（通常几分钟内解除）—— 稍后重跑本脚本即可")
            elif "Upgrade to GitHub Pro" in msg:
                print("   ✗ 403：GitHub Free 的私有仓库不支持分支保护，请先转 public 或升级 Pro")
            else:
                print(f"   ✗ 保护配置失败 HTTP {st}: {msg}")
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
        rpr = prot.get("required_pull_request_reviews") or {}
        print(
            "   保护验证："
            f"checks={contexts}, strict={rsc.get('strict')}, "
            f"enforce_admins={(prot.get('enforce_admins') or {}).get('enabled')}, "
            f"force_push={(prot.get('allow_force_pushes') or {}).get('enabled')}, "
            f"deletions={(prot.get('allow_deletions') or {}).get('enabled')}, "
            f"pr_required={bool(rpr)}, approvals_required={rpr.get('required_approving_review_count')}"
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
