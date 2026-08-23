# 微信登录管理

## 适用范围

本文说明 CFserver 生产环境的强制全新二维码登录流程。生产环境不再恢复旧微信会话；
每次 Debian 重启、容器重建或人工重新启动微信入口，都必须通过 SSH 运行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

这是唯一生产启动入口。`scripts/login.sh` 只是无条件 `exec` 到该入口的兼容包装，
不提供独立登录、诊断或恢复语义。VNC、noVNC、RDP、宿主桌面和 UI logout 都不属于
当前流程。

首次部署时先运行 `sudo ./scripts/bootstrap-cfserver.sh`。已运行环境的部署输入变化时，
必须先用 `./scripts/stop-qr-runtime.sh` 受控停止并确认 Agent/Worker 均已停止，再运行
Bootstrap。Bootstrap 只完成基础准备，不创建或恢复微信 session，不启动
`agent-wechat` 或 `wechat-worker`。扫码入口必须由人工在受控 SSH TTY 单独运行。

## 启动编排

`start-qr-login.sh` 按固定顺序执行：

1. 校验 TTY，拒绝生产管理环境覆盖，安全读取固定 `docker/.env`；API/WS 只从批准
   loopback/port 派生，Token path/session 固定。
2. 重新核验 systemd/Docker/auto-start unit、Gateway contract/Token、clean Compose
   精确渲染、现有 Runtime 精确权限和有界 no-follow 树扫描。
3. 获取 owner/management GID/mode/link 合规的 `0640` 独占锁。
4. 停止并确认 Gateway `worker` service。
5. 检查 Archive bytes/percent/inode，输出 inventory，并验证固定 Python/Hash lock/venv；
   失败时 Worker 保持停止，Archive 和 Agent 不变更。
6. 受控读取 root-only Token。
7. 停止并删除旧 Agent 容器，不执行 `docker compose down`；原子归档当前 Runtime，
   或把 legacy `data`/`wechat-home` 迁入同一个 UTC Archive。
8. 始终按批准非 root UID/GID/mode 创建全新 `runtime/data` 与 `runtime/wechat-home`，
   不继承旧目录漂移。
9. 以 `restart=no` 创建 Agent，并精确 attest 实际 image/project/name、RestartPolicy、
   mount、loopback port、alias 和 environment。
