# tf-deploy

FishMatrix（摸鱼矩阵）部署编排与聚合壳仓库。

- **中间件编排**：`docker-compose.middleware.yml` 单独拉起 MySQL / Redis / Elasticsearch / Nacos，生产与测试共用一套中间件地址
- **集中机编排**：`docker-compose.yml` 拉起网关 + Web 前端 + 流水线控制台
- **业务服务编排**：`docker-compose.services.yml` 拉起 user / chat / reader / game / music（与公共层共用 network）
- **测试环境编排**：`docker-compose.test.yml` 只拉起测试应用，连接共享中间件的 `fm_test_*` 库 / Redis DB1 / Nacos `fm-test`（见 `docs/测试环境说明.md`）
- **Nacos 配置**：`deploy/nacos/{prod,test}/tf-*.yaml` + `scripts/init-nacos.sh` 集中管理数据源、Redis 与业务参数
- **数据库初始化**：`scripts/init-db.sh` 幂等创建生产业务库与 `fm_app` 授权；`scripts/init-test-db.sh` 在同一个 `fm-mysql` 中创建 `fm_test_*` 库与 `fm_test_app` 授权
- **登录与用户中台**：`tf-user` 负责账号、审批与会话（Redis）；前端入口强制登录，管理员在用户中台审批新用户
- **管理员密码**：`scripts/ensure-user-admin-secrets.sh` 为生产/测试分别生成到 `.env`（不落库、不打印）
- **自动更新**：`scripts/auto-update.sh`（生产 `:latest`）与 `scripts/auto-update-test.sh`（测试 `:test`），集中机轮询 ghcr 自动重建（见 `docs/自动更新说明.md`）
- **日志与链路追踪**：网关生成 trace_id，Java 服务输出 JSON 日志，Alloy 采集 Docker stdout 写入 Loki；流水线中台 `/logs` 与 `scripts/trace.sh` 按编号检索（见 `docs/日志与链路追踪.md`）
- **大仓聚合壳**：git submodule 挂载 10 个服务仓库，便于统一浏览（不做统一构建）
- **仓库治理脚本**：`scripts/setup-branch-protection.py` 批量配置分支保护
- **CI 模板**：`docs/ci-templates/` 各技术栈的 CI / 发版工作流模板

## 集中机一键拉起

```bash
cp .env.example .env        # 可选：修改端口与密码
bash scripts/ensure-user-admin-secrets.sh  # 生成用户中台管理员密码到 .env（幂等）
bash scripts/ensure-test-secrets.sh        # 生成测试 MySQL 账号密码到 .env（幂等）
bash scripts/ensure-observability-secrets.sh  # 生成日志检索口令与 Grafana 管理员密码（幂等）

# 1) 共享中间件（只有这一套）
docker compose -f docker-compose.middleware.yml up -d mysql redis nacos

# 1.1) 日志与可观测性（可选，但日志检索依赖它）
docker compose -f docker-compose.middleware.yml up -d loki alloy grafana

# 2) 数据库与 Nacos
bash scripts/init-db.sh       # 生产 fm_* 库与 fm_app 授权
bash scripts/init-test-db.sh  # 测试 fm_test_* 库与 fm_test_app 授权
bash scripts/init-nacos.sh    # 创建 fm-prod / fm-test 命名空间并发布 FM group 配置

# 3) 生产应用
docker compose -f docker-compose.yml -f docker-compose.services.yml up -d
docker compose -f docker-compose.yml -f docker-compose.services.yml ps

# 4) 测试应用（push test 构建 :test 镜像后）
docker compose -f docker-compose.test.yml up -d
docker compose -f docker-compose.test.yml ps -a
bash scripts/auto-update-test.sh
```

访问入口：

| 入口 | 地址 |
|---|---|
| Web 前端（需登录） | `http://localhost:8088` |
| 统一网关 | `http://localhost:8080` |
| 用户中台 | `http://localhost:8101/admin/` 或 `http://localhost:8088/api/v1/user/admin/index.html` |
| 流水线控制台（含日志检索 `/logs`） | `http://localhost:8301` |
| Nacos 控制台 | `http://localhost:8848/nacos` |
| Grafana（仅宿主机回环） | `http://127.0.0.1:13000` |
| Loki API（仅宿主机回环） | `http://127.0.0.1:13100` |

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
docker compose -f docker-compose.middleware.yml up -d mysql redis nacos   # 单独启动/更新共享中间件（ES 未启用）
bash scripts/init-db.sh                   # 幂等初始化生产数据库与授权
bash scripts/init-test-db.sh              # 幂等初始化测试数据库与授权
bash scripts/init-nacos.sh                # 幂等创建命名空间并发布生产/测试配置
bash scripts/auto-update.sh               # 手动跑一轮生产镜像更新
bash scripts/auto-update-test.sh          # 手动跑一轮测试镜像更新
bash scripts/trace.sh <编号>               # 按链路编号查询集中日志
docker compose -f docker-compose.middleware.yml up -d loki alloy grafana   # 更新日志组件
```
