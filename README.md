# tf-deploy

FishMatrix（摸鱼矩阵）部署编排与聚合壳仓库。

- **集中机编排**：`docker-compose.yml` 拉起网关 + Web 前端 + 流水线控制台 + MySQL / Redis / Elasticsearch / Nacos
- **业务服务编排**：`docker-compose.services.yml` 拉起 user / chat / reader / game / music（与公共层共用 network）
- **测试环境编排**：`docker-compose.test.yml` 复用共享中间件，通过 `fm_test_*` / Redis DB1 / Nacos `fm-test` 逻辑隔离（见 `docs/测试环境说明.md`）
- **Nacos 配置**：`deploy/nacos/{prod,test}/tf-*.yaml` + `scripts/init-nacos.sh` 集中管理数据源、Redis 与业务参数
- **数据库初始化**：`scripts/init-db.sh` 幂等创建生产/测试业务库与 `fm_app` 授权
- **自动更新**：`scripts/auto-update.sh`（生产 `:latest`）与 `scripts/auto-update-test.sh`（测试 `:test`），集中机轮询 ghcr 自动重建（见 `docs/自动更新说明.md`）
- **大仓聚合壳**：git submodule 挂载 10 个服务仓库，便于统一浏览（不做统一构建）
- **仓库治理脚本**：`scripts/setup-branch-protection.py` 批量配置分支保护
- **CI 模板**：`docs/ci-templates/` 各技术栈的 CI / 发版工作流模板

## 集中机一键拉起

```bash
cp .env.example .env        # 可选：修改端口与密码
docker compose up -d        # 拉起中间件 + gateway + console + web
bash scripts/init-db.sh     # 创建 fm_* / fm_test_* 数据库与 fm_app 授权（首次/密码变更时）
bash scripts/init-nacos.sh  # 创建 fm-prod / fm-test 命名空间并发布 FM group 配置
docker compose -f docker-compose.yml -f docker-compose.services.yml up -d   # 再拉起 5 个业务服务
docker compose -f docker-compose.yml -f docker-compose.services.yml ps      # 查看全栈状态

# 测试环境（push test 构建 :test 镜像后）
docker compose -f docker-compose.test.yml up -d
bash scripts/auto-update-test.sh
```
```

访问入口：

| 入口 | 地址 |
|---|---|
| Web 前端 | `http://localhost:8088` |
| 统一网关 | `http://localhost:8080` |
| 流水线控制台 | `http://localhost:8301` |
| Nacos 控制台 | `http://localhost:8848/nacos` |

拉取私有镜像（首次）：

```bash
echo "<你的 PAT>" | docker login ghcr.io -u <github用户名> --password-stdin
```

安装自动更新定时器（可选，合 master 后自动拉新镜像并重建）：

```bash
sudo docker login ghcr.io        # 定时器以 root 运行，凭据需登录在 root 下
sudo bash scripts/install-auto-update.sh
```

## 分支模型

- `master`：保护分支，只接受 PR（CI 必须通过）；例外：允许管理员直推（供各仓发版后自动 bump submodule 指针）
- `test`：联调分支，可直接推送
- 详见 `docs/分支策略与CI说明.md`

## 常用命令

```bash
git submodule update --init --recursive   # 初始化全部子仓
git submodule foreach 'git checkout master && git pull'   # 批量更新子仓
python scripts/setup-branch-protection.py # 配置 11 仓分支保护（需 PAT）
bash scripts/init-db.sh                   # 幂等初始化数据库与授权
bash scripts/init-nacos.sh                # 幂等创建命名空间并发布配置
bash scripts/auto-update.sh               # 手动跑一轮生产镜像更新
bash scripts/auto-update-test.sh          # 手动跑一轮测试镜像更新
```
