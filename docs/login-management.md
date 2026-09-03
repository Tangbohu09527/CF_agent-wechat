# 微信登录生命周期

本文描述 forced-QR R2 的状态机、脚本职责、权限、锁、退出码和 fail-closed 语义。
Operator 的扫码步骤见 [QR Login Guide](qr-login-guide.md)，完整命令见
[CFserver 生产 Runbook](deployment/cfserver-production.md)。

## Lifecycle state machine

~~~text
offline/stopped
  -> validate Contract and deployment inputs
  -> Controller stop confirms Poll/Delivery gate closed
  -> old Agent removed
  -> old Runtime archived
  -> fresh Runtime created
  -> Agent healthy + WeChat process stable
  -> newAccount=true
  -> QR rendered in current SSH TTY
  -> phone confirms
  -> auth + chats + messages ready
  -> Controller start/status ready
  -> production online
~~~

当前生产不包含 “restore old Session” 状态。任何 Agent restart/recreate 后都回到
`offline/stopped -> fresh QR`。

## Script responsibilities

| 脚本 | 职责 | 明确不做 |
| --- | --- | --- |
| `bootstrap-cfserver.sh` | 准备 Host、Docker、目录、Token、网络、Compose、Contract | 不创建 Session，不启动 Agent/Worker |
| `start-qr-login.sh` | 唯一生产启动；轮换 Runtime、fresh QR、完整验证、放行 Worker | 不复用 Archive，不绕过 Controller |
| `stop-qr-runtime.sh` | Controller stop 后停止 Agent | 不删除 Runtime、Token、Archive 或容器 |
| `status.sh` | 只读输出 11 项状态和退出码 | 不启动、停止或修复 |
| `login.sh` | 兼容包装，直接 `exec start-qr-login.sh` | 不是第二套登录方式 |

## Gateway Controller interaction

固定入口：

~~~text
/opt/cf-agent-gateway/deploy/wechat-runtime-control
~~~

生命周期脚本：

1. 先调用 `contract`，要求精确 Runtime Contract version 1。
2. fresh QR 前调用 `stop`，响应必须只确认 `stopped=true`。
3. 完整 Agent/API 验证后调用 `start`。
4. 立即调用 `status`，要求 `ready=true`、`token_contract_valid=true`、
   `worker_health=healthy`、`delivery_health=healthy`。

Controller 是 Poll/Delivery Worker 的唯一生命周期入口。Contract 还声明 Dispatch
service name，但本仓库的 QR 生命周期不启停 Dispatch，也不拥有 Gateway 内部实现。

## Permission model

- 普通管理用户运行 start/stop/status；非 dry-run start 必须有 stdin/stdout TTY。
- 需要提权时先完成一次 `sudo -v`，后续受控操作只使用 `sudo -n`。
- Docker 可由当前用户直接访问，或在已授权后通过受控 `sudo -n docker` 访问。
- 二维码 Python venv 位于普通用户数据目录，禁止用 sudo 安装依赖。
- Token 只在内存和认证请求头中使用；完整文件契约见
  [生产状态](production-status.md#storage-and-token)。
- 外部错误会隐藏 Token、去除控制字符并限制长度。

## Lock and concurrency

start/stop 共用：

~~~text
/run/lock/cf-agent-wechat-qr-runtime.lock
~~~

- 使用 non-blocking `flock`；已有操作持锁时后续操作失败。
- 空锁文件存在不代表锁正在持有，不得因文件存在就删除。
- `--dry-run` 在获取锁前返回，不创建或修改锁文件。
- 重复 fresh QR 使用新 UTC Archive，不覆盖旧 Archive。

## Fresh QR rules

- HTTP start 使用 `POST /api/status/login?newAccount=true`。
- WebSocket URL强制设置 `newAccount=true` 和总时限 `timeoutMs`。
- 生产 session ID 必须为 `default`。
- 只有当前 WebSocket 的 `qr` 事件实际渲染后，才能接受 `login_success`。
- 文本 `qrBinaryData` 或 `qrData` 可在渲染前检查是否包含 Token。
- PNG-only `qrDataUrl` 当前无法可靠审计，生产模式在任何二维码输出前 fail closed。
- fresh Runtime 若先报告 `logged_in`，流程报
  `runtime is not clean; use start-qr-login.sh`，不能短路。
- 登录后必须再次验证同一 `PID:start_time`，并在
  `POST_LOGIN_READY_TIMEOUT` 内完成 auth/chats/messages。

## Exit codes

### status.sh

| 码 | 含义 |
| --- | --- |
| `0` | 11 个生产状态门槛全部通过 |
| `1` | 配置/依赖、查询、Token、Message API 或 Gateway readiness 失败 |
| `2` | Auth 明确为 `logged_out` |
| `3` | 容器、Docker health、Agent Server、WeChat process、Runtime mode 或其他认证状态不可用 |

### start-qr-login.sh / stop-qr-runtime.sh

- `0`：各自完整流程成功。
- `1`：参数、配置、权限、Contract、容器、Archive、QR、API 或 Worker 操作失败。
- `130`：start 流程收到 INT/TERM。

`login.sh` 继承 `start-qr-login.sh` 的退出语义。

## Fail-closed behavior

- Contract、mixed layout、Token scan、Compose attestation 或锁失败发生在状态变更前。
- 初始 Controller stop 无法确认时，流程立即失败，不声称 Worker 已停止。
- 进入 Agent 轮换阶段后的失败会再次尝试 Controller stop，并尝试 stop/remove Agent。
- cleanup 不删除 Runtime、Archive、bind data 或 volume；结果写入脱敏 manifest。
- cleanup 失败不覆盖原失败 phase，必须先人工确认残留容器再重启 Docker/Host。
- Auth `logged_in`、Docker health、`login_success` 任一单项都不能手工放行 Worker。

## Current evidence boundary

forced fresh QR、真实进程稳定、auth/chats/messages、Controller ready 与 Poll/Delivery
healthy 已完成 CFserver 实机验收。Automatic Gateway boot stop gate 尚未证明，Host
reboot 后必须显式 stop/confirm。详见 [生产状态](production-status.md)。
