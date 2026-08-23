# CF_agent-wechat

CF_agent-wechat 是企业 AI 自动化体系的微信入口项目，负责运行 WeChat Linux
客户端与 agent-server，并向 Gateway 提供登录、聊天和消息接口。本项目不负责 AI
推理、Gateway 内部权限、Hermes 调度或企业业务逻辑。

> [!IMPORTANT]
> 生产环境不再恢复旧微信登录会话。每次 Debian 重启、容器重建或人工重新启动微信
> 入口，都必须在 SSH 终端完成一次全新二维码登录。旧运行状态只归档，不恢复为活跃
> 会话，也不自动删除。

## 唯一生产流程

生产部署分成两个明确阶段。首次部署先执行一次基础准备；已运行环境的部署输入发生
变化时，必须先运行 `./scripts/stop-qr-runtime.sh` 并确认 Agent/Worker 均已停止，再
执行基础准备：

```bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
```

Bootstrap 校验主机、仓库、固定系统工具、本机 rootful Docker socket、
`live-restore=false`、Compose、环境文件、目录、权限、Token、网络和 Gateway 边界，
准备管理目录、`cf-internal` 和独立 API Token，并渲染生产 Compose。
它不创建或恢复微信 session，不启动
`agent-wechat`，不启动 `wechat-worker`，也不表示微信已经登录或 Runtime 已上线。

每次需要启动生产 WeChat Runtime 时，只允许在受控 SSH TTY 中执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

CFserver 的 agent-wechat 标准 Compose 输入为：

- Compose：`/opt/cf-agent-wechat/docker/compose.cfserver.yaml`
- 环境文件：`/opt/cf-agent-wechat/docker/.env`
- Compose 项目目录：`/opt/cf-agent-wechat`

生命周期脚本显式通过 `--env-file` 使用上述 agent-wechat 环境文件，并保持仓库根目录为
Compose 项目目录。非标准部署可通过 `CF_AGENT_WECHAT_ENV_FILE` 覆盖环境文件路径。

CFserver 的 Gateway 标准布局为：

- Compose：`/opt/cf-agent-gateway/deploy/compose.yaml`
- 环境文件：`/opt/cf-agent-gateway/deploy/.env`
- Compose 项目目录：`/opt/cf-agent-gateway/deploy`
- heartbeat checker：`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`

在两套标准布局下，上述命令可直接运行，无需导出任何变量。非标准部署仍可通过
`CF_AGENT_GATEWAY_COMPOSE_FILE`、`CF_AGENT_GATEWAY_ENV_FILE` 和
`CF_AGENT_GATEWAY_PROJECT_DIR` 覆盖 Gateway 路径。管理脚本安全解析
`docker/.env` 的受支持键值，不执行任意 shell 内容，也不输出文件内容。Gateway
环境文件只校验路径和元数据，并通过 `--env-file` 交给 Docker Compose；脚本不解析、
复制或输出其内容。

heartbeat checker 是 Gateway 部署提供的固定、无参数、只读探针。本仓库只校验它是
无符号链接、无额外 hardlink、owner/mode 合规且可由当前管理用户直接执行的普通文件，
并以管理用户身份在 hard timeout 内运行；不创建、修改或通过 `sudo` 执行该文件。
checker 只有在当前 `wechat-worker` 的应用 heartbeat 可用时才返回 `0`，且不得输出
Token、消息内容或其他敏感值。

固定流程如下：

```text
Debian 启动
  -> agent-wechat 保持停止
  -> wechat-worker 由 Gateway boot stop gate 保持停止
  -> SSH 登录 CFserver
  -> 首次部署，或受控停止后的配置变化，运行 bootstrap-cfserver.sh
  -> Bootstrap 只完成基础准备
  -> ./scripts/start-qr-login.sh
  -> 停止 Gateway wechat-worker
  -> 归档旧 runtime，创建全新 data 和 wechat-home
  -> 启动 cf-agent-wechat
  -> SSH 终端显示全新二维码
  -> 手机扫码
  -> 自动验证进程、认证、聊天和消息 API
  -> 验证全部通过后启动 wechat-worker
  -> 确认 wechat-worker running/healthy/heartbeat
```

