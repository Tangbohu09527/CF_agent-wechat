# Historical R2 implementation audit

> [!CAUTION]
> **Historical / Archived.** 本页记录 PR #4 实现线在
> `dc103c855e965524aa54325ce9c878321e3b1f3f` 前后的设计选择，不是当前 CFserver
> Runbook。当前事实见 [生产状态](production-status.md)，当前操作见
> [CFserver 生产 Runbook](deployment/cfserver-production.md)，实机结论见
> [2026-09-03 R2 验收](validation/2026-09-03-forced-qr-r2-production.md)。
>
> 仍有效：forced fresh QR、`restart: "no"`、Runtime/Archive/Token 隔离、
> fail-closed、Controller Contract v1。不能外推：设计阶段的“待实机验证”状态、
> automatic Gateway boot stop gate、旧 Gateway 分支/SHA 或源码与现场 Image ID 映射。

## Audit purpose

R2 选择人工 fresh QR 生产模型：

~~~text
Bootstrap only prepares
  -> Controller stops Poll/Delivery
  -> old Agent removed
  -> old Runtime archived
  -> fresh Runtime and QR
  -> process + auth + chats + messages
  -> Controller starts/statuses Poll/Delivery
~~~

旧 Runtime 只作为受限 Archive 保留，不恢复为 active Session。

## Historical PR #2 selection

PR #2 曾包含可移植的安全加固，也包含与 forced-QR 决策冲突的自动恢复设计。R2 的历史
处理为：

| 分类 | 选择 |
| --- | --- |
| 保留 | 路径/权限校验、rootful local Docker、Token 隔离、硬超时、错误脱敏、CI 加固 |
| 重设计 | Bootstrap、Compose 生命周期、登录管理、失败 cleanup、恢复文档 |
| 拒绝 | `unless-stopped`、自动 Session reuse、`logged_in` short-circuit |

这张表只解释实现来源，不授权修改既有 PR 栈或重新移植历史分支。

## Controls retained in current R2

- Bootstrap 不登录或启动 Agent/Worker。
- Compose 为 digest-pinned、loopback-only、`restart: "no"`。
- Runtime 与 Archive 分离，Token 独立只读挂载。
- mixed layout 与 Token scan 失败在状态变更前 fail closed。
- fresh QR 需要当前 SSH TTY 实际显示文本 QR。
- PNG-only `qrDataUrl` 生产路径 fail closed。
- 同一 `PID:start_time`、Auth、非空 chats、messages 读取共同构成 WeChat readiness。
- Controller `contract/stop/start/status` 是 Poll/Delivery 生命周期边界。
- 失败 cleanup 尝试再次关闭 Gate，并 stop/remove Agent，保留持久证据。

## Production result correction

2026-09-03 Closeout 已验证 fresh QR、真实进程、auth/chats/messages、Controller ready、
Poll/Delivery healthy、CFserver reboot 后 Agent 停止及完整恢复。

原设计目标“Host reboot 后 Gateway Worker 自动保持停止”没有被实测支持。真实 reboot
中 Worker 曾自动恢复为 running/healthy，因此当前 Runbook 强制 Operator 在 fresh QR
前显式 Controller stop/confirm。Boot stop gate 是后续改进项。

## Gateway boundary

当前通用依赖只有 Runtime Contract version 1 与固定 Controller 路径。旧 Gateway
branch、SHA 或 PR 只可在对应历史记录中出现，不能成为永久 Runbook 依赖。本仓库不拥有
Controller，不管理 Gateway Message、Admission、Checkpoint、Dispatch、Response 或
Delivery Receipt。

## Source/image boundary

现场观察到的 Docker Image ID 已记录在 [生产状态](production-status.md)。没有完整
构建证据时，不把它精确绑定到 PR #4 Head、某个源码 SHA 或猜测的上游 digest。

## Historical conclusion

该实现审计仍可用于理解 R2 为什么拒绝自动 Session 恢复、VNC/noVNC 和裸 Compose
生命周期，但不得作为部署步骤或当前状态来源。
