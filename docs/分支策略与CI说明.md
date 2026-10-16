# 分支策略与 CI 说明

## 分支模型

```
feature/xxx ──直接合入（不走 PR）──▶ test（联调环境，可直接 push）
     │
     └────PR（build 必过）────▶ master（发布线：保护）──自动发版──▶ tag vX.Y.Z + Release + ghcr 镜像
```

**开发流**：`feature/*` 开发完成 → 直接合入 `test` 联调（不走 PR）→ 验证 OK 后，从**开发分支**开 PR 合 `master`（不从 test 提 PR）→ 合并后自动发版。

| 分支 | 角色 | 保护规则 |
|------|------|----------|
| `master` | 默认分支、发布线 | 禁止直接 push；必须通过 PR 合并（PR 来源为 `feature/*`）；PR 的 `build` 检查必须通过；禁止强推/删除；合并方式仅 squash；合并后自动删源分支 |
| `test` | 联调分支 | 无保护；开发分支直接合入（不走 PR）；可直接 push（CI 仍会运行） |
| `feature/*` | 开发分支 | 无（push 不触发 CI，开 PR 时才跑，节省用量） |

**例外**：`tf-deploy` 的 master 允许管理员直推（`enforce_admins=false`），供各服务仓发版后自动 bump submodule 指针。

## CI 触发规则（10 个仓库统一）

| 事件 | 是否触发 CI |
|------|-------------|
| push 到 `test` / `master` | ✅ |
| 向 `test` / `master` 开 PR（含更新） | ✅ |
| push 到 `feature/*` 等其他分支 | ❌（开 PR 即触发） |
| push tag | ❌（发版由 release 工作流完成） |

- job 名统一为 **`build`**：分支保护里的 required check 就是它。将来拆分更多 job 时，请保留一个同名聚合 job，否则保护会失效。
- 所有工作流固定 `runs-on: ubuntu-24.04`（避免 `ubuntu-latest` 镜像迁移期波动）。

## 发版流程（9 个代码仓，tf-deploy 除外）

合并到 `master` → 自动触发 Release 工作流：

1. 取最近一个 tag，patch 自增（首个版本为 `v0.1.0`）
2. 构建产物并推送 `ghcr.io/take-fish/<仓库>:<版本>` 与 `:latest`
3. 创建 Release 与 tag，附上产物
4. （可选）配置了 `TF_DEPLOY_PAT` secret 的仓库，会把 `tf-deploy` 中自己的 submodule 指针 bump 到新版本

| 仓库 | Release 附件 | Docker 镜像 |
|------|-------------|-------------|
| tf-gateway / tf-edge-node | linux/amd64、linux/arm64、windows/amd64 裸二进制 + SHA256SUMS | ✅ linux/amd64 |
| tf-user / tf-chat / tf-reader / tf-game / tf-music | `<仓库>-vX.Y.Z.jar` + SHA256SUMS | ✅ |
| tf-agent | 无（仅 Release 说明） | ✅ |
| tf-web | `<仓库>-vX.Y.Z-dist.tar.gz` + SHA256SUMS | 无 |

需要发布给成员机器时，`tf-edge-node` 的 Windows 二进制可直接下载分发。

## 分支保护配置（一次性）

```bash
# 1. 创建 PAT（二选一）：
#    - fine-grained：Administration: RW + Contents: RW，限定 take-fish 的 10 个仓库
#    - classic：勾选 repo
# 2. 把 PAT 写入 ~/.fishmatrix-pat（或设 GH_PAT 环境变量）
# 3. 确认 master 上 CI 已跑过一次（必须有 build check），然后执行：
python scripts/setup-branch-protection.py            # 全量
python scripts/setup-branch-protection.py tf-web     # 单仓
DRY_RUN=1 python scripts/setup-branch-protection.py  # 只预览
```

脚本会：转 public（GitHub Free 私有仓不支持保护）→ 校正默认分支为 master → 校验约定的必过 check（默认 `build`，可用 `REQUIRED_CHECKS` 环境变量覆盖；接口读到 `release` 等只在 master 上运行的 check 会刻意忽略，否则 PR 会被永久卡住）→ 配置保护 → 设置 squash-only 合并 → 回读验证。

## 拉取私有镜像 / 制品

```bash
echo "<PAT>" | docker login ghcr.io -u <用户名> --password-stdin   # PAT 需 read:packages
```

## 常见问题

- **PR 一直显示 "Expected — waiting for status"**：保护里配置的 check 名与实际 job 名不一致。跑一次 `setup-branch-protection.py` 回读检查，或确认工作流 job 的 `name:` 仍是 `build`。
- **发版没有 bump tf-deploy**：仓库未配置 `TF_DEPLOY_PAT` secret，属预期行为（首次可不配，Release 本身不受影响）。
- **CI 不触发**：确认目标分支是 `test`/`master`（feature 分支 push 不触发是设计如此）。
- **ghcr 拉取慢**：国内网络问题，可后续换成阿里云 ACR（改各仓 release.yml 的 `IMAGE` 与登录步骤即可）。
