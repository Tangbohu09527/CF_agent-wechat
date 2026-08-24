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
Compose 项目目录。生产生命周期不接受调用进程通过 `CF_AGENT_WECHAT_ENV_FILE` 或其他
管理变量替换这些输入；非标准路径只属于显式 `CF_AGENT_WECHAT_TESTING=1` 的隔离测试。

CFserver 的 Gateway 标准布局为：

- Compose：`/opt/cf-agent-gateway/docker-compose.prod.yml`
- 环境文件：`/opt/cf-agent-gateway/.env`
- Compose 项目目录：`/opt/cf-agent-gateway`
- Compose 项目名：`cf-agent-gateway`
- Compose profile/service：`worker` / `worker`（角色名为 WeChat worker）
- 版本化合同：`/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json`
- heartbeat checker：`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`

在两套固定布局下，上述命令可直接运行，无需也不得导出管理变量。生产入口拒绝
`API_URL`、`WS_URL`、Token/session、Agent/Compose、Proxy、Runtime/Archive 和 Gateway
路径等调用环境覆盖；只安全解析受保护的 `docker/.env` 白名单字面值，不 source、eval
或输出文件内容。Agent HTTP 与 WebSocket 地址只由其中已验证的
`127.0.0.1:<AGENT_WECHAT_PORT>` 派生，`SESSION_ID` 固定为 `default`，Token 路径固定为
`/srv/storage/cf-agent-wechat/secrets/auth-token`。Compose 调用先清除宿主同名变量，再只
注入已批准值，并精确核验 project、image、container、port、mount、network alias、
`PROXY`、`RUST_LOG` 和 `restart=no`；宿主环境不能把 Token 重定向到远端或操作错误项目。

heartbeat checker 是 Gateway 部署提供的固定、无参数、只读探针。本仓库只校验它是
无符号链接、无额外 hardlink、owner/mode 合规且可由当前管理用户直接执行的普通文件，
并以管理用户身份在 hard timeout 内运行；不创建、修改或通过 `sudo` 执行该文件。
每次探测都会 no-follow 读取稳定内容、匹配批准摘要，再从只读密封快照执行；不会在
provenance 后按可替换路径二次执行。checker 的工作目录固定为 Gateway 项目根，不得
通过 `$0` 或 `BASH_SOURCE` 重新读取自身或定位资源。checker 必须在 10 秒 hard
timeout 内确认当前 `worker` 实例 running、Docker health 正常、heartbeat 不超过
30 秒、最新 Poll Cycle 成功且 WeChat auth 为 `logged_in`，才返回 `0`；
stdout/stderr 必须为空。Token、账号、消息内容或其他敏感值都不得输出。
当前 Gateway PR #4 尚未发布兼容 contract/checker，长期目标仍为
**BLOCKED BY GATEWAY CONTRACT**；不得用手工或 fake checker 代替，详见
[Gateway-WeChat Runtime Contract v1](docs/contracts/gateway-wechat-runtime-contract.md)。

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

本仓库会在 Archive、Agent start、QR、运行态验证和最终 Worker release 边界重复用
Compose 状态与精确 Docker labels 证明 `wechat-worker` stopped。QR WebSocket 等待期间
主流程也会轮询；发现外部启动时立即停止 Worker、终止本次登录并 fail closed。

这些检查只能检测并撤销本仓库取得控制后的并发启动，不能原子禁止 Gateway、外部
supervisor 或另一名管理员在两个检查之间启动 Worker。Contract v1 的
`bootPolicy=manual-after-fresh-qr` 因此要求 Gateway producer 提供绑定同一 fresh
runtime generation 的 generation/release gate：默认拒绝启动，只有当前扫码和
auth/chats/messages 全部验证后才能释放，旧 release 不能授权下一轮。该 producer gate、
Gateway restart 策略和 Debian boot stop 证据未发布前，不得宣称启动窗口安全。

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
│   └── <UTC时间戳>/          # 完整旧 runtime 与 schema v2 manifest
└── secrets/
    └── auth-token            # 单独只读挂载到 /data/auth-token
