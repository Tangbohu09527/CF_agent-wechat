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

agent-wechat 生产 Compose、环境文件和项目目录固定为
`/opt/cf-agent-wechat/docker/compose.cfserver.yaml`、
`/opt/cf-agent-wechat/docker/.env` 和 `/opt/cf-agent-wechat`。Gateway 生产合同固定为：

- Compose：`/opt/cf-agent-gateway/docker-compose.prod.yml`
- 环境文件：`/opt/cf-agent-gateway/.env`
- 项目目录/项目名：`/opt/cf-agent-gateway` / `cf-agent-gateway`
- profile/service：`worker` / `worker`；本文所称 WeChat worker 即该 service
- contract：`/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json`
- checker：`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`

生产 start/status/stop/login 拒绝来自调用进程的 Agent、Compose、Token/session、
Runtime/Archive、Proxy、Python 和 Gateway 管理变量；路径覆盖只用于显式
`CF_AGENT_WECHAT_TESTING=1` 的隔离测试。脚本安全解析受保护的 `docker/.env` 白名单
字面值，不 source/eval；API/WS 只由 `127.0.0.1:<approved-port>` 派生，Token 路径和
`SESSION_ID=default` 固定。Compose 调用清除宿主同名变量后只注入批准值，并精确校验
image、project、container、PROXY/RUST_LOG、port、mount、network 和 restart policy。

Gateway contract、checker 与 Token 一致性要求见
[Gateway-WeChat Runtime Contract v1](contracts/gateway-wechat-runtime-contract.md)。
checker 必须无输出，并在 10 秒内确认当前 `worker` running/healthy、heartbeat 新鲜、
最新 Poll Cycle 成功且 auth 为 `logged_in`。Gateway PR #4 尚无兼容 producer，
当前长期目标仍为 **BLOCKED BY GATEWAY CONTRACT**。

`start-qr-login.sh` 会在 Archive、Agent start、QR、验证和最终 release 边界重复确认
Worker stopped，并在 QR 等待期间轮询；若中途出现 Worker，会停止它、终止登录并失败。
这不构成跨仓原子锁。Gateway compatible producer 仍须提供 deny-by-default、绑定当前
fresh runtime generation 的 release gate，使任何外部 `compose up`、supervisor 或旧
release 都不能在验证前启动 Worker。

`docker/docker-compose.yml` 是实验或验证配置，不得用于 CFserver。生产环境不再恢复旧
微信登录会话；每次 Debian 重启、容器重建或人工重新启动都需要 SSH 人工扫码。
CFserver Host 使用 `Asia/Shanghai`，容器和原始日志使用 UTC；显示时可以转换，
archive manifest 和原始审计证据保持 UTC。

