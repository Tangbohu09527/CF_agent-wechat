# CFserver 生产运维

## 适用范围

本文只适用于 CFserver 上 `CF_agent-wechat` 的正式部署：

- 工作目录：`/opt/cf-agent-wechat`
- 正式 Compose：`docker/compose.cfserver.yaml`
- 正式环境文件：`docker/.env`
- 容器：`cf-agent-wechat`
- Docker 网络：`cf-internal`
- 显示环境：`DISPLAY=:99`，`ENABLE_VNC=0`
- Bootstrap：`sudo ./scripts/bootstrap-cfserver.sh`，只做基础准备
- 唯一启动入口：`./scripts/start-qr-login.sh`
- 停止入口：`./scripts/stop-qr-runtime.sh`
- 容器重启策略：`restart: "no"`

agent-wechat 标准 Compose 输入为
`/opt/cf-agent-wechat/docker/compose.cfserver.yaml` 和
`/opt/cf-agent-wechat/docker/.env`，Compose 项目目录保持
`/opt/cf-agent-wechat`。生命周期脚本显式通过 `--env-file` 使用该文件；非标准
环境文件路径通过 `CF_AGENT_WECHAT_ENV_FILE` 覆盖。

Gateway 标准布局为 Compose
`/opt/cf-agent-gateway/deploy/compose.yaml`、环境文件
`/opt/cf-agent-gateway/deploy/.env`，Compose 项目目录为
`/opt/cf-agent-gateway/deploy`。使用该布局时，在
`/opt/cf-agent-wechat` 直接运行启动或停止脚本即可，无需导出变量。非标准布局
继续使用 `CF_AGENT_GATEWAY_COMPOSE_FILE`、
`CF_AGENT_GATEWAY_ENV_FILE` 和 `CF_AGENT_GATEWAY_PROJECT_DIR` 覆盖；
管理脚本安全解析 agent-wechat `docker/.env` 的受支持键值，不执行任意 shell
内容，也不输出文件内容。Gateway 环境文件只检查路径和元数据，通过 `--env-file`
交给 Docker Compose；脚本不解析、复制或输出其内容。
Gateway 固定 heartbeat checker 为
`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`。它由 Gateway 部署提供，
必须满足 owner/mode/symlink/hardlink 契约并可由管理用户直接执行。本仓库不创建、
修改或通过 `sudo` 执行 checker；它无参数运行，只以退出码报告当前 Worker 应用
heartbeat，且不输出敏感值。
start/stop 在任何容器、worker、runtime、归档或锁变更前，要求 agent-wechat 环境文件
路径为绝对路径，且为已存在的普通非符号链接文件。

`docker/docker-compose.yml` 是实验或验证配置，不得用于 CFserver。生产环境不再恢复旧
微信登录会话；每次 Debian 重启、容器重建或人工重新启动都需要 SSH 人工扫码。
CFserver Host 使用 `Asia/Shanghai`，容器和原始日志使用 UTC；显示时可以转换，
archive manifest 和原始审计证据保持 UTC。

## 日常检查

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  ps
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  logs --tail=200 agent-wechat
```

`status.sh` 至少显示 `Container`、`Agent Server`、`WeChat Process`、`Auth`、
`QR Runtime Mode`、`Message API` 和 `Gateway WeChat Worker`。只有以下条件同时满足，
才可把微信入口视为生产可用：

1. `/usr/bin/wechat` 真实进程存在。
2. `/api/status/auth` 返回 `logged_in`。
3. `/api/chats` 可以读取。

`logged_in` 单独出现不代表成功。启动脚本还会验证 chats 至少返回一个聊天，并对 API
返回的一个聊天执行消息读取；只有该检查也通过，才启动 `wechat-worker`。状态和日志
不得输出真实账号或聊天 ID。

Compose healthcheck 只证明容器和 Agent API 健康，不证明微信登录、chats/messages 或
Gateway 链路健康。

## 启动

### Bootstrap

首次部署时运行。已运行环境的 Compose、环境文件、目录、权限、Token、镜像 digest
等部署输入发生变化时，先运行 `./scripts/stop-qr-runtime.sh` 并确认 Agent/Worker 均已
停止，再运行：

```bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
```

Bootstrap 只准备基础部署，并验证固定系统工具、真实非符号链接 Docker socket、local
rootful daemon、`live-restore=false` 和 `restart: "no"`。它不创建或恢复微信
session，不启动 `agent-wechat`，不启动 `wechat-worker`，也不能被当作登录成功或
上线证据。配置失败后修复原因并安全重跑 Bootstrap。

### Dry run

先预览将要执行的动作：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh --dry-run
```

