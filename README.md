# tf-deploy

FishMatrix（摸鱼矩阵）部署编排与聚合壳仓库。

- **集中机编排**：`docker-compose.yml` 一键拉起网关 + MySQL / Redis / Elasticsearch / Nacos
- **自动更新**：`scripts/auto-update.sh` + systemd 定时器，集中机轮询 ghcr 自动重建应用服务（见 `docs/自动更新说明.md`）
- **大仓聚合壳**：git submodule 挂载 9 个服务仓库，便于统一浏览（不做统一构建）
- **仓库治理脚本**：`scripts/setup-branch-protection.py` 批量配置分支保护
- **CI 模板**：`docs/ci-templates/` 各技术栈的 CI / 发版工作流模板

## 集中机一键拉起

```bash
cp .env.example .env        # 可选：修改端口与密码
docker compose up -d        # 拉起全部服务
docker compose ps           # 查看状态
```

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
python scripts/setup-branch-protection.py # 配置 10 仓分支保护（需 PAT）
```
