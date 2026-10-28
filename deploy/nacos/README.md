# Nacos 配置（group=FM）

每个服务一个 dataId（`tf-user.yaml` / `tf-chat.yaml` / `tf-reader.yaml` / `tf-game.yaml` / `tf-music.yaml`），
生产与测试通过 **namespace** 隔离：

| 环境 | namespace | 数据源 | Redis |
|---|---|---|---|
| 生产 | `fm-prod` | `fm_*` | DB0 |
| 测试 | `fm-test` | `fm_test_*` | DB1 |

- `prod/` 由 `scripts/init-nacos.sh` 幂等发布，`test/` 由 `scripts/init-test-nacos.sh` 幂等发布
- 敏感信息（MySQL 密码）用 `${MYSQL_APP_PASSWORD}` 占位，由容器环境变量注入，不落 Nacos
- 服务端启动配置（Nacos 地址、namespace、账号密码）仍由 compose 环境变量提供，因为必须先连上 Nacos
- 修改模板后重跑对应环境的脚本即可覆盖；Nacos 控制台也支持在线编辑

## RocketMQ

`fm.messaging` 的 broker 地址、topic 前缀、producer group、超时与诊断开关**全部写在本目录模板**，
不使用 compose 环境变量。生产/测试共用一个 broker，靠前缀隔离：

| 环境 | topic 前缀 | producer group | 启用状态 |
|---|---|---|---|
| 生产 `prod/` | `FM_` | `fm-<service>` | 默认 `false`，启用需单独确认 |
| 测试 `test/` | `FM_TEST_` | `fm-test-<service>` | 仅 `tf-game.yaml` 为 `true` |

- 只有使用 `tf-common >= 1.2.0` 的服务会识别这些属性；未升级的服务读到也不会连接。
- `enabled=true` 时服务启动即创建生产者，broker 不可达会导致启动失败；先确认 `fm-rocketmq-broker` 已运行。
- `diagnostics-on-startup=true` 会发布一条 `SYSTEM_PROBE` 事件，topic 为 `<前缀>SYSTEM_PROBE`，需先用
  `bash scripts/init-rocketmq.sh test` 预建。
- 回滚：把对应服务模板的 `enabled` 改回 `false`，重跑发布脚本并重启服务。

## 服务端如何加载

- compose 注入 `SPRING_PROFILES_ACTIVE=nacos` 后加载 `application-nacos.yml`：
  `spring.config.import: optional:nacos:${spring.application.name}.yaml?group=FM&refreshEnabled=true`
- 本地运行与单元测试不激活该 profile，不依赖 Nacos
- 配置缺失时使用 `application.yml` 中的环境变量默认值（`optional:`），不会阻塞启动