Dry run 不移动或创建目录，不停止或删除容器，不停止或启动 worker，并在获取锁前返回；
它不会创建或遗留 `/run/lock/cf-agent-wechat-qr-runtime.lock`。

### 正式启动

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

脚本将停止 `wechat-worker`、移除旧容器、原子归档当前或 legacy 运行目录、创建全新
runtime，并以 `restart: "no"` 启动容器。它先确认正式容器 running、Docker healthy、
Agent API 可用和 WeChat process 稳定，再要求在 SSH 终端实际渲染至少一个 QR。扫码
登录后，它在 `POST_LOGIN_READY_TIMEOUT` 有界时间内等待 auth/chats/messages 全部
可用，随后才启动 worker，并确认 running/healthy 和可用的 heartbeat 状态。

生产只接受能在渲染前检查 Token 的文本 QR payload。PNG-only `qrDataUrl` 必须
fail closed；不得为了兼容 PNG 绕过检查、写文件或接受未实际显示二维码的成功事件。

不要直接执行 `docker compose up`、`restart` 或 `down` 来代替此流程。Compose
必须为 `restart: "no"`，Docker 必须为 `live-restore=false`；进程 crash、Docker
daemon 重启和 Debian 重启都不会自动恢复 `agent-wechat`。

## 停止

```bash
cd /opt/cf-agent-wechat
./scripts/stop-qr-runtime.sh
```

停止脚本按顺序停止 Gateway `wechat-worker` 和 `agent-wechat`，但不删除：

- 当前 `runtime`；
- 独立 Token；
- 任何 `session-archive`；
- Gateway 或 Hermes 数据库内容。

预览停止动作：

```bash
./scripts/stop-qr-runtime.sh --dry-run
```

停止脚本的 dry run 同样在获取锁前返回，不创建或遗留锁文件。

不得执行 `docker compose down`。停止后再次投入生产必须重新运行
`start-qr-login.sh` 并扫码。

## Debian 重启后

本仓库没有修改 Gateway，不能保证 `wechat-worker` 在 Docker 或 Debian 启动时保持
停止。上线前必须在 CFserver 实机确认 Gateway 的 restart policy、Compose/systemd
启动方式或其他 boot stop gate，使 worker 从开机到人工运行登录脚本期间持续停止。
若该门禁未通过，不能宣称重启窗口安全，也不能仅依赖本脚本稍后执行 stop。

Debian 重启后，`restart: "no"` 要求 `agent-wechat` 保持停止，不得自动复用旧会话
并投入工作。运维人员必须：

1. SSH 登录 CFserver，并确认 boot stop gate 下 `wechat-worker` 仍为 stopped。
2. 进入 `/opt/cf-agent-wechat`。
3. 运行 `./scripts/start-qr-login.sh`。
4. 手机扫描 SSH 终端实际显示的全新二维码。
5. 等待脚本在有界时间内确认进程、auth、chats 和 messages。
6. 确认最终状态显示 `wechat-worker` 已启动。
7. 此后再开始发送业务消息。

重启期间发送给机器人的消息可能不会由微信本地客户端补拉，不得以旧消息仍可读取来判断
新运行时已经恢复。