本仓库会在启动脚本开始变更 runtime 前停止并复核 `wechat-worker`，但不能修改或保证
Gateway 自身的重启策略。必须在 CFserver 实机确认：Debian 启动至人工执行脚本前，
`wechat-worker` 的 restart/boot stop gate 能让它持续停止。该现场门禁未验证前，不得
宣称重启窗口已经由本仓库保证安全。

在变更前预览动作：

```bash
./scripts/start-qr-login.sh --dry-run
```

start/stop 的 dry run 都在获取运行锁前返回，不创建或遗留
`/run/lock/cf-agent-wechat-qr-runtime.lock`。

停止微信运行态时使用：

```bash
./scripts/stop-qr-runtime.sh
```

该命令先停止 Gateway `wechat-worker`，再停止 `agent-wechat`，但不删除当前
`runtime`、Token 或任何历史归档。它同样支持 `--dry-run`。

不要用 `docker compose up`、`restart` 或 `down` 代替上述脚本。生产 Compose 必须为
`restart: "no"`。容器进程退出、Docker daemon 重启或 Debian 重启后都不得自动恢复
`agent-wechat`；下一次生产启动仍需运行 `start-qr-login.sh` 并扫描全新二维码。

## 生产可用判定

`logged_in` 只是一个认证信号，不能单独证明微信入口可用。`scripts/status.sh` 至少显示：

- `Container`
- `Agent Server`
- `WeChat Process`
- `Auth`
- `QR Runtime Mode`
- `Message API`
- `Gateway WeChat Worker`

只有 WeChat 真实进程存在、认证状态为 `logged_in`、`/api/chats` 可读时，状态检查才
返回生产可用。启动流程还会先确认正式容器 running、Docker health 和 Agent API，
确认 WeChat process 稳定，再显示二维码；扫码后确认聊天列表至少包含一个聊天，并对
API 返回的一个聊天执行消息读取。登录后的 auth/chats/messages 会在有界的
`POST_LOGIN_READY_TIMEOUT` 内轮询；只有这些检查全部通过，才会启动 Gateway
`wechat-worker`，并确认其 running/healthy 和可用的 heartbeat 状态。

Compose healthcheck 只能证明容器内 Agent API 可访问，不能证明微信已经登录、
chats/messages 可读或 Gateway 链路可用。容器 `healthy` 不能替代上述完整放行门槛。

检查命令：

```bash
./scripts/status.sh
```

脚本不得输出微信账号或聊天 ID。worker 停止已确认后，后续任一步失败都会让它保持
停止，不启动 AI 调度，已有归档也不会被删除；若初始停止无法确认，脚本失败并明确
报告，不能声称 worker 已被本仓库阻断。

## 运行目录与归档

生产运行目录：

```text
/srv/storage/cf-agent-wechat/
├── runtime/
│   ├── data/                 # 挂载到 /data
│   └── wechat-home/          # 挂载到 /home/wechat
├── session-archive/
│   └── <UTC时间戳>/          # 上一次 runtime 与脱敏 manifest
└── secrets/
    └── auth-token            # 单独只读挂载到 /data/auth-token
```

可通过 `CF_AGENT_WECHAT_RUNTIME_ROOT` 覆盖 `runtime` 根目录；默认值为
`/srv/storage/cf-agent-wechat/runtime`。Token 不属于 runtime，不得复制进 runtime、
归档、日志、环境变量或命令行。旧 runtime 归档本身可能包含历史微信 session、缓存和
消息数据，必须保持 root-protected，只能用于受控审计或故障分析，绝不能挂回生产复用。

每次启动会将当前 runtime 原子移动到新的 UTC 时间戳目录，并记录不含敏感信息的
manifest，包括 schema version、启动与结束 UTC 时间、旧 runtime path、镜像 digest、
原目录 owner/mode 和归档结果。脚本不会删除任何历史归档；容量监控和经审批的保留期
由外部运维策略负责。

首次上线本模式时，如果只有旧布局 `${STORAGE_ROOT}/data` 和
`${STORAGE_ROOT}/wechat-home`，脚本会把两者迁入同一个 UTC 时间戳归档，再创建新
runtime。新 `runtime` 与任一旧目录同时存在属于 mixed layout，脚本在修改容器、worker
或目录前 fail-fast，不碰任一布局。

## 强制二维码登录

