# CFserver 生产故障排查

## 总原则

生产环境不恢复旧微信登录会话。任何需要重新启动微信入口的故障都必须回到：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

不要用 `docker compose up`、`restart` 或 `down` 恢复服务，不要执行 UI logout，也
不要手工删除 runtime。脚本确认 `wechat-worker` 已停止后，后续失败必须保持停止；
若初始停止无法确认，脚本会失败并报告，不能声称本仓已阻断 worker。已有归档必须保留。
生产 Compose 必须为 `restart: "no"`，Docker daemon 必须为
`live-restore=false`，所以 crash、daemon 重启或 Debian 重启都不会自动恢复 Agent。

## 排查顺序

1. 确认没有另一个 `start-qr-login.sh` 持有登录锁。
2. 确认正式 Compose、agent-wechat 环境文件、Token 元数据、runtime 和归档根配置
   正确。
3. 查看 `./scripts/status.sh` 的七个状态项。
4. 确认 `/usr/bin/wechat` 真实进程存在且稳定。
5. 区分 auth、chats 和 messages 三层 API 结果。
6. 确认完整验证前 `wechat-worker` 一直停止。
7. 只查看脱敏日志，不记录账号、聊天 ID、二维码、Token 或消息正文。

基础诊断命令：

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

`docker/docker-compose.yml` 是实验配置，不得用于 CFserver。

## Bootstrap 失败

首次部署时运行。已运行环境的部署输入变化时，先运行
`./scripts/stop-qr-runtime.sh` 并确认 Agent/Worker 均已停止，再运行：

```bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
```

Bootstrap 失败只表示基础部署尚未准备完成。它不得启动 `agent-wechat` 或
`wechat-worker`，不得创建或复用微信 session，也不得伪造 initialized 状态。按脱敏
错误检查固定系统工具、systemd、本机 rootful Docker、default context、固定 endpoint、
真实非符号链接 `/var/run/docker.sock`、`live-restore=false`、Compose v2、仓库、
环境文件、目录、owner/mode、symlink/hardlink、digest、loopback、`cf-internal` alias、
Token、Gateway 路径和固定 heartbeat checker。修复配置后安全重跑 Bootstrap，然后才
运行 `start-qr-login.sh`。

## Dry run 与配置失败

先执行：

```bash
./scripts/start-qr-login.sh --dry-run
```

两个脚本的 dry run 都应只输出计划，不停止或删除容器、不移动目录、不停止或启动
worker，并在锁获取
前返回，不创建或遗留 `/run/lock/cf-agent-wechat-qr-runtime.lock`。若配置校验失败，
按错误提示检查：

- `docker/compose.cfserver.yaml` 与固定 `docker/.env` 是否为 owner/mode/link 合规文件；
- `docker/.env` 是否包含全部受支持键、批准 digest/loopback/path/UID/GID/mode/阈值，
  且没有重复键、shell 语法或 Secret；
- systemd/docker.service、local rootful default Docker、真实 socket、
  `live-restore=false`、Compose v2、`cf-internal` 和 Agent auto-start unit 是否合规；
- Runtime/legacy、Archive、secrets 和锁的精确 owner/group/mode、symlink/hardlink 合同；
- Token 是否为批准固定路径，且 Gateway 使用固定 file pointer 和唯一只读 bind；
- Gateway contract v1、固定 checker、project/profile/service 是否完整兼容。

生产路径不可覆盖：Agent Compose/env/project 固定在 `/opt/cf-agent-wechat`，Gateway
Compose/env/project 固定为 `/opt/cf-agent-gateway/docker-compose.prod.yml`、
`/opt/cf-agent-gateway/.env` 和 `/opt/cf-agent-gateway`。导出 `API_URL`、
`WS_URL`、Token/session、Agent/Compose、Proxy、Python、Runtime/Archive 或 Gateway
管理变量会立即被拒绝；不要改成“正确覆盖值”，应清除变量后重试。该拒绝发生在 curl/
WebSocket、Worker、Archive 和 QR 之前，因此不会把 Token 发往环境指定地址。

Gateway contract/checker 固定在
`/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json` 和
`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`。checker 必须由兼容
Gateway commit 部署，以当前管理用户无参数运行，10 秒内无输出，并同时验证当前
`worker` running/healthy、heartbeat 新鲜、最新 Poll Cycle 成功和 auth=`logged_in`。
缺失、版本/字段不兼容、Token mismatch、非零、stale、超时或任何输出都禁止 Worker
放行；不得创建 fake checker。Gateway PR #4 尚不兼容，当前结论必须保留
**BLOCKED BY GATEWAY CONTRACT**。