## 重建与升级

正式镜像保持受控 digest，不使用 `latest`。重建、升级或回滚必须按顺序：

1. 在仍使用旧的已批准代码、Compose 和环境输入时运行
   `./scripts/stop-qr-runtime.sh`，确认 Agent/Worker 均已停止。
2. 再修改到新的已批准 Commit、Compose、环境输入或镜像 digest。
3. 使用新输入执行以下静态渲染和镜像拉取，不启动容器。
4. 运行 `sudo ./scripts/bootstrap-cfserver.sh`。
5. 在受控 SSH TTY 运行 `./scripts/start-qr-login.sh`，扫码并完成全部放行验证。

新输入下的静态检查：

```bash
cd /opt/cf-agent-wechat
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  config --quiet
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  pull agent-wechat
```

不要在拉取后直接用 `up -d --force-recreate` 投入工作；该命令会显式启动容器，
`restart: "no"` 不会拦截它。旧 runtime 只归档，不能恢复为活跃微信会话。

## Runtime 与 Token

生产挂载：

| 宿主路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `${CF_AGENT_WECHAT_RUNTIME_ROOT:-/srv/storage/cf-agent-wechat/runtime}/data` | `/data` | 本次 agent-server 数据 |
| `${CF_AGENT_WECHAT_RUNTIME_ROOT:-/srv/storage/cf-agent-wechat/runtime}/wechat-home` | `/home/wechat` | 本次微信 HOME |
| `/srv/storage/cf-agent-wechat/secrets/auth-token` | `/data/auth-token` | 独立只读 Token |

Token 不属于 runtime。不得把 Token 放进 `runtime/data`、`runtime/wechat-home`、
归档、manifest、备份日志或普通用户目录。

首次上线本模式时，`${STORAGE_ROOT}/data` 和 `${STORAGE_ROOT}/wechat-home` 是 legacy
布局。若没有新 runtime，脚本把存在的 legacy 目录迁入同一个时间戳归档；如果新 runtime
与任一 legacy 目录同时存在，配置校验 fail-fast，不停止 worker、容器，也不修改目录。

## 归档

归档根：

```text
/srv/storage/cf-agent-wechat/session-archive/<UTC时间戳>/
```

每次启动在容器停止后将当前 runtime 原子移动到唯一时间戳目录。归档至少包含：

- 上一次 `runtime/data`；
- 上一次 `runtime/wechat-home`；
- 一份脱敏 manifest；
- manifest schema version、启动和结束 UTC 时间；
- 旧 runtime path、当前批准的镜像 digest 和 archive result；
- 原 runtime、data 和 wechat-home 的属主、组和权限元数据。

legacy 迁移同样使用一个唯一时间戳目录：`data` 与 `wechat-home` 不得拆到两个归档。
manifest 的 `sourceLayout`/`sourcePaths` 用于区分 runtime 与 legacy 来源，不记录敏感
内容。

manifest 不得包含 Token 内容或指纹、微信账号、联系人、聊天 ID、消息正文、数据库内容
或服务器凭据。失败流程也必须保留已产生的归档，并输出对应归档路径。

manifest 是脱敏元数据，但 archive 本身可能包含历史 session、缓存和消息数据，必须
root-protected。Token 被严格禁止进入 archive，且 archive 不得挂回生产复用。

### 保留策略

本项目不自动删除任何历史归档，也不提供定时清理动作。生产运维应：

1. 监控 `session-archive` 容量和文件系统剩余空间。
2. 由数据所有者与安全负责人定义保存期限和访问权限。
3. 仅在独立、审批通过的外部流程中处置超期归档。
4. 删除前确认不影响审计、故障分析和回滚证据。

上述策略说明不授权本项目脚本删除历史归档。

## 权限

新 runtime 目录必须继承生产基线的正确 UID、GID 和权限。Token 权限保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

