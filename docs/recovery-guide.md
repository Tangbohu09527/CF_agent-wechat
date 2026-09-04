# Recovery Guide

恢复的目标是重新建立一套经过 fresh QR 验证的 Runtime，不是恢复旧微信 Session。
所有场景遵循：

~~~text
检查 -> 判断 -> 操作 -> 验证 -> 失败回退
~~~

详细命令以 [CFserver 生产 Runbook](deployment/cfserver-production.md) 为准。

## Baseline checks

~~~bash
cd /opt/cf-agent-wechat
./scripts/status.sh
~~~

需要更多信息时，只查看 Compose `ps`、必要日志、目录/文件元数据和 Controller
`contract/status`。不要读取 Token、Archive payload、账号或消息正文。

## Recovery matrix

| 场景 | 检查与判断 | 安全操作 | 验证 | 失败回退 |
| --- | --- | --- | --- | --- |
| Container absent/stopped | `Container=absent/stopped`；确认是否计划内 | 确认 Gate 后运行完整 fresh QR | 11 项状态全过 | 保留现场，Controller stop，不裸 `up` |
| Docker health unhealthy | Container running 但 health 非 healthy；看轮转日志 | 运行完整 fresh QR，不直接 restart | Docker health、进程、API、Gateway 全过 | 保留 Runtime/Archive，查镜像/资源/挂载 |
| Agent Server unreachable | `Agent Server=unavailable`；health 可能也失败 | 完整 fresh QR | `/health` 与完整 status | 不延长为无限超时，不手工启动 Worker |
| WeChat process missing/replaced | `not_running` 或 `exited_or_replaced` | 完整 fresh QR | 同一 `PID:start_time` 稳定 | 保留日志，查上游进程/Xvfb/资源 |
| Auth logged_out | status 退出 `2` | 完整 fresh QR | Auth + chats/messages + Gateway | 不执行 UI logout，不只调用登录 API |
| Chats unreadable/empty | Auth 可为 logged_in，但 Message API 失败 | 完整 fresh QR | chats 非空且 messages 可读 | 不硬编码 Chat ID，不从数据库替代验证 |
| Messages unreadable | chats 已返回 ID，但 messages 校验失败 | 完整 fresh QR | 对 API 返回的聊天读取成功 | 不跳过该门槛，不手工放行 Worker |
| Gateway ready=false | Agent 层可能正常；Controller status 未就绪 | 交给 Gateway 运维修复 Contract/Worker 后复核 | ready/token/两 Worker 全过 | 保持 Gate 关闭，不改 Gateway 数据库 |
| Poll/Delivery stopped | 若 Agent 在线，判断是计划停止还是 Gateway 故障 | 只通过 Controller/正式流程恢复 | 两项 health 为 healthy | 不手工运行 Compose service |
| Runtime mode legacy_or_unknown | mount 不匹配 fresh Runtime/Token 契约 | 先停止 Gate，保留现场，修复受控输入后 fresh QR | `QR Runtime Mode=fresh` | 不删除或挂回 Archive |
| Failed Archive manifest | 查看 manifest 是否为 failed、phase 与 cleanup 结果 | 保留 Archive，修复根因后完整重试 | 新流程成功且旧证据仍在 | 不改写旧结果，不把 manifest 当 payload 无敏感证明 |
| Mixed layout | 新 Runtime 与 legacy data/HOME 同时存在 | fail closed；确认受控来源并走独立人工处置 | 重新校验无 mixed layout 后 Bootstrap/fresh QR | 不合并、不删除任一目录掩盖状态 |
| Token metadata invalid | 只用 `stat` 查 type/owner/mode/link | 保留文件，离线修复到当前契约后重跑 Bootstrap | Bootstrap/状态安全加载 Token | 不读取、重生成替换或复制 Token |
| Docker daemon reboot | Agent 应保持停止 | 确认 Gate，再完整 fresh QR | status 全过 | 若 Agent 自动恢复，先修复 restart/live-restore 偏差 |
| CFserver reboot | Agent 停止，但 Worker 可能 running | 强制 Controller `stop --timeout-seconds 30`，再 fresh QR | status 全过 | 不依赖 automatic boot stop gate |
| Interrupted QR flow | start 返回 `130` 或连接中断 | 等待 cleanup/锁释放，确认 Gate，再重新运行完整流程 | 新 QR 实际显示并完整就绪 | 不复用旧 QR，不删除锁文件 |
| Container stop/remove failed | 查看 cleanup 的 stop/remove 脱敏结果 | 保留容器和持久数据，人工确认容器已停止/移除后再重试 | 容器状态明确且新流程全过 | 确认前不重启 Docker/Host |
| Archive exists, active Runtime missing | 判断是否中断在 archive 与 create 之间 | 不恢复 Archive；确认 Gate 后重新运行 fresh QR 创建新 Runtime | 新 Runtime fresh、旧 Archive 保留 | 不把 Archive 移回 active path |
| Gateway-only deployment | Agent 未被重启/删除时 Session 可保持 | 不运行 fresh QR；由 Gateway 运维恢复后复核 status | Agent 与 Gateway 状态全过 | 若 Agent 实际被动过，改走 fresh QR |
| AI/Hermes host restart | CFserver/Agent 未重启 | 不轮换 Agent；恢复外部连通性 | 本仓库 status 与下游独立验证 | 不把下游故障归为微信 Session 故障 |

## Container and API failures

Docker health 只证明 `/health`，不能证明 WeChat、chats/messages 或 Gateway。任何需要
重建 Agent 的场景都使用 `start-qr-login.sh`；该脚本负责 stop/remove、Archive、fresh
Runtime、QR 和 Worker gate。禁止 `docker restart`、裸 Compose `up/restart/down`。

## Runtime and Archive failures

- Archive 由旧 Runtime 原子移动产生，不是自动恢复点。
- 历史 Archive 不覆盖、不删除；新流程使用新 UTC 目录。
- legacy `data` 与 `wechat-home` 必须进入同一个 Archive。
- mixed layout 在任何状态变更前 fail closed。
- Archive payload 可能含 Session、账号/Chat 标识、消息 metadata、cache 和数据库内容。
- 不得删除 Runtime、跳过 Token scan 或把 Archive 挂回 active path。

## Token failures

完整契约见 [生产状态](production-status.md#storage-and-token)。只允许查看元数据；未知
格式必须保留并离线修复。Bootstrap 只自动迁移精确定义的单一 legacy 格式，不能用新
Token 替换已有数据库关联 Token。

## Gateway failures

只使用：

~~~text
/opt/cf-agent-gateway/deploy/wechat-runtime-control
~~~

- `contract` 验证 version 1。
- `stop` 关闭 Poll/Delivery Gate。
- `start/status` 只在 Agent 完整就绪后使用。

不得绕过 Controller，也不得修改 Gateway、PostgreSQL、Checkpoint 或 Hermes 数据。
`ready=false`、Token Contract invalid 或任一 Worker health 非 healthy 都是完整状态
失败，即使 Agent Auth 为 `logged_in`。

## Verification and fallback

恢复成功必须由 `./scripts/status.sh` 退出 `0` 证明。失败时：

1. 保留原退出码和失败 phase。
2. 保留 Runtime、Archive、manifest 与必要轮转日志。
3. 确认 Gate 关闭；不确定时再次 Controller stop。
4. 确认失败 Agent 容器是否仍存在。
5. 不删除未知状态，不恢复旧 Session，不手工启动 Worker。
6. 修复根因后重新执行完整 fresh QR。

状态与证据不得包含 Token、二维码、账号、联系人、群名、Chat ID、消息正文、内网 IP
或数据库连接信息。