不要通过创建假 Token、放宽权限、修改其他仓库或跳过检查继续启动。

## 登录锁已占用

start/stop/retention 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`。它必须为空、
非 symlink、单 hardlink，精确使用批准 owner、`CF_AGENT_WECHAT_MANAGEMENT_GID` 和
mode `0640`；普通非管理用户不能打开持锁。空文件存在不等于锁正被持有，flock 随持有
进程退出释放。看到锁占用错误时：

1. 确认是否确有另一个 SSH 会话正在登录。
2. 等待该流程完成或正常退出。
3. 确认 `wechat-worker` 的状态。
4. 再运行一次完整启动入口。

不要并发启动第二个脚本，也不要仅因文件存在就删除它，更不能移除活跃锁。并发失败不得
改变 runtime、归档、容器或 worker。

## Runtime 归档失败

当前 runtime 必须原子移动到：

```text
/srv/storage/cf-agent-wechat/session-archive/<UTC时间戳>/
```

归档前已经完成 bytes、可用百分比、inode 和 inventory 门禁。若提示容量不足，调整
受保护 `docker/.env` 中经批准阈值或按审批执行 retention；不得临时导出阈值、自动删除
Archive 或跳过检查。只读 inventory：

```bash
sudo python3 scripts/archive-runtime.py inventory
sudo python3 scripts/archive-runtime.py inventory --json
```

其他失败检查父目录是否同一受控文件系统、Archive root 是否 `root:root 700` 且非
symlink、时间戳目标是否唯一，以及扫描是否遇到路径逃逸、额外 hardlink、特殊文件、
跨文件系统、entry 上限或 timeout。脚本不得覆盖旧归档，也不得在移动失败后删除源目录。

只检查目录元数据：

```bash
sudo stat -c '%F %U:%G %a %n' \
  /srv/storage/cf-agent-wechat/runtime \
  /srv/storage/cf-agent-wechat/session-archive
```

若 inventory 报告顶层 `.incomplete-*`，它是发布前中断的归档事务；若合法 UTC
目录中的 schema v2 manifest 仍为 `in_progress`，它是发布后尚未终结的事务。两者都
必须保留为 restricted 现场并阻断启动。不要手工拼接、改名、删除或把它们改写成
`success`，也不要上传、共享或复用其中 session。

缺失 manifest、malformed/non-object JSON、unsupported schema、manifest 临时残留或
非 terminal 结果不是 schema v1 compatibility。只有结构完整且 terminal 的 v1 历史
证据可被 inventory 识别，仍必须按 restricted 处理且禁止生产恢复。

确认原因并按批准处置现场后再运行完整入口。不要把 Token 复制进归档。fsync 顺序和
Linux signal/timeout fixture 不能替代真实掉电验证；CFserver/VM fault-injection 仍待
受控执行。

Manifest schema v2 的 `manifestData` 只描述 manifest 自身；Archive payload 可能包含
完整 session、账号/聊天标识和消息数据，必须按 `restricted` 管理。这不改变 Token
严禁进入 Archive 的要求，也不授权挂回生产。
默认 dry-run retention、显式删除和备份合同见
[Archive Management Contract](archive-management.md)。

首次上线若只有 `${STORAGE_ROOT}/data` 和 `${STORAGE_ROOT}/wechat-home`，两者应进入
同一个时间戳归档；第二个目录移动失败时脚本会尝试回滚第一个。新 `runtime` 与任一
legacy 目录并存属于 mixed layout，校验会在停止 worker/容器前 fail-fast。此时保留两套
现场，先确认受控来源，不要手工合并或删除。

## 新 Runtime 权限失败

`runtime`、`runtime/data`、`runtime/wechat-home` 或 legacy 目录必须精确匹配
`docker/.env` 批准的非 root `CF_AGENT_WECHAT_RUNTIME_UID/GID/MODE`；默认合同为
`1000:1000/700`。脚本不会从旧 Runtime 继承权限。遇到失败时：

1. 只查看目录类型、UID、GID、mode 和 link/type 错误类别。
2. `root:root 700`、`1000:1000 755`、group/other writable 均按漂移处理。
3. symlink、额外 hardlink、FIFO、socket、device 或跨文件系统内容先隔离调查。
4. 由管理员修复到已批准精确值，再重新执行 `start-qr-login.sh`。

不要用 `chmod 777`、`755` 或 root owner 绕过问题。新 Runtime 始终按批准值创建；
Archive manifest 只保留旧权限证据，Token 权限不得随 Runtime 调整。

## PROXY 配置被拒绝

`PROXY` 只支持空值或 `http`、`https`、`socks5`、`socks5h` 的
`scheme://host:port`。出现 `user:password@`、path、query、fragment、空 host/port
或控制字符时必须修改受保护 `docker/.env`，不能把值转移到宿主 `HTTP_PROXY` 等变量。
当前生产不支持认证代理；密码不得进入 container environment、inspect、Compose config、
pip argv 或日志。