10. 等待 container/health/API 与 `/usr/bin/wechat` canonical `PID:start_time` 稳定。
11. 以 `newAccount=true` 请求 fresh QR；当前 SSH TTY 必须实际渲染后才接受成功事件。
12. 在有界窗口验证同一进程、auth=`logged_in`、chats 非空和 messages。
13. 只有全部通过才启动 Gateway `worker`；contract checker 对当前实例、Docker health、
    heartbeat、最新 Poll Cycle 和 auth 持续无输出地通过，才输出最终状态。

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
- start/stop/retention 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`；锁必须为空、
  非 symlink、单 hardlink，精确使用批准 owner、management GID 和 mode `0640`。
  文件存在不等于锁正被持有，禁止仅因存在就删除它。
- 锁已被占用时，后启动的流程必须失败并保持现状，不得绕过锁。
- 上一次失败不妨碍后续重新执行，但失败产生的 runtime 和归档仍必须保留。

## Fresh QR 协议

`start-qr-login.sh` 自身执行二维码请求与事件监听，并遵守：

- 登录 WebSocket 参数使用 `newAccount=true`，请求全新设备二维码。
- HTTP 响应或 WebSocket 事件必须在当前 SSH 终端实际渲染至少一个 QR；强制模式在未
  渲染 QR 时拒绝接受 `login_success`。二维码刷新时应扫描最后显示的一张。
- 等待 `qr`、`phone_confirm`、`login_success`、超时或错误事件。
- 当前认证状态若仍为 `logged_in`，不得短路成功，必须返回错误：

  ```text
  runtime is not clean; use start-qr-login.sh
  ```

- 不自动执行 UI logout，避免在失效状态下触发 `Unknown IAState`。
- 不删除 `data`、`wechat-home` 或其他用户数据。目录轮换由同一
  `start-qr-login.sh` 生命周期在二维码请求前完成。

`login.sh` 不接受另一套生产协议；它把参数原样交给唯一入口，因此未知参数仍由
`start-qr-login.sh` 拒绝。若需要重新登录，应重新执行唯一生产启动入口，让现有
runtime 先归档，再创建全新 runtime。

## Archive 前置门禁

扫码流程先停止并确认 Worker，再在归档和显示 QR 前检查 Archive bytes/percent/inode、
输出脱敏 inventory，并验证 schema/路径/文件类型安全。失败时 Worker 保持停止。
Manifest schema v2 只保证 manifest 自身
不写实际标识；Archive payload 仍可能含完整 session、账号/聊天标识和消息数据，整体为
`restricted`。Retention 默认 dry-run，不自动删除。见
[Archive Management Contract](archive-management.md)。
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

Compose healthcheck 只证明容器和 Agent API 可访问，不证明微信登录、chats/messages
可读、Gateway 可达或 Worker heartbeat 正常。

Gateway checker 必须由 contract v1 兼容 commit 部署，以管理用户在 10 秒内无输出执行；
stale、Poll 失败、auth 失败、超时、非零或输出任何内容都会停止/撤销 `worker` 放行。
当前 Gateway PR #4 尚不兼容，因此长期目标状态为 **BLOCKED BY GATEWAY CONTRACT**。
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

- Token 是 Agent/Gateway 唯一权威 credential，不得进入 Runtime 或 Archive。
- 不得写入 argv、process environment、Docker inspect、Compose config、manifest、
  日志、错误、工单、截图或 CI。
- Gateway 生产配置必须使用固定 file pointer 和唯一只读 Token bind，不得保留明文
  `CF_AGENT_WECHAT_TOKEN`。独立 legacy migration audit 即使常量时间比较相同也不放行；
  它不 source/eval、不输出任一值/Hash/长度，也不自动同步。
- 不得打印 Token 实值、摘要或指纹。
- 禁止改为全局可读、增加 hardlink、复制到普通用户目录或用 symlink 替换。
- 脚本只在当前进程内存中使用 Token 构造认证请求，错误输出必须脱敏。

## Python venv

生产二维码渲染和 WebSocket 辅助程序固定使用 `/usr/bin/python3`、仓库内
`scripts/requirements.txt`，以及根据当前管理用户 passwd home 派生的：

```text
<passwd-home>/.local/share/cf-agent-wechat/venv
```

生产不读取 `HOME`/`XDG_DATA_HOME` 来重定向 venv，并明确拒绝 `PYTHON_BIN`、
`REQUIREMENTS_FILE`、`VENV_DIR` 和 `CF_AGENT_WECHAT_VENV`；生产不支持任何 venv 路径
覆盖。显式 `CF_AGENT_WECHAT_TESTING=1` 只属于隔离测试门禁，不是生产运行方式。
Bootstrap 会验证系统解释器为普通 GIL-enabled CPython 3.10-3.14，真实创建临时 venv，
并在隔离环境中验证该 venv 的 GIL、ensurepip 和 pip 可运行；free-threaded CPython 不在
当前 Pillow/QR 依赖合同内，必须 fail closed。
每次生产启动还会在创建目录、移动旧 venv 或运行 pip 前重新执行同一 runtime gate。
free-threaded、非 CPython 或不支持的 Python 版本必须在任何依赖状态变更和网络访问前
fail closed。

`scripts/requirements.txt` 使用 SHA-256 hash 锁和 binary-only wheel。
`ensure-login-environment.sh` 在 clean environment 中以 no-input、禁用版本检查、
有界下载 timeout/retry 和整体 hard timeout 安装。venv 内的受保护 stamp 记录依赖合同；
当前 stamp schema 为 v3，除 lock、RECORD 和完整树 digest 外还固定
`python_gil=enabled`。已安装包与合同精确一致时快速复用。只有旧 venv 的 owner/mode、
单链接普通文件/目录、解释器链接和完整树结构先通过安全审计，而 lock/RECORD/stamp
发生漂移时，才允许事务式移走、重建并在安装失败时恢复原环境；如果结构审计本身无法
证明安全，工具不会移动或自动删除该树，而是原位保留并要求管理员先隔离后重试。
系统 Python minor 升级后，旧 `bin/python3.<minor>` 只有在最终解析到当前批准 base
Python 时才允许通过“可安全移动”审计；它不能通过当前环境的严格验证，因此会进入
受控重建。

新 stamp 原子安装后即为事务提交点，旧 `.previous.<pid>` 清理属于 post-commit 工作。
若该清理失败，已验证的新 venv 保持生效，受限旧树保留为人工隔离证据并返回非零；不得
把部分清理的旧树恢复到新环境之上。
启动脚本先停止并确认 Worker，才准备登录 venv；依赖准备失败发生在 Agent 容器、Archive
和 QR 变更前，Worker 保持停止。不要使用 sudo 安装 Python 包，不要修改系统 Python，
也不要向 pip 传递含凭证的代理。

## 退出语义

### `status.sh`

- 返回 `0`：WeChat 进程存在、认证为 `logged_in`，并且 chats API 可读。
- 返回非零：容器、agent-server、WeChat 进程、认证或消息 API 任一条件不满足。
- `logged_out` 表示需要重新执行完整启动入口，不代表服务可投入生产。

### `start-qr-login.sh`

- 返回 `0`：完整登录和运行时验证通过，`wechat-worker` 已启动。
- 返回非零：任一准备、归档、启动、登录或验证步骤失败；worker 保持停止。
- `login.sh` 兼容包装无条件 `exec` 到这里，因此没有独立退出语义。

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

生产 start/status/stop/login 拒绝调用环境中的 `API_URL`、`WS_URL`、Token/session、
Agent/Compose、Proxy、Python/requirements/venv、Runtime/Archive、锁和 Gateway 管理
变量，并在任何 curl/WebSocket、Worker、Archive 或 QR 变更前返回。不能用“正确值”
覆盖；必须清除变量，让固定路径和受保护 `docker/.env` 成为唯一输入。

只有显式 `CF_AGENT_WECHAT_TESTING=1` 的隔离测试可以使用 URL、Python、临时路径和
fake Docker/checker 覆盖。测试门禁不是生产诊断入口，也不能用于真实 Token。

6174 只绑定 loopback，并通过 `cf-internal` 固定 alias `cf-agent-wechat` 供
Gateway 访问；不得新增公网端口。
生产 Compose 必须保持 `restart: "no"`。进程 crash、Docker daemon 重启和 Debian
重启后均不得自动恢复 Agent；必须再次运行唯一入口并显示新二维码。

CFserver Host 使用 `Asia/Shanghai`，容器和日志使用 UTC。二维码只显示在当前 TTY，
archive manifest 和原始审计时间保持 UTC。

## 实机验证边界

2026-08-13 验证的是旧基线上的已信任设备手机确认，不是本次强制全新二维码流程的证据。
“全新 runtime -> SSH 二维码 -> 手机扫码 -> WeChat 进程稳定 -> auth/chats/messages
验证 -> worker 启动”仍需在 CFserver 实机完成。

本仓库只能在脚本运行后停止并复核 worker，不能配置 Gateway 的 boot/restart 行为。
必须另行实机确认 Debian 启动到人工运行脚本之前 `wechat-worker` 持续停止；未确认前
不能宣称启动窗口已被本仓库保证。

本仓库只协调 `wechat-worker`，不启停 `dispatch-worker` 或 `delivery-worker`，
不修改 Gateway、PostgreSQL、Checkpoint 或其他仓库。

实机记录必须脱敏，不得包含二维码、Token、账号、联系人、聊天 ID、聊天正文、服务器
地址或数据库内容。详细状态见 [验证总览](validation.md)。
