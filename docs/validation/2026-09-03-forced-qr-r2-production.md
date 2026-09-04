# 2026-09-03 forced-QR R2 生产验收记录

> [!IMPORTANT]
> 本页是一次性、脱敏的生产 Closeout 记录，不是未来部署 Runbook。可复用命令见
> [CFserver 生产 Runbook](../deployment/cfserver-production.md)，当前状态见
> [生产状态](../production-status.md)。

## Scope

本次验收确认 `CF_agent-wechat` forced-QR R2 在真实 CFserver 上的生产行为、重启恢复、
Gateway Runtime Contract、Archive/Token 边界和端到端消息链路。记录不包含真实账号、
联系人、群名、Chat ID、二维码、Token、消息正文、内网 IP 或数据库连接信息。

## Environment boundary

- 项目根：`/opt/cf-agent-wechat`
- 正式 Compose：`/opt/cf-agent-wechat/docker/compose.cfserver.yaml`
- Compose project/container：`cf-agent-wechat`
- Runtime：`/srv/storage/cf-agent-wechat/runtime`
- Archive：`/srv/storage/cf-agent-wechat/session-archive/<UTC timestamp>`
- Token：`/srv/storage/cf-agent-wechat/secrets/auth-token`
- Gateway Controller：`/opt/cf-agent-gateway/deploy/wechat-runtime-control`
- Agent API：Host loopback 与 `cf-internal` 内部网络；未开放公网入口
- VNC/noVNC：不在生产路径，`ENABLE_VNC=0`

## Repository/PR state

| 层级 | 验收时状态 |
| --- | --- |
| `main` | `92393bc2ae1d89dae9449fc131413979aa2fa2f2` |
| PR #1 | `OPEN`；`feat/forced-qr-login` @ `9cb7163cb226b4eed2581e11ff298e41f96226b6` |
| PR #4 | `OPEN`；`codex/forced-qr-production-hardening-r2` @ `dc103c855e965524aa54325ce9c878321e3b1f3f` |
| 当前实现评审线 | PR #4，Base 为 PR #1 分支 |
| `main` promotion | 未完成 |

生产行为已验收，不代表 PR #1/PR #4 已合并，也不代表 `main` 是 R2 代码权威。

## Production container identity

- service：`agent-wechat`
- container：`cf-agent-wechat`
- restart：`"no"`
- Agent port：`6174`，Host 仅 loopback
- network：external `cf-internal`，alias `cf-agent-wechat`
- 日志：`json-file`，`20m × 3`
- stop grace：`30s`
- 当前上游要求：`seccomp=unconfined`、`SYS_PTRACE`
- 现场观察 Docker Image ID：
  `sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720`

未取得足以证明“该 Image ID 精确对应某源码 SHA 或上游 digest”的构建证据，因此不作
精确映射声明。

## Fresh QR acceptance

多次真实 fresh QR 均完成以下闭环：

1. 通过 Controller 停止并确认 Poll/Delivery Gate。
2. 停止并移除旧 `cf-agent-wechat` 容器。
3. 将旧 Runtime 原子移动到新的 UTC Archive。
4. 创建全新 `runtime/data` 和 `runtime/wechat-home`。
5. 使用 `newAccount=true` 启动登录。
6. 在交互式 SSH TTY 中实际显示至少一个二维码。
7. 手机扫码并确认。
8. 正式容器 running，Docker health healthy，Agent Server reachable。
9. `/usr/bin/wechat` 进程存在且同一 `PID:start_time` 稳定。
10. Auth 为 `logged_in`，chats 可读且非空，messages 可读。
11. Gateway Controller status 全部满足放行条件。

未实际显示 QR 的 `login_success` 不计为验收证据；PNG-only `qrDataUrl` 的生产
fail-closed 行为与当前实现一致。

## Post-reboot acceptance

2026-09-01 的真实 CFserver reboot 验证结果：

- Docker service 恢复，存储正常挂载。
- Gateway/PostgreSQL 核心服务恢复。
- `cf-agent-wechat` 因 `restart: "no"` 保持停止/离线。
- 旧微信 Session 未自动恢复。
- Gateway Poll/Delivery Worker 当时被观察为 running/healthy。
- Operator 显式执行 Controller `stop` 并关闭 Gate。
- 随后执行 fresh QR，手机扫码，入口恢复在线。
- `status.sh` 最终全部通过。

