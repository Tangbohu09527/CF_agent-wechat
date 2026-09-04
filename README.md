# CF_agent-wechat

`CF_agent-wechat` 是企业 AI 自动化链路中的微信入口服务：

```text
WeChat Linux client
  -> agent-server HTTP API
  -> CF_agent-gateway
  -> Hermes
```

本仓库负责 `agent-wechat` 容器部署边界、forced fresh QR 生命周期、WeChat
进程与认证/API 就绪验证、Runtime/Archive、Token 挂载，以及通过 Gateway Runtime
Contract version 1 协调 Poll/Delivery Worker。Gateway 内部消息模型、AI 权限、Hermes、
Skills、ERP、RAG、OCR 和文件理解不属于本仓库。

> [!IMPORTANT]
> forced-QR R2 已于 2026-09-03 完成真实 CFserver 验收，当前生产在线。Repository
> branch authority 为 `main`。Repository promotion 已于 2026-09-04 完成：PR #5、
> PR #4、PR #1 均已合并；PR #1 promotion merge baseline 为
> `02583fe76220916019ca961bb37dfa015640384e`，其 baseline CI Run
> `33853255941` 成功。Live `main` tip 有意不硬编码，必须通过 GitHub 或
> `git rev-parse origin/main` 动态查询。
> 仓库合并没有连接或修改 CFserver，也没有重新构建或发布生产镜像；不得把
> `02583fe...` 写成已经重新部署。
> 当前事实只以 [生产状态](docs/production-status.md) 为准。

## 核心决策

- 每次 CFserver 重启、`agent-wechat` 容器重建、人工重新启动或 Runtime 轮换，都必须
  创建全新 Runtime，并在交互式 SSH TTY 扫描新的二维码。
- 旧 Runtime 只移动到 `session-archive/<UTC timestamp>`，不得恢复为 active Session。
- 生产 Compose 使用 `restart: "no"`；主机重启后 `cf-agent-wechat` 保持停止。
- 真实重启验收中 Gateway Poll/Delivery Worker 曾自动恢复。因此重启后不能假设 Gate
  已关闭，fresh QR 前必须通过正式 Controller 显式 `stop` 并确认。
- Gateway-only 部署若不重启或删除 `cf-agent-wechat`，已观察到微信 Session 保持；
  该结论不能外推为 `agent-wechat` 自身重启可复用 Session。

## 生产入口

```text
Bootstrap   sudo ./scripts/bootstrap-cfserver.sh   # 只准备，不上线
Fresh QR    ./scripts/start-qr-login.sh            # 唯一生产启动
Stop        ./scripts/stop-qr-runtime.sh           # 停 Worker 和 Agent，保留数据
Status      ./scripts/status.sh                    # 只读完整状态判定
Compat      ./scripts/login.sh                     # 仅转入 start-qr-login.sh
```

不要用 `docker compose up`、`docker compose restart`、`docker compose down`、
`docker restart cf-agent-wechat`、手工启动 Gateway Worker 或恢复 Archive 替代这些入口。

## 生产边界

- 项目根：`/opt/cf-agent-wechat`
- Compose：`/opt/cf-agent-wechat/docker/compose.cfserver.yaml`
- 环境文件：`/opt/cf-agent-wechat/docker/.env`
- 容器/Compose project：`cf-agent-wechat`
- API：容器端口 `6174`，宿主仅 loopback，容器网络为外部 `cf-internal`
- Runtime：`/srv/storage/cf-agent-wechat/runtime`
- Archive：`/srv/storage/cf-agent-wechat/session-archive/<UTC timestamp>`
- Token：`/srv/storage/cf-agent-wechat/secrets/auth-token`，只读挂载到
  `/data/auth-token`
- Gateway Controller：`/opt/cf-agent-gateway/deploy/wechat-runtime-control`

Docker health 只证明 Agent API `/health` 可达，不证明 WeChat 已登录、真实进程稳定、
chats/messages 可读或 Gateway 已放行。生产在线必须以 `./scripts/status.sh` 的全部
11 个状态项和退出码为准。

## 状态口径

| 状态 | 当前使用方式 |
| --- | --- |
| **已完成** | forced-QR R2 已进入 Repository branch authority `main`；live tip 动态查询 |
| **已验证（自动化）** | PR #1 promotion baseline CI Run `33853255941` 成功，五项 Job 全部通过 |
| **已验证（CFserver 行为）** | 2026-09-03 的脱敏记录证明 forced fresh QR 生产行为 |
| **未证明** | 选定 Release Commit、构建输入与现场 Image ID 的精确映射、automatic boot stop gate |
| **Repository promotion** | **COMPLETED**；仓库合并不表示生产重新部署 |
## 当前限制

- CFserver 重启后必须人工 fresh QR；automatic Gateway boot stop gate 尚未证明。
- 离线或重启窗口内的消息可能无法由本地微信客户端补拉。
- Archive 是受限敏感资产，保留期、容量、备份与安全销毁由外部运维策略负责。
- 上游 `agent-wechat` API/schema 可能变化；镜像升级必须重新验证。
- `seccomp=unconfined` 与 `SYS_PTRACE` 是当前上游要求，需持续审查。
- 现场 Docker Image ID 与选定 Release Commit、构建输入的精确映射尚无完整证据。

## 文档

- [文档索引](docs/README.md)
- [当前生产状态](docs/production-status.md)
- [CFserver 生产 Runbook](docs/deployment/cfserver-production.md)
- [forced-QR R2 生产验收记录](docs/validation/2026-09-03-forced-qr-r2-production.md)
- [API 边界](docs/api.md)
- [恢复指南](docs/recovery-guide.md)