## 日常检查

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
```

生产状态检查必须走受保护的管理入口；不要在带有未知宿主环境变量的 shell 中直接运行
Compose。确需调查容器日志时，先由 `status.sh` 确认批准容器身份，再在受限终端使用
固定系统 Docker 读取有限行数；不得把输出粘贴到 CI、公开工单或聊天。

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
rootful daemon、`live-restore=false`、`restart: "no"`、精确 Compose 渲染、Runtime
权限合同、可真实创建且带 ensurepip 的 Python venv、Gateway contract/checker 与 Token
一致性。它不创建或恢复微信 session，不启动 Agent/`worker`，也不能被当作登录成功或
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

脚本先重新校验 systemd/docker.service、本机 rootful default Docker、
`live-restore=false`、未启用的 Agent auto-start unit、精确 Compose `restart=no`、
Gateway contract/Token、现有 Runtime 精确权限和受限 no-follow 树扫描（包含路径名 Token
检查及 xattr/POSIX ACL 拒绝）；扫描最多接受 200,000 个 entry，attestation 累计编码
相对路径另有不可配置的 64 MiB 上限。随后获取管理锁，停止并确认 Gateway `worker`，
再检查 Archive bytes/percent/inode、输出 inventory，并
验证 Hash 锁定的 QR Python 环境。容量、inventory 或 venv 失败时 Worker 保持停止，
但不会移动 Archive、变更 Agent 容器或显示二维码。

这些门禁全部通过后才移除旧 Agent 容器、原子归档当前或 legacy Runtime，并按批准
UID/GID/mode 创建全新目录。容器创建后还会以 Docker inspect
精确核验 image、container/project、`RestartPolicy=no`、mount、loopback port、network
alias 和环境，再等待 running/healthy、Agent API 与 WeChat process 稳定。SSH 终端实际
渲染 QR 且 auth/chats/messages 全部通过后才启动 `worker`；checker 在稳定窗口内持续
通过才放行，否则撤销 Worker 启动并保留 Agent/Archive 现场。

scanner 的最终重验依赖容器已停止且部署 principal 受信；同权限或 root 写入者若在最后
检查后继续修改 Runtime，超出该工具能证明的边界。systemd inventory 同样只证明已枚举
unit、直接 timer/path/socket target 和 target 的一跳 `Wants`/`Requires`；任意深度依赖、
cron、Swarm、Kubernetes、外部配置管理及人工 Docker 操作必须在 CFserver 另行审计。

QR venv helper 会快照 Python、venv、requirements 和 verifier 全部现存祖先的
device/inode/owner/group/mode/type，并在 venv、pip、验证、stamp、cleanup 与 rollback
阶段重验。祖先漂移时 fail closed，不再通过已漂移路径写入或删除。

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

归档根为 `/srv/storage/cf-agent-wechat/session-archive/<UTC时间戳>/`。它保存完整旧
Runtime，可能包含 session、账号/聊天标识、消息元数据和内容，整体属于 `restricted`
敏感资产；不得自动上传、分享、作为 CI artifact 或挂回生产。独立 Agent Token 仍严格
禁止进入 Archive。

Manifest schema v2 的 `manifestData` 只保证 manifest 自身不写实际标识或消息内容；
`archivePayloadClassification` 明确 payload 可能包含上述数据，并固定
`productionSessionRecoveryAllowed=false`。schema v1 按未知且 restricted 处理，不原地
改写，也不推断其中没有敏感数据。

归档先在 root-protected `.incomplete-<UTC-name>-<pid>` staging 中移动并复扫 payload，
持久化 v2 `in_progress` manifest 后才 rename 为合法 UTC 名并 fsync Archive root。
`.incomplete-*` 表示发布前中断；合法 UTC 目录中的 `in_progress` 表示发布后尚未
终结。任一状态、缺失/malformed manifest 或 manifest 临时残留都会使 inventory 与下一次
生产启动 fail closed。不得自动修复、改名、删除、上传或复用这些 Archive。

Linux signal/timeout fixture 验证中断处理，但不等同真实掉电证明；CFserver/VM
fault-injection 仍需在受控维护窗口完成。

每次启动在归档和 QR 前检查 `CF_AGENT_WECHAT_MIN_FREE_BYTES`、
`CF_AGENT_WECHAT_MIN_FREE_PERCENT` 和 `CF_AGENT_WECHAT_MIN_FREE_INODES`，并自动输出
脱敏 inventory。手工 inventory：

```bash
sudo python3 scripts/archive-runtime.py inventory
sudo python3 scripts/archive-runtime.py inventory --json
```

Retention 永远默认 dry-run，且必须明确一个 UTC Archive：

```bash
sudo python3 scripts/archive-runtime.py retention --archive 20300101T000000Z
```

实际删除是另行批准的破坏性动作，还必须增加
`--execute --confirm DELETE:20300101T000000Z` 并在受控 TTY 二次确认。工具重用管理锁、
重做路径/文件类型检查并写 `0600` JSONL 审计；不得配置自动 retention，也绝不触碰
当前 Runtime、Token 或未知路径。受限备份、完整 schema 与删除合同见
[Archive Management Contract](archive-management.md)。

## 权限

批准值必须写入受保护的 `docker/.env`；默认合同为：

```text
runtime、data、wechat-home                      1000:1000 700
session-archive root 与每个 Archive 顶层目录  root:root 700
manifest.json                                  root:root 600
/run/lock/cf-agent-wechat-qr-runtime.lock      approved-owner:<management-gid> 640
/srv/storage/cf-agent-wechat/secrets            root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token root:root 600
```

每次 fresh QR 都精确比较现有 Runtime/legacy 目录与
`CF_AGENT_WECHAT_RUNTIME_UID/GID/MODE`，不继承漂移权限。`root:root 700`、
mode `755`、group/other writable、symlink 或额外 hardlink 必须先受控修复再重试。
锁必须为空、单 hardlink、非 symlink，并使用 `CF_AGENT_WECHAT_MANAGEMENT_GID`；普通
非管理用户不能打开持锁。Token 只检查元数据，不读取或输出内容，严禁 `chmod 644`、
复制、写入环境或调试 shell trace。

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
- [ ] Gateway contract v1 已由兼容 PR #4 commit 部署；固定 checker 由管理用户从
  digest-bound sealed snapshot 执行，不用 sudo、不按原路径二次执行，且在 hard
  timeout 内无输出。未兼容时状态明确为 BLOCKED BY GATEWAY CONTRACT。
- [ ] Agent/Gateway Token 通过合同一致性检查，Token 未进入 argv、environment、
  inspect、Compose config、日志或 CI。
- [ ] 生产管理 shell 不导出 API/WS、Agent、Compose、Proxy、Runtime 或 Gateway 覆盖变量。
- [ ] 所有人知道每次 Debian 重启、重建和人工启动都需要手机扫码。
- [ ] 停止操作统一使用 `./scripts/stop-qr-runtime.sh`。
- [ ] 禁止用 `docker compose down/up/restart` 代替生命周期脚本。
- [ ] Runtime 精确 UID/GID/mode、管理锁 group/mode、Archive root 与 secrets 权限已交接。
- [ ] Archive bytes/percent/inode 门禁、inventory、restricted 备份和默认 dry-run retention
  已交接；没有自动清理。
- [ ] PROXY 无凭证，QR venv 依赖 hash 合同匹配，Runtime 树扫描上限已审批。
- [ ] `logged_in` 不能单独作为生产可用结论。
- [ ] worker 只在进程、auth、chats 和 messages 验证通过后启动。
- [ ] start/stop 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`，dry-run 不创建锁。
- [ ] legacy 双目录迁入同一归档，mixed 新旧布局必须 fail-fast。
- [ ] CFserver 已实机验证 Gateway boot stop gate；本仓库不提供该开机窗口保证。
- [ ] 业务方知道重启期间消息可能不补拉，并在登录完成后再发送业务消息。
- [ ] Gateway/Hermes 上下文仍由各自数据库持久化。
- [ ] 本次强制二维码流程仍需 CFserver 实机扫码验证。
