# Deployment Audit

本文记录 forced fresh QR 生产部署的设计审计。它是代码与文档契约，不是 CFserver
实机验收记录。

## 审计结论

生产生命周期采用：

```text
Bootstrap 只准备
  -> Agent/Worker 保持停止
  -> 人工 start-qr-login.sh
  -> 归档旧 runtime
  -> 全新 data/wechat-home
  -> 全新二维码
  -> auth/chats/messages
  -> Worker 放行
```

生产 Compose 必须为 `restart: "no"`。容器 crash、Docker daemon 重启、Host 重启、
recreate、升级和回滚均不得自动恢复旧微信 session。

## PR #2 选择性移植

PR #2 的 CI 曾通过，但其生产生命周期采用 `unless-stopped`、自动 session reuse 和
`logged_in` short-circuit。这些行为与批准的 forced fresh QR 模型冲突，因此不能整体
merge、rebase 或 cherry-pick。

| 分类 | 处理 |
| --- | --- |
| PORT | 路径、owner/mode、symlink/hardlink、rootful local Docker、Token、超时、错误脱敏、CI 和测试加固 |
| REDESIGN | Bootstrap、Compose lifecycle、真实 Docker E2E、登录管理和恢复文档 |
| REJECT | `unless-stopped`、crash/daemon/host 自动恢复、旧 session reuse、`logged_in` 跳过扫码 |

选择性移植必须保留 forced-QR 基线的原子归档、新 runtime、Worker gating 和唯一生产入口。

## 控制矩阵

| 控制 | 生产要求 | 证据类型 |
| --- | --- | --- |
| Bootstrap | 只准备，不登录，不启动 Agent/Worker | Fake Docker、分阶段重试测试 |
| Docker | 固定系统工具、真实非符号链接 socket、本机 rootful/default endpoint、`live-restore=false` | environment 测试 |
| Compose | digest、loopback、alias、只读 Token、`restart: "no"` | 静态契约与真实 render |
| Restart | crash/daemon/host 均不恢复 | Real Docker 已覆盖正常/异常退出与 daemon restart，待绿色 Run ID；Host 仍需实机 |
| Runtime | 旧目录原子归档，新 data/home 隔离 | forced-QR lifecycle |
| QR | 当前 TTY 显示可审计的文本 fresh QR 后才接受成功；拒绝 PNG-only | QR unit/integration；真机扫码待验证 |
| API | process、auth、chats、messages 全通过 | lifecycle 与 CFserver 实机 |
| Worker | fresh QR 前停止，完整验证后启动；固定 checker 验证 heartbeat | lifecycle；healthy/heartbeat 待实机 |
| Token/archive | Token root-only、只读且不进 archive/log/error/CI；旧 runtime archive root-protected | permissions 与 secret scan |
| 错误 | 超时、有界长度、去控制字符、外部错误脱敏 | unit/integration |
| 文档 | 两阶段流程、UTC/时区和边界一致 | link/UTF-8/lifecycle scan |

## Compose 与健康边界

正式 Compose 必须包含：

- digest-pinned image；
- `restart: "no"`；
- fresh runtime 的 data/wechat-home bind；
- root-only Token read-only bind；
- loopback 6174；
- 外部 `cf-internal` 和固定 alias `cf-agent-wechat`；
- healthcheck、日志轮转、`ENABLE_VNC=0`；
- 当前上游所需 `seccomp=unconfined` 和 `SYS_PTRACE`。

Healthcheck 只证明容器和 Agent API 健康，不能证明微信登录、chats/messages 或 Gateway
链路。上游权限必须随每次镜像升级持续安全审查。

Bootstrap 必须使用固定系统 Docker/systemctl/OpenSSL/timeout 工具并校验真实非符号链接
`/var/run/docker.sock`。生产启动重新验证本机 rootful/default endpoint 与
`live-restore=false`，Docker、Compose 和 API 调用均受 hard timeout 约束。forced
production 只接受渲染前可检查 Token 的文本 QR payload；PNG-only `qrDataUrl` 必须在
输出二维码前 fail closed。

## Gateway 边界

允许本仓库：

- 校验 Gateway 生产路径；
- 在 fresh QR 前停止并确认 `wechat-worker`；
- 完整验证后启动并确认 `wechat-worker`。

固定 checker 为 `/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`，由 Gateway
部署提供，本仓库不创建或修改。它必须通过 owner/mode、非 symlink、无额外 hardlink
检查，由管理用户直接在 hard timeout 内执行，禁止 `sudo`。只有当前 Worker 应用
heartbeat 可用时才能返回 `0`，且不得输出敏感数据。

禁止本仓库：

- 修改 Gateway 源码、配置数据库、PostgreSQL 或 Checkpoint；
- 启停 `dispatch-worker` 或 `delivery-worker` 作为 QR 步骤；
- 使用 SQL、`bootstrap_mode=latest` 或 localId 回退解决 Runtime 恢复；
- 修改其他仓库。

Gateway boot stop gate、Worker healthy/heartbeat 和真实重启窗口必须在 CFserver 实机
验证，不能由本仓库 CI 代替。

## 敏感信息

Token、二维码、微信账号、联系人、聊天 ID、消息正文、服务器地址、API Key 和密码不得
进入 Git、manifest、日志、错误、CI 输出或 artifact；Token 还绝不能进入 archive。

Archive 本身可能包含旧 session、缓存和消息数据，必须 root-protected，只能用于受控
审计或故障分析，且绝不能挂回生产复用。Archive manifest 只记录 schema version、UTC
时间、旧 runtime path、镜像 digest、owner/mode 和归档结果等脱敏元数据。

## 时间模型

- Host：`Asia/Shanghai`。
- Container：UTC。
- Logs：UTC。
- Archive manifest 与原始审计证据：UTC。
- 人工展示：可以转换为 `Asia/Shanghai`，必须标明时区。

## 仍需实机验证

- 真实 CFserver 上 Bootstrap fail-closed 和安全重试。
- 真实手机扫描当前 TTY 显示的全新二维码。
- WeChat process 稳定及 auth/chats/messages 完整验证。
- Gateway boot stop gate。
- `wechat-worker` running/healthy/heartbeat。
- 真实 Debian/Host restart 后 Agent 不自动恢复，且 Worker boot stop gate 持续有效。
- 真实 archive、权限、时区和脱敏记录。

实机记录不得包含任何敏感值。当前验证状态见[验证总览](validation.md)。
