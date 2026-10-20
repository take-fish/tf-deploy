# Nacos 配置（group=FM）

每个服务一个 dataId（`tf-user.yaml` / `tf-chat.yaml` / `tf-reader.yaml` / `tf-game.yaml` / `tf-music.yaml`），
生产与测试通过 **namespace** 隔离：

| 环境 | namespace | 数据源 | Redis |
|---|---|---|---|
| 生产 | `fm-prod` | `fm_*` | DB0 |
| 测试 | `fm-test` | `fm_test_*` | DB1 |

- `prod/`、`test/` 下是配置模板，由 `scripts/init-nacos.sh` 幂等发布
- 敏感信息（MySQL 密码）用 `${MYSQL_APP_PASSWORD}` 占位，由容器环境变量注入，不落 Nacos
- 服务端启动配置（Nacos 地址、namespace、账号密码）仍由 compose 环境变量提供，因为必须先连上 Nacos
- 修改模板后重跑 `bash scripts/init-nacos.sh` 即可覆盖；Nacos 控制台也支持在线编辑

## 服务端如何加载

- compose 注入 `SPRING_PROFILES_ACTIVE=nacos` 后加载 `application-nacos.yml`：
  `spring.config.import: optional:nacos:${spring.application.name}.yaml?group=FM&refreshEnabled=true`
- 本地运行与单元测试不激活该 profile，不依赖 Nacos
- 配置缺失时使用 `application.yml` 中的环境变量默认值（`optional:`），不会阻塞启动
