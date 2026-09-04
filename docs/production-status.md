# 当前生产状态

> [!IMPORTANT]
> 本页是 `CF_agent-wechat` 当前生产事实的唯一入口，不是命令 Runbook。详细操作只见
> [CFserver 生产 Runbook](deployment/cfserver-production.md)。

## Status

| 字段 | 当前事实 |
| --- | --- |
| Production runtime status | **production online** |
| Closeout date | 2026-09-03 |
| Current forced-QR decision | 每次 CFserver/Agent 重启、容器重建或人工重新启动均使用 fresh Runtime 和新二维码 |
| Repository `main` | `92393bc2ae1d89dae9449fc131413979aa2fa2f2` |
| PR #1 | `OPEN`；Base `main`；Head `feat/forced-qr-login`；已包含 PR #4/#5 与 current-main reconciliation |
| PR #4 | `MERGED`；Merge Commit `92f3f062da564053678cbdd8d2830c82cab0f3fb` |
| PR #5 | `MERGED`；Merge Commit `ed7d50c414c8b146345bbf188be66a1265c4a560` |
| R2 implementation review line | PR #1 / `feat/forced-qr-login` |
| Observed production image ID | `sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720` |
| Exact source-to-image binding status | **未验证**；现有证据不足以把现场 Image ID 精确绑定到某个源码 SHA 或上游 digest |
| Repository promotion status | R2 尚未合并到 `main`，未创建生产 Tag |

当前 PR 栈：

```text
main
  -> PR #1 feat/forced-qr-login
       +-- merged PR #4 Runtime/CI hardening
       +-- merged PR #5 production Closeout docs
```

生产行为已经完成 CFserver 实机验证，不等于仓库分支已经完成 `main` promotion。

## Production deployment

| 项目 | 当前值 |
| --- | --- |
| 项目根 | `/opt/cf-agent-wechat` |
| Compose | `/opt/cf-agent-wechat/docker/compose.cfserver.yaml` |
| 环境文件 | `/opt/cf-agent-wechat/docker/.env` |
| Compose project | `cf-agent-wechat` |
| service | `agent-wechat` |
| container | `cf-agent-wechat` |
| restart policy | `restart: "no"` |
| Agent API | container port `6174`；Host 仅 `127.0.0.1` |
| Docker network | external `cf-internal`；alias `cf-agent-wechat` |
| VNC | `ENABLE_VNC=0`；无 x11vnc、websockify、noVNC 或 Host X11 依赖 |
| security | `seccomp=unconfined`、`SYS_PTRACE`，为当前上游镜像要求 |
| stop grace | `30s` |
| agent-wechat logging | `json-file`，`20m × 3` |

Gateway 的 `64m × 10` 日志策略属于另一个项目，不是 `agent-wechat` 的日志配置。
正式 `docker/.env` 必须使用不可变 `AGENT_WECHAT_IMAGE` digest；本文不猜测现场上游
镜像 digest。

## Storage and Token

| 用途 | 路径 |
| --- | --- |
| storage root | `/srv/storage/cf-agent-wechat` |
| active Runtime | `/srv/storage/cf-agent-wechat/runtime` |
| Runtime data | `/srv/storage/cf-agent-wechat/runtime/data` |
| WeChat HOME | `/srv/storage/cf-agent-wechat/runtime/wechat-home` |
| Archive | `/srv/storage/cf-agent-wechat/session-archive/<UTC timestamp>` |
| Token | `/srv/storage/cf-agent-wechat/secrets/auth-token` |

Token 已验证为：普通文件、非 symlink、hard-link count `1`、owner `10001:10001`、
mode `0600`、恰好 64 个小写十六进制字符、无尾随 LF；父目录为 `root:root 0700`；
容器内只读挂载到 `/data/auth-token`。Token 不在 `.env`、Runtime、Archive、manifest、
日志、命令或状态输出中。其他文档只引用本节，不重复长契约。

Archive 由旧 Runtime 原子移动产生，不覆盖、不自动删除，也不恢复为 active Session。
manifest 只保存脱敏生命周期和清理结果；payload 可能包含 Session、账号/Chat 标识、
消息 metadata、cache 与数据库内容，因此属于受限敏感资产。

## Lifecycle status

- Bootstrap：`sudo ./scripts/bootstrap-cfserver.sh`，只检查和准备部署输入；不创建或恢复
  Session，不启动 Agent，不显示二维码，不启动 Gateway Worker，也不宣称入口在线。
