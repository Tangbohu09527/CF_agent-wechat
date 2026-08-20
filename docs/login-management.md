# 微信登录管理

## 适用范围

本文说明 CFserver 生产环境的强制全新二维码登录流程。生产环境不再恢复旧微信会话；
每次 Debian 重启、容器重建或人工重新启动微信入口，都必须通过 SSH 运行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

这是唯一生产启动入口。`scripts/login.sh --force-qr` 是该入口调用的底层登录步骤，不是
绕过 runtime 轮换的独立恢复命令。VNC、noVNC、RDP、宿主桌面和 UI logout 都不属于
当前流程。

## 启动编排

`start-qr-login.sh` 按固定顺序执行：

1. 校验生产 Compose、命令、Token 元数据、runtime、legacy 目录、归档根和必要配置。
2. 非 dry-run 获取 `/run/lock/cf-agent-wechat-qr-runtime.lock` 独占锁。
3. 停止 Gateway `wechat-worker`。
4. 停止并删除旧 `agent-wechat` 容器，但不执行 `docker compose down`。
5. 将当前 runtime 原子移动到
   `/srv/storage/cf-agent-wechat/session-archive/<UTC时间戳>/`；首次上线只有
   `${STORAGE_ROOT}/data`、`${STORAGE_ROOT}/wechat-home` 旧布局时，将存在的两个目录
   迁入同一时间戳归档。新旧布局同时存在则在任何变更前 fail-fast。
6. 按原目录正确的 UID、GID 和权限创建全新的 `runtime/data` 与
   `runtime/wechat-home`。
7. 启动 `agent-wechat`，等待 agent-server 可访问。
8. 确认 `/usr/bin/wechat` 真实进程存在并稳定，认证状态进入 `logged_out` 或二维码
   登录界面。
9. 调用 `login.sh --force-qr`；当前 SSH 终端必须实际渲染至少一个 QR，才接受登录成功。
10. 登录后在 `POST_LOGIN_READY_TIMEOUT` 有界时间内等待 WeChat 进程持续存在、
    `/api/status/auth` 为 `logged_in`、`/api/chats` 至少返回一个聊天，并对 API
    返回的一个聊天执行消息读取。
11. 只有全部验证通过，才启动 Gateway `wechat-worker` 并输出最终状态。

脚本确认 worker 已停止后，后续任一步失败都会让它保持停止，不启动 AI 调度；若初始
停止无法确认，流程立即失败并明确报告，不能声称 worker 已被本仓保证停止。当前或历史
归档均不删除。

### Dry run

以下命令只显示计划动作，不停止或删除容器、不停止或启动 worker、不移动或创建目录：

```bash
./scripts/start-qr-login.sh --dry-run
```

Dry run 在获取锁前返回，因此不会创建或遗留
`/run/lock/cf-agent-wechat-qr-runtime.lock`。

### 重复与并发