## QR Python 依赖失败

生产固定使用 `/usr/bin/python3`、仓库 `scripts/requirements.txt` 和管理用户 passwd
home 下的 `.local/share/cf-agent-wechat/venv`。不要设置 `PYTHON_BIN`、
`REQUIREMENTS_FILE`、`VENV_DIR` 或 `CF_AGENT_WECHAT_VENV`；生产明确拒绝这些覆盖。
`CF_AGENT_WECHAT_TESTING=1` 仅是隔离测试门禁，不是生产支持。Bootstrap 必须真实创建
venv 并确认
ensurepip/pip。启动时依赖必须通过 SHA-256 `--require-hashes`、binary-only、clean
environment、bounded retry/network timeout 和整体 hard timeout；hash mismatch、
ensurepip 缺失或 timeout 都在 Agent 容器、Archive 和 QR 变更前失败；此时 Worker 已先
停止并保持停止。修复包源或批准 lock，不要关闭 hash 校验。

## Runtime 树扫描失败

扫描器不跟随 symlink、不跨文件系统，拒绝额外 hardlink、FIFO、socket、device 等特殊
文件，并限制普通文件数、总字节和总时间。symlink loop、树外链接、大文件/大树超限、
扫描错误或 Token 命中均 fail closed，错误不输出文件内容或 Token。保留现场并在受限
终端修复异常节点；不要改用递归 `grep -R`，也不要放宽为跟随链接。

## 启动策略或实际容器 attestation 失败

每次扫码都会重新检查 systemd/docker.service、default local rootful Docker、
`unix:///var/run/docker.sock`、`live-restore=false`、Agent auto-start unit 和渲染的
`restart=no`。创建后实际容器还必须精确符合批准 image、name/project、
`HostConfig.RestartPolicy.Name=no`、mount、loopback port、network alias 和环境。
任一漂移都会在 QR 前失败并清理本次错误容器；不要把 Compose 改成
`unless-stopped`，不要启用 systemd unit，也不要手工保留不合规容器。
## 容器或 Agent Server 未就绪

`start-qr-login.sh` 会启动容器并等待 agent-server。超时或健康失败时查看：

```bash
./scripts/status.sh
sudo /usr/bin/docker inspect \
  --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} {{.HostConfig.RestartPolicy.Name}}' \
  cf-agent-wechat
sudo /usr/bin/docker logs --tail=300 cf-agent-wechat
sudo /usr/bin/docker exec cf-agent-wechat \
  curl --fail --silent --show-error http://127.0.0.1:6174/health
```

不要在含未知宿主环境变量的 shell 中裸跑 Compose 来排障；Compose 的进程环境优先级会
改变 project/image/container。生命周期脚本已使用 clean environment，以上只读 Docker
命令也必须先由 `status.sh` 确认批准容器身份。日志仅在受限终端查看，不粘贴 Secret。

重点检查镜像、Xvfb、端口、资源限制、挂载和 agent-server 日志。不要直接执行 Compose
重启；保留现场后重新运行完整入口。`restart: "no"` 禁止自动失败重试，不得改成
`on-failure`、`always` 或 `unless-stopped`。

Compose healthcheck 只证明容器和 Agent API 可访问。即使显示 `healthy`，仍必须验证
WeChat 进程、auth、chats、messages 和 Gateway Worker；不得把 healthcheck 当登录证据。

进入 agent 容器轮换阶段后，`start-qr-login.sh` 的任何非零退出都会尝试重新停止并
确认 `wechat-worker`，再依次 stop/remove 本次 `agent-wechat` 容器。remove 只使用
`compose rm --force`，不使用 `-v`、`down` 或 volume 删除；cleanup 不主动删除已有
runtime、历史归档或其中已落盘的持久文件。成功流程不执行该 cleanup，容器继续运行。

只有 stop/remove 均报告成功并通过状态确认时，才能认定失败容器已删除且不会在 Docker
daemon 重启后恢复。任一步失败时，脚本保留原失败阶段和退出结果并追加 cleanup 错误；
重启 Docker 或 Debian 前必须人工确认并处置残留容器。归档已建立且 failed manifest
更新成功时，`failureCleanup` 会记录两步结果；manifest 更新失败会另行报告。cleanup
不会采集 Docker json-file 容器日志，需在等待阶段或由外部日志系统留存；bind-mounted
runtime 中已经落盘的日志不受容器删除影响。配置、锁或 Token 读取等 agent 容器轮换前
的失败仍保持 fail-fast，不删除既有容器或运行目录。

