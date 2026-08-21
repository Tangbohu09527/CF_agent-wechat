# 微信登录管理

> [!WARNING]
> 本文 forced-QR 流程仅适用于 `feat/forced-qr-login@9cb7163` 及其后续合入版本。
> 本文审计的 `main` 代码基线 `96264e2` 没有 `--force-qr` 和 runtime 生命周期入口，不得按本文执行。
> 该实现已完成自动化验证，但 CFserver 真实手机扫码闭环仍为未验证。

## 适用范围

本文说明 CFserver forced-QR 目标基线的全新二维码登录流程。该目标基线不恢复旧微信会话；
每次 Debian 重启、容器重建或人工重新启动微信入口，都必须通过 SSH 运行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

这是 forced-QR 目标基线的唯一启动入口。`scripts/login.sh --force-qr` 是该入口调用的底层登录步骤，不是
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
   `${STORAGE_ROOT}/data`、`${STORAGE_ROOT}/wechat-home` 旧布局时，将实际存在的目录
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

脚本只有在全部验证成功后才主动启动 worker。确认初始 stop 后发生失败时，cleanup 会
再次停止并确认；初始 stop 或 cleanup stop 任一无法确认，worker 状态都按未知处理，
不能声称本仓已阻断 AI 调度。当前或历史归档均不删除。

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

## 登录失败恢复流程

先按失败阶段判断，不要直接重启主机或手工启动 worker：

| 失败阶段 | 现场状态 | 恢复动作 |
| --- | --- | --- |
| 配置、Token 元数据、外部控制路径或 dry run 失败 | 尚未取得运行锁，也未改变容器和目录 | 修复明确错误，再次执行 dry run |
| 独占锁失败 | 另一个 start/stop 可能运行中 | 确认活动 SSH 会话，等待其退出；不要删除或绕过锁 |
| QR helper、venv 或依赖准备失败 | 已取得锁但尚未停止 worker；容器和 runtime 不变，venv 可能已写入 | 等脚本退出并释放锁；以普通用户修复 helper、Python、venv 所有权或依赖，再运行完整入口 |
| worker 初始停止无法确认 | worker 状态未知，入口尚不应轮换 | 将调度视为仍可能活跃，先由责任人停止并确认，再重试 |
| Token 内容读取失败 | 初始 worker stop 已确认，容器和目录尚未轮换；最终以 cleanup 报告为准 | 恢复受控 Token 文件及严格权限，不输出其内容；再运行完整入口 |
| 归档或新 runtime 创建失败 | 初始 worker stop 已确认；现场和已产生归档必须保留，最终以 cleanup 报告为准 | 检查同文件系统、mixed layout、目标唯一性和权限；修复后运行完整入口 |
| QR 未显示、过期或扫码超时 | 脚本不会放行 worker；本次 runtime 保留，最终以 cleanup 报告为准 | 等脚本退出和释放锁，扫描时只用最新 QR；重新运行完整入口 |
| `login_success` 后 auth/chats/messages 失败 | 不能视为生产可用，worker 不应放行 | 保留脱敏日志；已建立归档时检查 manifest，否则记录 `Archive path: not created`；再检查 WeChat 进程与 API |
| 失败 cleanup 的 stop/remove 未确认 | 可能残留可被 Docker 恢复的入口容器 | 不重启 Docker/Debian；人工核验并处置残留，再开始下一次流程 |

恢复的共同终点始终是：

```bash
./scripts/start-qr-login.sh --dry-run
./scripts/start-qr-login.sh
./scripts/status.sh
```

只有最终状态确认进程、auth、chats、messages 和 worker 放行顺序都满足要求，才能恢复
业务消息。详细症状见[故障排查](troubleshooting.md)。

## 状态检查

`scripts/status.sh` 至少输出：

| 项目 | 判读 |
| --- | --- |
| `Container` | 返回 `0` 要求正式容器处于运行状态 |
| `Agent Server` | 显示 `/health` 探测结果；该展示项不独立决定退出码 |
| `WeChat Process` | 返回 `0` 要求 canonical executable 对应的同一进程身份稳定 |
| `Auth` | `/api/status/auth` 返回 `logged_in` |
| `QR Runtime Mode` | 返回 `0` 要求为 `fresh` |
| `Message API` | 返回 `0` 要求 `/api/chats` 可读；列表可以为空 |
| `Gateway WeChat Worker` | 状态查询必须成功；显示为 stopped 时 `status.sh` 仍可能返回 `0` |

`status.sh` 返回 `0` 只证明下节列出的状态查询与入口读取门槛通过。完成启动后的
生产判读还必须确认第七项 worker 为 running，并确认本次 `start-qr-login.sh` 已完成
非空 chats 和 messages 放行验证。账号字段和聊天 ID 不得出现在状态输出中。

`logged_in` 不能单独作为成功结论。空 chats 列表可以通过 `status.sh` 的“可读”
检查，却不能通过启动放行门槛。

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

- 返回 `0`：配置和必要命令可用；容器与 worker 状态查询成功；Token 可安全读取；
  容器为 running；forced-QR mounts 判定为 fresh；WeChat 进程身份稳定；auth 为
  `logged_in`；chats API 可读。
- 返回 `1`：配置、必要命令、容器/worker 查询、Token 或 chats API 检查失败。
- 返回 `2`：auth 为 `logged_out`，需要重新执行完整启动入口。
- 返回 `3`：WeChat 进程、容器运行态、fresh mounts 或其他 auth 状态不满足。
- `Agent Server` 的 `/health` 结果仅用于展示，不独立决定退出码；仍应排查
  `unavailable`。
- worker 状态必须可查询，但不要求为 running；即使返回 `0`，也必须查看第七项。
- `status.sh` 不验证 chats 非空，也不读取 messages；这两项由启动脚本验证。

### `login.sh --force-qr`

- 返回 `0`：全新二维码流程收到成功事件并确认认证为 `logged_in`。
- 返回非零：runtime 不干净、配置或依赖失败、进程未运行、API/WebSocket 失败、超时、
  取消或登录后认证复核失败。
- 即使该命令返回 `0`，仍由 `start-qr-login.sh` 完成 chats/messages 验证和 worker
  放行。

### `start-qr-login.sh`

- 返回 `0`：完整登录和运行时验证通过，`wechat-worker` 已启动。
- 返回非零：任一准备、停止、归档、启动、登录或验证步骤失败。配置或锁失败时保持原
  状态；初始 worker stop 无法确认时 worker 状态未知；只有已确认初始 stop，且后续
  cleanup 未报告 worker stop 失败时，才能认定 worker 保持停止。

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