```

生产 `runtime`、Archive 和 Token 路径固定为上述布局，不能通过调用进程环境覆盖。
`docker/.env` 必须明确给出批准的非 root Runtime UID/GID/mode；默认合同为
`1000:1000/700`。每次 fresh QR 都会精确检查现有 runtime、legacy `data` 和
`wechat-home`；`root:root 700`、`1000:1000 755`、group/other writable、
symlink、额外 hardlink 或特殊文件均 fail closed。新 Runtime 始终按批准值创建，不继承
漂移权限。

Token 不属于 runtime，不得复制进 runtime、归档、日志、环境变量、argv、Docker inspect
或 Compose config。归档前的有界 no-follow 扫描不跟随 symlink、不跨文件系统，拒绝
FIFO、socket、device 等特殊文件；扫描同时检查普通文件内容和每个目录项名称的原始
文件系统字节，并拒绝任何 xattr/POSIX ACL，避免 Token 随 metadata 进入 Archive。
`docker/.env` 的扫描上限不得超过 200,000 个 entry；扫描器另有不可配置的 200,000
entry attestation 上限和 64 MiB 累计编码相对路径上限，并同时限制普通文件总字节与
扫描时间。扫描失败或命中当前独立 Agent Token 都在归档和二维码之前 fail closed。
最终重验依赖 Agent 容器已停止且部署 principal 受信；它不声称能抵御在最后一次检查后
仍可写 Runtime 的同权限或 root 写入者，该项必须由 CFserver 权限与进程 inventory 证明。

每次启动在取得管理锁后先停止并确认 Gateway `worker` service，再校验 Archive 可用
bytes、百分比和 inode，并输出脱敏 inventory；任一阈值不满足时 Worker 保持停止，且
不移动目录、不显示二维码。通过后才把旧 runtime 原子移动到 UTC 目录。Manifest schema
v2 把“manifest 本身不含标识”与
“payload 可能含完整 session、账号/聊天标识和消息数据”明确分开；整个 Archive 均为
`restricted` 资产，绝不能挂回生产复用。脚本不会自动删除 Archive；独立 retention
工具默认 dry-run，实际删除必须明确 Archive、审批、TTY 二次确认和 `0600` 审计记录。
完整合同、inventory/retention 命令与 schema v1 兼容规则见
[Archive Management Contract](docs/archive-management.md)。

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
  `/var/run/docker.sock`。Bootstrap 与每次生产启动都会重新校验 systemd、
  `docker.service`、default context、`unix:///var/run/docker.sock` endpoint、本机
  rootful daemon、`live-restore=false`、未启用的 `cf-agent-wechat.service`/同类
  auto-start unit 和渲染的 `restart=no`；创建后还精确检查实际容器 image、project、
  name、RestartPolicy、mount、loopback port、network alias 和环境。
- systemd 扫描枚举 enabled/linked 与 active service/timer/path/socket/target，并检查
  timer/path/socket 的直接 activation target 及 target 的一跳 `Wants`/`Requires`。
  它不递归证明任意深度依赖，也不覆盖 cron、Swarm、Kubernetes、外部配置管理或人工
  `docker start/run`；这些启动源仍属于 CFserver 人工 inventory pending。
- `PROXY` 只允许空值或 `http`/`https`/`socks5`/`socks5h` 的无凭证
  `scheme://host:port`；userinfo、path、query、fragment 和控制字符全部拒绝。当前不
  支持认证代理，代理密码不得进入普通环境或 `docker inspect`。
- QR Python 环境使用 SHA-256 hash 锁和 binary-only wheel，安装使用 clean environment、
  no-input、禁用版本检查、有界网络 timeout/retry 及整体 hard timeout。已安装依赖与
  lock digest 合同时快速复用，否则事务式重建。启动流程先停止并确认 Worker，再做
  容量/inventory 和 venv 准备；依赖失败仍发生在 Agent 容器、Archive 和 QR 变更前，
  Worker 保持停止。依赖 helper 会快照 Python、venv、lock 和 verifier 的全部现存祖先
  device/inode/owner/group/mode/type，并在创建、pip、验证、stamp、cleanup 与 rollback
  前后重验；祖先漂移时停止路径操作并保留受限现场。
- start/stop/retention 共用 root-protected 管理锁；文件精确为批准 owner、
  `CF_AGENT_WECHAT_MANAGEMENT_GID`、mode `0640`、单 hardlink、非 symlink 且为空。
  flock 随进程退出释放，普通非管理用户不能持锁。
- CFserver Host 使用 `Asia/Shanghai`；容器和日志使用 UTC。运维展示可以转换为
  `Asia/Shanghai`，但 archive manifest 和原始证据保留 UTC。

## 验证状态

2026-08-13 和 2026-08-14 的记录证明了当时基线上的容器、已信任设备登录和消息接口
能力，但不能证明本次“全新 runtime -> SSH 二维码 -> 完整 API 验证 -> worker 放行”
流程已经在 CFserver 闭环。

本次实现包含 `restart=no Docker policy fixture`：它在 GitHub Actions 的真实 Docker
daemon 上用一次性 Alpine/Nginx 容器验证正常退出、异常退出和 daemon restart 后均不
自动恢复。它不运行实际 agent-wechat 镜像、WeChat 进程或真实二维码链路，也不执行
Host reboot；这些项目仍必须在 CFserver 用真实手机完成现场验证。
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
- [Gateway-WeChat Runtime Contract v1](docs/contracts/gateway-wechat-runtime-contract.md)
- [Archive Management Contract](docs/archive-management.md)
- [微信登录管理](docs/login-management.md)
- [API 边界](docs/api.md)
- [生产运维](docs/operations.md)
- [故障排查](docs/troubleshooting.md)
- [验证总览](docs/validation.md)
- [2026-08-13 CFserver 生产验证](docs/validation/2026-08-13-cfserver-production.md)
- [2026-08-14 消息与媒体生产验证](docs/validation/2026-08-14-message-media-production.md)

上游镜像项目为 [thisnick/agent-wechat](https://github.com/thisnick/agent-wechat)。上游源码
不属于本仓库；升级镜像前应独立确认许可、版本兼容性与回滚基线。