## WeChat 进程不存在、被替换或身份不匹配

即使 agent-server 可访问或 auth 显示 `logged_in`，`/usr/bin/wechat` 真实进程不存在
也必须判定失败。检查：

`/usr/bin/wechat` 是 launcher 路径，可能是符号链接。生命周期脚本先将其解析为
canonical executable，只接受 `/proc/<pid>/exe` 的链接目标与该路径精确一致的进程。
不得仅凭 `comm`、basename、进程名或命令行包含 `wechat` 做宽松匹配；`ps -ef`
只能辅助排查，不能作为 worker 放行证据。

```bash
sudo /usr/bin/docker exec cf-agent-wechat ps -ef
sudo /usr/bin/docker logs --since=15m cf-agent-wechat
```

脚本使用 `PID:start_time` 标识已验证进程，其中 `start_time` 来自
`/proc/<pid>/stat`。稳定等待、登录后验证和最终验证都必须保持同一身份且 executable
仍精确匹配；PID 消失、PID 复用后 start time 改变或 executable 不匹配都视为退出或
替换。不要在工单中粘贴可能包含账号信息的完整输出。排查 Xvfb、窗口管理器、资源不足
和上游客户端崩溃；任一身份检查失败时 `wechat-worker` 不得启动。

## 状态为 `logged_out`

`logged_out` 表示 agent-server 可访问但当前 runtime 未登录。这是全新 runtime 在扫码
前的预期中间状态，不代表可投入生产。保持当前 `start-qr-login.sh` 运行并扫描终端中的
二维码。

如果原流程已经退出，重新运行完整入口。不要手工删除 data 或 wechat-home。
`login.sh` 只是无条件进入同一完整生命周期的兼容包装，不是恢复或诊断入口。

## `runtime is not clean`

`start-qr-login.sh` 在全新 runtime 中发现 `logged_in` 时必须报：

```text
runtime is not clean; use start-qr-login.sh
```

这是安全失败，不能短路为成功。不要 UI logout；确认当前流程退出并释放锁后，重新执行
`start-qr-login.sh`，让脚本归档现场并创建另一个全新 runtime。

## 二维码未显示或扫码超时

1. 保持 SSH 会话和终端宽度足够。
2. 扫描最后显示的二维码，旧二维码可能已经过期。
3. 检查 WebSocket 是否出现 `qr`、`phone_confirm`、超时或脱敏错误事件。
4. 确认 canonical executable 对应的同一 `PID:start_time` 身份在等待期间持续存在。
5. 当前流程退出后，再运行完整启动入口。

强制模式必须实际在 SSH 终端渲染至少一个 QR；未渲染 QR 即使收到 `login_success`
也会拒绝成功。不要把仅出现“登录成功”文本当作完整证据。

如果错误指出 PNG-only `qrDataUrl` 被拒绝，这是预期的 fail-closed 行为：当前依赖
无法在渲染前可靠检查 PNG 编码的 QR 内容是否含 Token。不得改用诊断渲染、写文件或
跳过检查；应修复上游事件，使其提供可审计的文本 QR payload。

不要截图或转发二维码，不要并发启动登录流程，不要尝试通过 UI logout 修复
`Unknown IAState`。

## 收到 `login_success` 后仍失败

WebSocket 成功事件不是最终生产可用证明。启动流程会在
`POST_LOGIN_READY_TIMEOUT`（默认 120 秒）的有界窗口内轮询并确认：

1. canonical executable 对应的同一 `PID:start_time` 身份持续存在；
2. `/api/status/auth` 返回 `logged_in`；
3. `/api/chats` 成功且至少返回一个聊天；
4. 对 API 返回的一个聊天执行消息读取成功。

任何一项失败，`wechat-worker` 都必须保持停止。不要只凭 `login_success` 或
`logged_in` 手工启动 worker。

窗口内短暂未就绪会继续等待；超时或已验证的 WeChat 进程退出/替换才失败。不要通过把
超时设为无限值来掩盖 API 故障。

## Auth 为 `logged_in` 但 chats 不可读

这是已知的假可用状态。`status.sh` 必须非零退出，启动脚本必须失败。旧消息仍可见也
不能证明新消息链路正常。

保留归档和脱敏错误，确认 worker 停止后重新运行完整启动入口。不得修改 Gateway 数据库
或 PostgreSQL 来掩盖微信运行时故障。