- Fresh QR：`./scripts/start-qr-login.sh`，是唯一生产启动入口。
- Stop：`./scripts/stop-qr-runtime.sh`，停止 Poll/Delivery Worker 和 Agent，保留 Runtime、
  Token 与 Archive。
- Status：`./scripts/status.sh`，只读检查 11 个状态项；完整通过才表示生产在线。
- Compatibility：`./scripts/login.sh` 只转入 `start-qr-login.sh`。

## Production acceptance

2026-09-03 Closeout 汇总：

- 多次在真实 SSH TTY 显示 fresh QR，并由手机扫码确认。
- `cf-agent-wechat` running，Docker health healthy，Agent Server reachable。
- `/usr/bin/wechat` 真实进程存在且同一 `PID:start_time` 身份稳定。
- Auth 为 `logged_in`，chats 可读且非空，并成功读取其中一个聊天的 messages。
- Gateway Runtime `ready=true`、`token_contract_valid=true`、Poll/Delivery 均 healthy。
- 私聊与群聊的 inbound/outbound 集成链路成功，未观察到重复回复。
- Gateway-only 受控切换期间 agent-wechat Session 保持。
- Token 未进入 Archive；状态输出未暴露账号或 Chat ID。

详细一次性证据见
[2026-09-03 forced-QR R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md)。

## Reboot and deployment boundaries

### CFserver reboot

2026-09-01 真实重启中，Docker、存储及 Gateway/PostgreSQL 核心服务恢复；
`cf-agent-wechat` 因 `restart: "no"` 保持停止，旧 Session 未自动恢复。Gateway
Poll/Delivery Worker 当时被观察为 running/healthy，Operator 随后显式关闭 Gate，
运行 fresh QR，最终状态全部通过。

因此 automatic Gateway boot stop gate **未被证明**。Host reboot 后必须先通过正式
Controller 执行并确认 `stop`，再运行 `start-qr-login.sh`；不能只依赖启动脚本稍后
执行 stop。

### AI/Hermes host reboot

只要 CFserver 和 `cf-agent-wechat` 未重启，微信 Session 保持，不需要 fresh QR。
Hermes 连通性恢复属于 Gateway/Hermes 边界；本仓库只确认 agent-wechat 是否仍在线。

### Gateway-only deployment

若没有重启或删除 `cf-agent-wechat`，微信 Session 可以保持，且已在多次受控切换中
观察到。该结论不能外推为 Agent 容器重启后可复用 Session。

## Gateway Runtime Contract

- 通用依赖：Runtime Contract version 1。
- Controller：`/opt/cf-agent-gateway/deploy/wechat-runtime-control`。
- `contract` 动态验证服务名和 Token container path；`stop/start/status` 是受控 Worker
  的唯一生命周期入口。
- R2 实机验收时验证的 Controller implementation commit：
  `e6a8645ff3a97830dc19c5bf57390f94a4840457`。
- 一次性环境快照：Gateway `main`
  `b488cf452584e73bc9b752564bf90ea153aa8d18`；production-validated code
  `f36c798294368263433f6132366ac9a864d9482b`。

这些 SHA 只用于本次生产状态记录。通用 Runbook 以 Contract version 与 Controller
输出为准，不固定旧分支、旧 PR 或旧 SHA。本仓库不拥有 Controller，也不负责 Gateway
的 Message、Admission、Checkpoint、Dispatch、Response 或 Delivery 数据模型。

## Known limitations

1. CFserver reboot 后必须人工 fresh QR。
2. `agent-wechat` 为 `restart: "no"`，不自动恢复 Session。
3. Gateway automatic boot stop gate 未证明；必须显式关闭并确认 Gate。
4. 离线/重启窗口内消息可能无法由本地微信客户端补拉。
5. Archive 不得自动恢复为 active Session。
6. 上游 `agent-wechat` 不是本仓库实现，API/schema 可能变化。
7. `seccomp=unconfined` 与 `SYS_PTRACE` 是持续风险项。
8. 6174 不是公网 API；VNC/noVNC 不在生产链路。
9. 本仓库不保证 Gateway、Hermes、数据库或业务自动化恢复。
10. 源码 SHA 与现场 Image ID 的精确绑定未验证。
11. PR #1 尚未完成最终 `main` promotion。
12. Archive 保留、容量、备份与安全销毁由外部运维策略决定。

## Remaining repository work

1. Review PR #1 and confirm mergeable/CLEAN/CI；本次仓库提升先停在 PR #1，不合入 `main`。
2. 只有证据完整时才建立源码 SHA、上游 digest 与现场 Image ID 的精确映射。
3. Gateway boot stop gate 需要独立后续实现与实机复验。