因此“Gateway Worker 在 Host reboot 后自动保持停止”未通过验收。当前安全要求是重启后
显式 stop/confirm，再 fresh QR。

## API readiness

验收确认以下生产就绪层级：

- `/health` 可达。
- `/api/status/auth` 返回 `logged_in`。
- `/api/chats` 可读且至少存在一个聊天。
- 对 API 返回的一个聊天，`/api/messages/{chat_id}` 可读。
- 状态输出不包含账号或 Chat ID。

Docker health 或 `logged_in` 单项均不足以代表生产在线。

## Gateway Contract acceptance

- Runtime Contract version 1 验证通过。
- Controller implementation commit：
  `e6a8645ff3a97830dc19c5bf57390f94a4840457`。
- Gateway `main` 快照：`b488cf452584e73bc9b752564bf90ea153aa8d18`。
- production-validated code：`f36c798294368263433f6132366ac9a864d9482b`。
- `ready=true`。
- `token_contract_valid=true`。
- `worker_health=healthy`。
- `delivery_health=healthy`。

这些 SHA 是本次验收环境记录，不是通用 Runbook 的永久依赖。通用操作以 Contract
version 与 Controller `contract/stop/start/status` 输出为准。

## Integrated inbound/outbound evidence

forced QR 后，真实私聊和群聊均通过以下完整链路：

```text
WeChat
  -> agent-wechat chats/messages API
  -> Gateway
  -> Hermes
  -> Gateway delivery
  -> agent-wechat send API
  -> WeChat reply
```

已确认 inbound 可读取、outbound reply 可发送，且未观察到重复回复。Gateway-only
受控切换期间 agent-wechat 状态和 Session 保持。

Message 去重、Admission、Checkpoint、Dispatch、Response 和 Delivery Receipt 属于
`CF_agent-gateway`；本记录只把结果作为跨系统集成证据，不把其内部语义归属给本仓库。

## Archive and Token safety

- 成功 Archive 示例：
  `/srv/storage/cf-agent-wechat/session-archive/20260901T015824Z`
  和 `/srv/storage/cf-agent-wechat/session-archive/20260901T093918Z`。
- 示例只属于本次验收；通用文档使用 `<UTC timestamp>`。
- Archive 未覆盖历史目录，也未恢复为 active Session。
- Token 未进入 Runtime、Archive 或 manifest。
- Token 元数据与格式契约通过，内容未记录、未输出、未哈希。
- Archive payload 仍可能包含 Session 与消息相关敏感数据，按受限资产处理。

## Failure/rollback evidence

- fresh QR 前的受控 Gate stop 已验证；完整就绪前不放行 Worker。
- 多次 Runtime 轮换保留历史 Archive，没有用旧 Archive 回滚 active Session。
- Gateway-only 切换证明“不动 Agent 容器时 Session 可保持”，不构成 Agent restart
  恢复证据。
- 本次生产 Closeout 未故意注入容器 remove 失败、Archive 写失败或源码/镜像回滚；
  这些失败路径由仓库自动化覆盖，若生产发生必须按 Recovery Guide 保留现场并 fail
  closed。

## What was not validated

- Automatic Gateway boot stop gate 未被证明，真实 reboot 观察结果与最初目标不同。
- 未证明现场 Image ID 与 PR #4 源码 SHA 的精确构建映射。
- 未把 Archive 恢复为 active Session，也未授权这种操作。
- 未验证本仓库对 Gateway/Hermes/数据库的恢复保证，因为这些属于外部系统。
- 未把 6174 暴露为公网 API，未启用 VNC/noVNC。

## Remaining known limitations

- CFserver reboot 后仍需人工 fresh QR，并显式关闭 Gateway Gate。
- 离线窗口消息可能无法补拉。
- 上游 API/schema 变化需要重新验收。
- `seccomp=unconfined` 与 `SYS_PTRACE` 需要持续风险审查。
- Archive 的保留、容量、备份和销毁由外部策略负责。
- PR #1/PR #4 尚未完成 `main` promotion。