## chats 可读但 messages 失败

启动脚本选择 API 已返回的一个聊天做消息读取，只使用于内存验证，不打印聊天 ID 或
正文。读取失败时：

- 不启动 `wechat-worker`；
- 记录脱敏 HTTP 结果类别和时间；
- 检查 agent-server 和 WeChat 进程稳定性；
- 重新运行全新 runtime 登录流程。

不要改用硬编码聊天 ID，也不要从数据库读取聊天数据进行验证。

## Worker 未启动或启动失败

只有完整验证通过后脚本才启动 Gateway `wechat-worker`。若前置检查全部成功但 worker
启动失败，整体流程仍失败：

- 保持或恢复 worker 为停止状态；
- 不启动 AI 调度；
- 不修改 Gateway 代码或数据库；
- 记录脱敏的 worker 控制命令结果；
- 交由 Gateway 运维边界排查。

## Token 文件或权限错误

默认独立路径：

```text
/srv/storage/cf-agent-wechat/secrets/auth-token
```

只查看元数据：

```bash
sudo stat -c '%F %U:%G %a %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
```

预期为 secrets `root:root 700`、Token `root:root 600`；Token 必须是非 symlink、
单 hardlink 的普通文件。它是 Agent/Gateway 唯一权威 credential，不得进入 argv、
process environment、inspect、Compose config、runtime/archive、日志、错误或 CI。

若提示 Gateway Token agreement 失败，只检查 Gateway `.env` 的 owner/mode/link
元数据、contract 兼容版本、固定 `CF_AGENT_WECHAT_TOKEN_FILE` pointer 和唯一只读
bind。独立 legacy migration audit 可以常量时间比较 `CF_AGENT_WECHAT_TOKEN`，但即使
相同也不构成生产兼容；它绝不 source/eval、输出任一值/Hash/长度或静默同步。不要读取
Token、`chmod 644`、复制、生成替代 Token 或手工覆盖 Gateway `.env`；交由 Gateway
受控配置流程迁移到 file credential。

## Gateway 或 Hermes 边界

### Debian 启动后 worker 提前运行

本仓库未修改 Gateway 的 restart policy 或 boot 配置，不能保证人工运行脚本前 worker
已停止。必须在 CFserver 检查并实机重启验证 Gateway Compose/systemd 的 stop gate。
若 worker 在启动窗口提前运行，停止业务消息并转交 Gateway/CFserver 运维处理；不能在
本仓库文档中把该门禁写成已保证。

只有以下条件都成立时，才把“没有 AI 回复”转交下游：

- `status.sh` 返回生产可用；
- messages 读取验证成功；
- `Gateway WeChat Worker` running/healthy，且可用 heartbeat 正常；
- 容器仍连接 `cf-internal`。

heartbeat 证据必须来自 contract v1 固定 checker。脚本以管理用户身份在 10 秒 hard
timeout 内执行，不使用 `sudo`；只有当前 `worker` 实例、Docker health、30 秒内
heartbeat、最新成功 Poll Cycle 和 auth=`logged_in` 同时满足且 stdout/stderr 为空，
返回 0 才通过。stale、持续 Poll 失败、auth 失败、超时、非零或输出任何内容都会撤销
Worker 放行；不得把容器 `healthy` 或固定成功脚本伪装成 checker。

Gateway 和 Hermes 上下文仍由各自数据库持久化。轮换微信 runtime 不修改这些数据库；
本项目故障处理也不得启停 `dispatch-worker` 或 `delivery-worker`，不得修改
`CF_agent-gateway`、PostgreSQL、Checkpoint 或 Hermes 数据。

重启期间收到的消息可能不会由微信本地客户端补拉。必须等登录和完整验证完成后再发送
业务消息。

## 确认无 VNC 进程

生产保持 `ENABLE_VNC=0`，不使用 x11vnc 或 websockify：

```bash
sudo docker exec cf-agent-wechat ps -ef |
  grep -E '[x]11vnc|[w]ebsockify' || true
```

正常结果为空。不要启用 VNC、宿主 X11、XFCE 或 RDP 绕过二维码流程。

## 提交故障信息前

只记录时间、Commit、镜像 digest、脱敏状态项、脚本返回码和归档路径。不得附带 Token
或指纹、二维码、账号、联系人、聊天 ID、聊天正文、媒体、服务器地址、API Key、密码
或任何数据库内容。

CFserver Host 时间按 `Asia/Shanghai` 展示，容器、日志、archive manifest 和原始审计
证据使用 UTC；故障记录必须注明转换后的时区。