- 重复执行会为每次现有 runtime 使用新的 UTC 时间戳归档，不覆盖旧归档。
- start/stop 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`；文件存在不等于锁正被
  持有，禁止仅因文件存在就删除它。
- 锁已被占用时，后启动的流程必须失败并保持现状，不得绕过锁。
- 上一次失败不妨碍后续重新执行，但失败产生的 runtime 和归档仍必须保留。

## 强制二维码参数

底层强制登录命令为：

```bash
./scripts/login.sh --force-qr
```

`--force-qr` 的约束：

- 登录 WebSocket 参数使用 `newAccount=true`，请求全新设备二维码。
- HTTP 响应或 WebSocket 事件必须在当前 SSH 终端实际渲染至少一个 QR；强制模式在未
  渲染 QR 时拒绝接受 `login_success`。二维码刷新时应扫描最后显示的一张。
- 等待 `qr`、`phone_confirm`、`login_success`、超时或错误事件。
- 当前认证状态若仍为 `logged_in`，不得短路成功，必须返回错误：

  ```text
  runtime is not clean; use start-qr-login.sh
  ```

- 不自动执行 UI logout，避免在失效状态下触发 `Unknown IAState`。
- 不删除 `data`、`wechat-home` 或其他用户数据。目录轮换只由
  `start-qr-login.sh` 在登录前完成。

生产运维不应单独运行无参数 `login.sh` 来恢复旧会话。若需要重新登录，应重新执行唯一
生产启动入口，让现有 runtime 先归档，再创建全新 runtime。

## SSH 扫码

建议使用宽度至少 80 列的 SSH 终端，并保持会话打开：

1. 运行 `start-qr-login.sh`。
2. 等待终端显示二维码。
3. 用手机微信扫描最新二维码，并按手机提示完成确认。
4. 等待脚本完成进程、认证、聊天和消息读取验证。
5. 看到最终状态确认 `Gateway WeChat Worker` 已启动后，再发送业务消息。

不要截屏、转发或保存二维码。扫码失败或超时时重新运行完整启动入口；不要启动第二个并发
流程，也不要尝试 UI logout。

## 状态检查

`scripts/status.sh` 至少输出：

| 项目 | 要求 |
| --- | --- |
| `Container` | 正式容器处于运行状态 |
| `Agent Server` | agent-server API 可访问 |
| `WeChat Process` | `/usr/bin/wechat` 真实进程存在 |
| `Auth` | `/api/status/auth` 返回 `logged_in` |
| `QR Runtime Mode` | 当前为轮换后的二维码 runtime |
| `Message API` | `/api/chats` 可读 |
| `Gateway WeChat Worker` | 显示 worker 当前状态 |

生产可用至少要求 WeChat 进程存在、`Auth` 为 `logged_in` 且 `/api/chats` 可读。
进程不存在或 chats API 无法读取时，`status.sh` 必须非零退出。账号字段和聊天 ID 不得
出现在状态输出中。

`logged_in` 不能单独作为成功结论。启动流程的放行条件更严格：聊天列表必须至少有一个
聊天，且对其中一个 API 返回的聊天执行消息读取不能报错。

## Token 安全模型

Token 始终使用独立只读挂载：

```text
/srv/storage/cf-agent-wechat/secrets/auth-token -> /data/auth-token
```

生产权限必须保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

安全要求：

- Token 不得进入 `runtime` 或 `session-archive`。
- 不得写入命令行参数、环境变量、manifest、日志、工单或截图。
- 不得打印 Token 实值、摘要或指纹。
- 禁止改为全局可读、复制到普通用户目录或用符号链接替换。
- 脚本只在内存中使用 Token 构造认证请求，错误输出必须脱敏。

## Python venv

二维码渲染和 WebSocket 辅助程序使用普通用户 venv，默认位置：

```text
~/.local/share/cf-agent-wechat/venv
```

首次需要登录时按 `scripts/requirements.txt` 创建或检查依赖。不要使用 sudo 安装
Python 包，也不要修改系统 Python。可用 `CF_AGENT_WECHAT_VENV` 覆盖路径。

## 退出语义

### `status.sh`

- 返回 `0`：WeChat 进程存在、认证为 `logged_in`，并且 chats API 可读。
- 返回非零：容器、agent-server、WeChat 进程、认证或消息 API 任一条件不满足。
- `logged_out` 表示需要重新执行完整启动入口，不代表服务可投入生产。

### `login.sh --force-qr`

- 返回 `0`：全新二维码流程收到成功事件并确认认证为 `logged_in`。
- 返回非零：runtime 不干净、配置或依赖失败、进程未运行、API/WebSocket 失败、超时、
  取消或登录后认证复核失败。
- 即使该命令返回 `0`，仍由 `start-qr-login.sh` 完成 chats/messages 验证和 worker
  放行。

### `start-qr-login.sh`

- 返回 `0`：完整登录和运行时验证通过，`wechat-worker` 已启动。
- 返回非零：任一准备、归档、启动、登录或验证步骤失败；worker 保持停止。

登录后 API 不是单次抢跑检查；启动脚本会按 `RUNTIME_POLL_INTERVAL` 轮询，最长等待
`POST_LOGIN_READY_TIMEOUT`（默认 120 秒），超时后才失败。

## 常见错误

### `runtime is not clean`

全新 runtime 仍报告 `logged_in`。不要执行 UI logout，也不要手工删除数据。确认当前
流程退出后重新运行：

```bash
./scripts/start-qr-login.sh
```

### Mixed 新旧布局

`runtime` 与 `${STORAGE_ROOT}/data` 或 `${STORAGE_ROOT}/wechat-home` 同时存在时，脚本
拒绝修改任一布局。不要手工合并或删除；先保留现场并确认哪套目录是受控来源。

### WeChat 进程不存在

`/usr/bin/wechat` 不存在或无法稳定存活时，登录流程必须失败。保留归档和脱敏日志，检查
镜像、Xvfb、窗口管理器、资源限制及容器日志；worker 必须继续停止。

### Auth 为 `logged_in` 但 chats 不可读

这是失效或假登录态，不是生产可用。不要启动 worker，不要仅凭认证状态宣告成功。保留
现场并重新执行全新 runtime 登录流程。

### chats 可读但 messages 读取失败

启动验证未闭环，`wechat-worker` 不得启动。只记录接口结果类别和返回码，不记录聊天
ID 或正文。

### 登录超时或扫码失败

等待当前流程释放锁后重新运行 `start-qr-login.sh`。不要复用屏幕上的旧二维码，不要
并行运行两个登录流程。失败归档不得删除。

## 配置覆盖

登录工具支持的既有 URL、超时、Python 和终端宽度覆盖仍可用于受控测试。生产环境不得
通过覆盖变量绕过以下约束：`newAccount=true`、全新 runtime、独占锁、完整 API 验证、
Token 独立挂载和 worker 放行门槛。

6174 只保持既有受控绑定，并通过 `cf-internal` 供 Gateway 访问；不得新增公网端口。

## 实机验证边界

2026-08-13 验证的是旧基线上的已信任设备手机确认，不是本次强制全新二维码流程的证据。
“全新 runtime -> SSH 二维码 -> 手机扫码 -> WeChat 进程稳定 -> auth/chats/messages
验证 -> worker 启动”仍需在 CFserver 实机完成。

本仓库只能在脚本运行后停止并复核 worker，不能配置 Gateway 的 boot/restart 行为。
必须另行实机确认 Debian 启动到人工运行脚本之前 `wechat-worker` 持续停止；未确认前
不能宣称启动窗口已被本仓库保证。

实机记录必须脱敏，不得包含二维码、Token、账号、联系人、聊天 ID、聊天正文、服务器
地址或数据库内容。详细状态见 [验证总览](validation.md)。