严禁 `chmod 644`、更改 Token 所有者、复制 Token 或将其加入环境变量。检查时只查看
元数据，不读取内容。

## 失败处理

worker 停止已经确认后，任一归档、容器启动、WeChat 进程、二维码登录或 API 验证失败
时：

- `wechat-worker` 保持停止；
- 不启动 AI 调度；
- 不删除 runtime 或归档；
- 不执行 UI logout；
- 不修改 PostgreSQL、Gateway 数据库或 Hermes 数据库；
- 只输出脱敏错误和归档路径。

如果第一步无法确认 worker 已停止，脚本立即失败并报告“无法确认”，本仓库不声称它仍
为 stopped。该问题必须在 CFserver/Gateway 运维边界处理。

处理原因后重新执行完整启动入口。不要手工恢复旧 runtime，也不要用单独的
`logged_in`、容器 `healthy` 或重启前旧消息作为成功证据。

## 回滚原则

- 代码、Compose 或镜像可以回到已批准的不可变版本。
- 回滚前保留当前 runtime、归档和脱敏日志。
- 回滚后仍必须创建全新 runtime 并完成二维码登录，不恢复旧微信会话。
- Token 继续使用同一独立只读挂载，不进入代码或归档。
- 完整验证通过前，`wechat-worker` 必须停止。
- Gateway 与 Hermes 上下文继续由各自数据库持久化，本项目回滚不修改这些数据库。

## 安全边界

- 6174 只绑定 loopback，不新增公网端口。
- Gateway 只通过 `cf-internal` 固定 alias `cf-agent-wechat` 调用本服务。
- 日志、截图和工单不得包含 Token、二维码、账号、联系人、聊天 ID、聊天正文、服务器
  地址、API Key 或密码。
- 本项目只控制 Gateway 的 `wechat-worker` 运行状态，不启停 `dispatch-worker` 或
  `delivery-worker`，不修改 Gateway 代码、PostgreSQL、Checkpoint、数据库或 Hermes
  调度数据。
- VNC、noVNC、x11vnc、websockify、宿主 X11、XFCE 和 RDP 不属于生产方案。
- `seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求；镜像升级时必须重新
  评估，并持续审查其必要性。

## 交接清单

- [ ] 所有人知道唯一启动入口是 `./scripts/start-qr-login.sh`。
- [ ] 所有人知道 Bootstrap 只做基础准备，不登录微信或启动 Agent/Worker。
- [ ] 生产 Compose 已渲染为 `restart: "no"`。
- [ ] Docker 使用固定系统工具、真实非符号链接 `/var/run/docker.sock`、local
  rootful daemon 和 `live-restore=false`。
- [ ] 固定 heartbeat checker 由管理用户直接执行，且不输出敏感值。
- [ ] 所有人知道每次 Debian 重启、重建和人工启动都需要手机扫码。
- [ ] 停止操作统一使用 `./scripts/stop-qr-runtime.sh`。
- [ ] 禁止用 `docker compose down/up/restart` 代替生命周期脚本。
- [ ] runtime、archive 和 secrets 的路径及权限责任明确。
- [ ] 归档容量监控、访问控制和外部保留策略已交接。
- [ ] `logged_in` 不能单独作为生产可用结论。
- [ ] worker 只在进程、auth、chats 和 messages 验证通过后启动。
- [ ] start/stop 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`，dry-run 不创建锁。
- [ ] legacy 双目录迁入同一归档，mixed 新旧布局必须 fail-fast。
- [ ] CFserver 已实机验证 Gateway boot stop gate；本仓库不提供该开机窗口保证。
- [ ] 业务方知道重启期间消息可能不补拉，并在登录完成后再发送业务消息。
- [ ] Gateway/Hermes 上下文仍由各自数据库持久化。
- [ ] 本次强制二维码流程仍需 CFserver 实机扫码验证。
