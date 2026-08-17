# CF_agent-wechat

CF_agent-wechat 是企业 AI 自动化体系的微信入口项目，负责运行 WeChat Linux
客户端与 agent-server，并向 Gateway 提供登录、聊天和消息接口。本项目不负责 AI
推理、Gateway 内部权限、Hermes 调度或企业业务逻辑。

> [!IMPORTANT]
> 生产环境不再恢复旧微信登录会话。每次 Debian 重启、容器重建或人工重新启动微信
> 入口，都必须在 SSH 终端完成一次全新二维码登录。旧运行状态只归档，不恢复为活跃
> 会话，也不自动删除。

## 唯一生产流程

生产启动只允许使用：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

CFserver 的 Gateway 标准布局为：

- Compose：`/opt/cf-agent-gateway/deploy/compose.yaml`
- 环境文件：`/opt/cf-agent-gateway/deploy/.env`
- Compose 项目目录：`/opt/cf-agent-gateway/deploy`

在该标准布局下，上述命令可直接运行，无需导出任何变量。非标准部署仍可通过
`CF_AGENT_GATEWAY_COMPOSE_FILE`、`CF_AGENT_GATEWAY_ENV_FILE` 和
`CF_AGENT_GATEWAY_PROJECT_DIR` 覆盖 Gateway 路径。生命周期脚本不自行解析、
复制或输出环境文件内容；Docker Compose 通过 `--env-file` 将该文件作为插值/配置
输入使用。

固定流程如下：

```text
Debian 启动
  -> SSH 登录 CFserver
  -> ./scripts/start-qr-login.sh
  -> 停止 Gateway wechat-worker
  -> 归档旧 runtime，创建全新 data 和 wechat-home
  -> 启动 cf-agent-wechat
  -> SSH 终端显示全新二维码
  -> 手机扫码
  -> 自动验证进程、认证、聊天和消息 API
  -> 验证全部通过后启动 wechat-worker
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

不要用 `docker compose up`、`restart` 或 `down` 代替上述脚本。生产 Compose 的
`restart: on-failure:3` 只处理当前人工启动过程中的有限失败，不代表允许 Debian 重启后
自动恢复旧登录态。

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
返回生产可用。启动流程还会确认聊天列表至少包含一个聊天，并对 API 返回的一个聊天
执行消息读取。登录后的 auth/chats/messages 会在有界的
`POST_LOGIN_READY_TIMEOUT` 内轮询；只有这些检查全部通过，才会启动 Gateway
`wechat-worker`。

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
归档、日志、环境变量或命令行。

每次启动会将当前 runtime 原子移动到新的 UTC 时间戳目录，并记录不含敏感信息的
manifest，包括启动与结束时间以及原目录权限。脚本不会删除任何历史归档；容量监控和
经审批的保留期由外部运维策略负责。

首次上线本模式时，如果只有旧布局 `${STORAGE_ROOT}/data` 和
`${STORAGE_ROOT}/wechat-home`，脚本会把两者迁入同一个 UTC 时间戳归档，再创建新
runtime。新 `runtime` 与任一旧目录同时存在属于 mixed layout，脚本在修改容器、worker
或目录前 fail-fast，不碰任一布局。

## 强制二维码登录

`scripts/login.sh --force-qr` 是启动编排内部使用的强制登录路径。它使用
`newAccount=true` 请求全新设备二维码，并且必须在当前 SSH 终端实际渲染至少一个可见
QR，才接受后续登录成功。如果全新 runtime 仍报告 `logged_in`，脚本必须失败并提示：

```text
runtime is not clean; use start-qr-login.sh
```

该路径不会自动执行 UI logout，也不会删除用户数据。生产运维人员应运行
`start-qr-login.sh`，不应把普通 `login.sh` 当作会话恢复入口。

## 运行边界

- Gateway 和 Hermes 的上下文仍由各自数据库持久化；轮换微信 runtime 不修改这些
  数据库，也不修改其他仓库。
- 重启期间发送给机器人的消息可能不会被微信本地客户端补拉。必须等二维码登录和自动
  验证完成、`wechat-worker` 启动后，再发送业务消息。
- 6174 保持现有受控绑定和 `cf-internal` 网络访问，不新增公网端口。
- VNC、noVNC、x11vnc、websockify、宿主 X11 和 RDP 均不在生产链路中；
  `ENABLE_VNC=0` 保持不变。

## 验证状态

2026-08-13 和 2026-08-14 的记录证明了当时基线上的容器、已信任设备登录和消息接口
能力，但不能证明本次“全新 runtime -> SSH 二维码 -> 完整 API 验证 -> worker 放行”
流程已经在 CFserver 闭环。

本次实现完成自动化测试和静态检查后，仍必须在 CFserver 上进行一次真实手机扫码验证。
还必须验证 Debian 启动到人工运行脚本之前的 Gateway worker stop gate；本仓库没有修改
Gateway，因此不能提供该启动窗口的代码保证。
验证材料只能记录脱敏状态、时间和返回码，不得记录二维码、Token、账号、联系人、聊天
ID 或聊天正文。

## 文档入口

- [文档索引](docs/README.md)
- [CFserver 正式部署](docs/deployment/cfserver-production.md)
- [微信登录管理](docs/login-management.md)
- [API 边界](docs/api.md)
- [生产运维](docs/operations.md)
- [故障排查](docs/troubleshooting.md)
- [验证总览](docs/validation.md)
- [2026-08-13 CFserver 生产验证](docs/validation/2026-08-13-cfserver-production.md)
- [2026-08-14 消息与媒体生产验证](docs/validation/2026-08-14-message-media-production.md)

上游镜像项目为 [thisnick/agent-wechat](https://github.com/thisnick/agent-wechat)。上游源码
不属于本仓库；升级镜像前应独立确认许可、版本兼容性与回滚基线。
