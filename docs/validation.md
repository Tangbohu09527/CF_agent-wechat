# 验证总览

本页把已完成的 R2 生产验收、未来 Release 模板、历史记录和剩余限制明确分开。当前
事实以 [生产状态](production-status.md) 为准。

## Status definitions

| 标签 | 当前使用方式 |
| --- | --- |
| **已完成** | 实现、测试、Workflow 和文档存在于 PR #1 Head |
| **已验证（自动化）** | 隔离测试覆盖，不连接 CFserver 或真实微信 |
| **已验证（CFserver 行为）** | 带日期的脱敏现场记录观察到预期行为 |
| **未证明** | 缺少 exact build/provenance 或 automatic boot gate 证据 |
| **后续提升** | PR #1 合入 `main`；不表示生产重新部署 |

历史基线只证明其日期、Commit 与运行方式，不能替代当前 R2 证据。
## A. Completed R2 production acceptance

以下项目已在 2026-09-03 Closeout 前完成真实 CFserver 验证：

- [x] 交互式 SSH TTY 实际显示 fresh QR，手机扫码并确认。
- [x] 正式容器 running，Docker health healthy，Agent Server reachable。
- [x] `/usr/bin/wechat` 真实进程存在并保持同一 `PID:start_time`。
- [x] Auth `logged_in`。
- [x] chats 可读且至少有一个聊天。
- [x] 对 API 返回的一个聊天读取 messages 成功。
- [x] `QR Runtime Mode` 为 `fresh`。
- [x] Gateway Runtime `ready=true`、Token Contract valid。
- [x] Poll Worker 与 Delivery Worker 均 healthy。
- [x] 多次 fresh QR 产生独立 UTC Archive，历史 Archive 未覆盖。
- [x] Token 未进入 Runtime、Archive 或状态输出。
- [x] 真实 CFserver reboot 后 `cf-agent-wechat` 保持停止。
- [x] 重启后显式关闭 Gateway Gate，再 fresh QR，最终全部状态通过。
- [x] 私聊与群聊 inbound/outbound 集成链路成功。
- [x] 未观察到重复回复。
- [x] Gateway-only 受控切换期间 agent-wechat Session 保持。

完整记录：
[2026-09-03 forced-QR R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md)。

### Reboot correction

真实 reboot 中 Gateway Poll/Delivery Worker 曾自动恢复为 running/healthy。因此下列
表述不成立：

```text
主机重启后 Gateway Worker 会自动保持停止
```

当前安全方案是：Host reboot 后先用正式 Controller 显式 `stop` 并确认 Gate 关闭，
再运行 `start-qr-login.sh`。Automatic boot stop gate 是已知限制和后续改进项，不是
已验收能力。

## B. Reusable future validation checklist

以下清单用于未来 Release、镜像、Compose、Runtime Contract 或生命周期变更，默认均为
未执行状态：

- [ ] 记录待验源码 SHA、PR 栈和批准的不可变镜像 digest。
- [ ] 运行 Bootstrap，确认它只准备输入，不创建 Session 或启动 Agent/Worker。
- [ ] 验证 Compose 为 `restart: "no"`、6174 loopback-only、`cf-internal` external。
- [ ] 验证 Token 元数据、只读挂载及 Runtime/Archive 扫描，不输出 Token。
- [ ] 在 Host reboot 后先检查并显式关闭 Gateway Gate。
- [ ] 在交互式 SSH TTY 显示 fresh QR 并实际扫码。
- [ ] 验证 Container、Docker Health、Agent Server、WeChat Process、Auth、Runtime Mode、
  Message API 与四项 Gateway 状态。
- [ ] 验证 chats 非空，并对 API 返回的一个聊天读取 messages。
- [ ] 验证 stop 保留 Runtime、Token 和所有 Archive。
- [ ] 验证失败流程保留证据、Worker 不放行、容器 stop/remove 结果可确认。
- [ ] 验证 Agent crash、Docker daemon restart、CFserver reboot 均不会自动恢复 Agent。
- [ ] 验证 Gateway-only deployment 不重启或删除 Agent 时的 Session 边界。
- [ ] 验证私聊和群聊 inbound/outbound，不记录参与者、Chat ID 或正文。
- [ ] 运行静态、单元、集成、Compose render、Markdown 链接与敏感信息检查。
- [ ] 新增带日期的脱敏验证记录，并明确未验证项。

未来 Release 的 `[ ]` 不得与本次已完成 `[x]` 混写成同一验收状态。

## C. Historical validation records

| 记录 | 适用范围 | 不可外推 |
| --- | --- | --- |
| [2026-08-13 CFserver](validation/2026-08-13-cfserver-production.md) | 旧基线、可信设备确认、基础 API | 不能证明 forced fresh QR、当前 Runtime 轮换或当前 Gateway Contract |
| [2026-08-14 消息与媒体](validation/2026-08-14-message-media-production.md) | 当时文本发送、消息字段、图片 media | 不能替代 2026-09-03 R2 生命周期验收 |
| [V1 验证结果](05_V1验证结果.md) | 实验室固定镜像与 VNC/noVNC 背景 | 不能作为生产 Runbook 或自动恢复授权 |

## Regression requirements

以下变化必须重新运行自动化门禁，并在涉及生产行为时建立新的带日期脱敏记录：

1. 镜像 digest、Compose、端口、网络、挂载或 `restart: "no"`。
2. Runtime/Archive 路径、原子移动、权限或 manifest。
3. Token owner/mode/content、只读挂载或 Token Contract。
4. `newAccount=true`、QR payload、WebSocket 或登录超时。
5. WeChat 进程、Auth、chats/messages 或 11 项 status 判定。
6. Runtime Controller contract/stop/start/status 或 Poll/Delivery Gate。
7. Host reboot、Docker daemon restart、升级、重建或回滚。
8. Archive 保留、访问控制、备份或审批销毁。
9. automatic boot stop gate 的实现或验证状态。
## D. Remaining limitations

- Automatic Gateway boot stop gate 尚未实现或证明；真实 reboot 中 Worker 曾自动恢复。
- CFserver reboot 后需要人工 fresh QR，离线窗口消息可能不补拉。
- Archive 不恢复为 active Session，保留和销毁由外部策略管理。
- 上游 API/schema 与镜像运行要求可能变化，升级后必须重验。
- `seccomp=unconfined` 与 `SYS_PTRACE` 仍需持续风险评估。
- 本仓库不验证 Gateway 内部去重、Admission、Checkpoint、Dispatch、Response、
  Delivery Receipt 或 Hermes 业务语义。
- 现场 Image ID 与源码 SHA 的精确构建映射未验证。
- PR #4/#5 已并入 PR #1；PR #1 仍未提升到 `main`。
