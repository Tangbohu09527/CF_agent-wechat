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
> 状态核对日期：2026-10-11。`production online` 是 **2026-09-03 历史验收结果**，
> 不代表今天实时在线。用户报告在 Gateway d9 新 plan 通过后执行了 CFserver reboot；
> 重启后的微信容器、登录、API 和 Poll/Delivery Gate **均未复验**。
> 本次远端 `main` 为 `81d21f451adc61df71077ca3035adeddeca4621f`，包含已合并 PR #7；
> 媒体候选分支 `codex/fix-wechat-original-media` 固定为
> `9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a`，未合并，未证明现场已升级。
> 本页所在文档分支基于该候选，只更新文档。能力、来源和待验收项以
> [生产状态](docs/production-status.md)为准；仓库/CI 成功不证明部署或真实取件。

## 核心决策

- 每次 CFserver 重启、`agent-wechat` 容器重建、人工重新启动或 Runtime 轮换，都必须
  创建全新 Runtime，并在交互式 SSH TTY 扫描新的二维码。
- 旧 Runtime 只移动到 `session-archive/<UTC timestamp>`，不得恢复为 active Session。
- 生产 Compose 使用 `restart: "no"`；2026-09-01 重启曾观察到 Agent 保持停止，
  2026-10-11 重启后的实际容器状态仍待复验。
- 真实重启验收中 Gateway Poll/Delivery Worker 曾自动恢复。因此重启后不能假设 Gate
  已关闭，fresh QR 前必须通过正式 Controller 显式 `stop` 并确认。
- Gateway-only 部署若不重启或删除 `cf-agent-wechat`，已观察到微信 Session 保持；
  该结论不能外推为 `agent-wechat` 自身重启可复用 Session。

## 生产入口

```text
Bootstrap   ./scripts/bootstrap-cfserver.sh        # 普通管理用户；只准备，不上线
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
chats/messages 可读或 Gateway 已放行。在线状态须由当次 `./scripts/status.sh` 的全部
11 个状态项和退出码证明；它不包含 PDF/原图取件或下游内容理解验收。

## 状态口径

| 能力/事件 | 来源与边界 |
| --- | --- |
| main 已有 | forced-QR 生命周期；PR #7 Controller 授权预检查、Runtime 服务身份配置与干净设备准备流程 |
| 历史生产成功 | 2026-09-03 fresh QR、API 与私聊/群聊文本闭环；不替代本次 reboot 后复验 |
| 未合并媒体候选 | 锁文件 `0.15.1` 固定源码/制品与隔离校验；不称最新版本或生产现用版本 |
| 历史媒体失败 | PDF 两次 HTTP 200/pending 无 data/url；图片 JPEG 与源文件大小/摘要不同，原图未证明 |
| 待验收 | reboot 后在线/Gate、真实微信 native 取件、PDF 完整字节、图片层级/转码/源文件一致性 |
| Gateway d9 新 plan | 用户报告通过；不能替代 WeChat 入站 PDF/原图验收，本仓不实现分类/理解或 Gateway 队列 |

## 当前限制

- 微信文件原件取件已定位为历史上游镜像仅查缓存；图片不能据 JPEG 响应认定原图。
  [固定升级候选与验收边界](docs/validation/2026-09-28-media-retrieval-candidate.md)
  已单独记录，未部署生产。

- CFserver 重启后必须人工 fresh QR；automatic Gateway boot stop gate 尚未证明。
- 离线或重启窗口内的消息可能无法由本地微信客户端补拉。
- Archive 是受限敏感资产，保留期、容量、备份与安全销毁由外部运维策略负责。
- 上游 `agent-wechat` API/schema 可能变化；镜像升级必须重新验证。
- `seccomp=unconfined` 与 `SYS_PTRACE` 是当前上游要求，需持续审查。
- 锁文件记录了历史公开制品与上游源码 provenance；2026-10-11 实际运行镜像未核对，
  本仓管理脚本 Release Commit 与现场部署的对应关系仍无完整证据。

## 文档

- [文档索引](docs/README.md)
- [当前生产状态](docs/production-status.md)
- [干净 Debian 13 安装与验收](docs/deployment/clean-device.md)
- [CFserver 生产 Runbook](docs/deployment/cfserver-production.md)
- [forced-QR R2 生产验收记录](docs/validation/2026-09-03-forced-qr-r2-production.md)
- [API 边界](docs/api.md)
- [恢复指南](docs/recovery-guide.md)