`scripts/start-qr-login.sh` 直接使用 `newAccount=true` 请求全新设备二维码并监听
登录事件；必须在当前 SSH 终端实际渲染至少一个可见 QR，才接受后续登录成功。如果全新
runtime 仍报告 `logged_in`，脚本必须失败并提示：

```text
runtime is not clean; use start-qr-login.sh
```

该路径不会自动执行 UI logout，也不会删除用户数据。`scripts/login.sh` 只是无条件
`exec` 到 `start-qr-login.sh` 的兼容包装，不提供第二套登录、诊断或 session 恢复
语义；生产 runbook 始终使用 `start-qr-login.sh`。

forced production 只接受能够在渲染前检查 Token 的文本 QR payload。PNG-only
`qrDataUrl` 内容无法在当前依赖下可靠审计，因此必须 fail closed；不得为了兼容 PNG
绕过 Token 检查、写入二维码文件或接受未显示 QR 的成功事件。

## 运行边界

- Gateway 和 Hermes 的上下文仍由各自数据库持久化；轮换微信 runtime 不修改这些
  数据库，也不修改其他仓库。
- 重启期间发送给机器人的消息可能不会被微信本地客户端补拉。必须等二维码登录和自动
  验证完成、`wechat-worker` 启动后，再发送业务消息。
- 6174 只绑定 loopback，并通过 `cf-internal` 固定 alias `cf-agent-wechat` 供
  Gateway 访问；不新增公网端口。
- VNC、noVNC、x11vnc、websockify、宿主 X11 和 RDP 均不在生产链路中；
  `ENABLE_VNC=0` 保持不变。
- `seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像运行要求，不是通用安全默认值；
  每次镜像升级都必须重新进行风险评估并持续审查其必要性。
- Bootstrap 固定使用系统 Docker CLI，并校验真实的非符号链接
  `/var/run/docker.sock`。Bootstrap 与生产启动都会校验 default context、
  `unix:///var/run/docker.sock` endpoint、本机 rootful daemon 和
  `live-restore=false`；Docker、Compose 与 API 调用都受硬超时约束。
- CFserver Host 使用 `Asia/Shanghai`；容器和日志使用 UTC。运维展示可以转换为
  `Asia/Shanghai`，但 archive manifest 和原始证据保留 UTC。

## 验证状态

2026-08-13 和 2026-08-14 的记录证明了当时基线上的容器、已信任设备登录和消息接口
能力，但不能证明本次“全新 runtime -> SSH 二维码 -> 完整 API 验证 -> worker 放行”
流程已经在 CFserver 闭环。

本次实现包含真实 Docker 的 `restart=no` 容器退出与 daemon restart E2E；最终证据以
新 PR 的绿色 GitHub Actions Run ID 为准。该 E2E 不会、也不能重启真实 Host，因此仍
必须在 CFserver 上进行真实 Host reboot 和一次真实手机扫码验证。
还必须验证 Debian 启动到人工运行脚本之前的 Gateway worker stop gate；本仓库没有修改
Gateway，因此不能提供该启动窗口的代码保证。
验证材料只能记录脱敏状态、时间和返回码，不得记录二维码、Token、账号、联系人、聊天
ID 或聊天正文。

## 文档入口

- [文档索引](docs/README.md)
- [部署指南](docs/deployment-guide.md)
- [CFserver 正式部署](docs/deployment/cfserver-production.md)
- [新设备 Bootstrap](docs/deployment/new-device-bootstrap.md)
- [强制二维码登录指南](docs/qr-login-guide.md)
- [恢复指南](docs/recovery-guide.md)
- [部署审计](docs/deployment-audit.md)
- [微信登录管理](docs/login-management.md)
- [API 边界](docs/api.md)
- [生产运维](docs/operations.md)
- [故障排查](docs/troubleshooting.md)
- [验证总览](docs/validation.md)
- [2026-08-13 CFserver 生产验证](docs/validation/2026-08-13-cfserver-production.md)
- [2026-08-14 消息与媒体生产验证](docs/validation/2026-08-14-message-media-production.md)

上游镜像项目为 [thisnick/agent-wechat](https://github.com/thisnick/agent-wechat)。上游源码
不属于本仓库；升级镜像前应独立确认许可、版本兼容性与回滚基线。
