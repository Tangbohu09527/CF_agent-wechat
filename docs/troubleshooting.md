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

## Dry run 与配置失败

先执行：

```bash
./scripts/start-qr-login.sh --dry-run
```

两个脚本的 dry run 都应只输出计划，不停止或删除容器、不移动目录、不停止或启动
worker，并在锁获取
前返回，不创建或遗留 `/run/lock/cf-agent-wechat-qr-runtime.lock`。若配置校验失败，
按错误提示检查：

- `docker/compose.cfserver.yaml` 是否存在并可静态渲染；
- agent-wechat 环境文件路径是否为绝对路径，文件是否存在、是否为普通文件且不是符号
  链接；标准路径为 `/opt/cf-agent-wechat/docker/.env`；
- 必要命令和外部 `cf-internal` 网络是否存在；
- runtime、archive 和 secrets 父目录是否为预期类型；
- Token 是否为独立文件且权限正确；
- Gateway worker 控制配置是否完整。

生命周期脚本显式通过 `--env-file` 使用 agent-wechat 环境文件，Compose 项目目录
仍为 `/opt/cf-agent-wechat`。非标准路径检查 `CF_AGENT_WECHAT_ENV_FILE` 覆盖值。
校验失败会明确指出 agent-wechat environment file，并在任何容器、worker、runtime、
归档或锁变更前返回。

Gateway 默认 Compose、环境文件和项目目录分别为
`/opt/cf-agent-gateway/deploy/compose.yaml`、
`/opt/cf-agent-gateway/deploy/.env` 和
`/opt/cf-agent-gateway/deploy`。标准布局下直接运行
`cd /opt/cf-agent-wechat` 后的 `./scripts/start-qr-login.sh`，无需导出变量。
若现场路径不同，检查 `CF_AGENT_GATEWAY_COMPOSE_FILE`、
`CF_AGENT_GATEWAY_ENV_FILE` 和 `CF_AGENT_GATEWAY_PROJECT_DIR` 覆盖值；
运维检查只确认 agent-wechat 和 Gateway 环境文件是否位于预期路径及其元数据。
生命周期脚本不自行读取、解析、复制或输出内容；Docker Compose 通过 `--env-file`
使用对应文件。

不要通过创建假 Token、放宽权限、修改其他仓库或跳过检查继续启动。

## 登录锁已占用

start/stop 共用 `/run/lock/cf-agent-wechat-qr-runtime.lock`。普通执行可能保留一个安全
的空锁文件，文件存在不等于锁正被持有；并发控制依据 `flock`。看到锁占用错误时：

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

失败时检查父目录是否位于同一受控文件系统、时间戳目标是否唯一、目录是否为真实目录，
以及执行用户是否有正确权限。脚本不得覆盖旧归档，也不得在移动失败后删除源目录。

只检查目录元数据：

```bash
sudo stat -c '%F %U:%G %a %n' \
  /srv/storage/cf-agent-wechat/runtime \
  /srv/storage/cf-agent-wechat/session-archive
```

修复原因后重新运行完整入口。不要手工拼接不完整归档，不要把 Token 复制进归档。

首次上线若只有 `${STORAGE_ROOT}/data` 和 `${STORAGE_ROOT}/wechat-home`，两者应进入
同一个时间戳归档；第二个目录移动失败时脚本会尝试回滚第一个。新 `runtime` 与任一
legacy 目录并存属于 mixed layout，校验会在停止 worker/容器前 fail-fast。此时保留两套
现场，先确认受控来源，不要手工合并或删除。

## 新 Runtime 权限失败

`runtime/data` 和 `runtime/wechat-home` 必须继承生产基线的 UID、GID 和权限。若容器因
不可写而失败：

1. 对比归档 manifest 中的脱敏权限元数据。
2. 检查新目录的类型、属主、组和 mode。
3. 修复到批准的生产权限。
4. 重新执行 `start-qr-login.sh`。

不要用 `chmod 777` 或全局可写权限绕过问题。Token 权限不得随 runtime 权限调整。

## 容器或 Agent Server 未就绪

`start-qr-login.sh` 会启动容器并等待 agent-server。超时或健康失败时查看：

```bash
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  ps
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  logs --tail=300 agent-wechat
sudo docker exec cf-agent-wechat \
  curl --fail --silent --show-error http://127.0.0.1:6174/health
```

重点检查镜像、Xvfb、端口、资源限制、挂载和 agent-server 日志。不要直接执行 Compose
重启；保留现场后重新运行完整入口。`restart: on-failure:3` 已限制容器失败重试，不应
改回 `always` 或 `unless-stopped`。

## WeChat 进程不存在、被替换或身份不匹配

即使 agent-server 可访问或 auth 显示 `logged_in`，`/usr/bin/wechat` 真实进程不存在
也必须判定失败。检查：

`/usr/bin/wechat` 是 launcher 路径，可能是符号链接。生命周期脚本先将其解析为
canonical executable，只接受 `/proc/<pid>/exe` 的链接目标与该路径精确一致的进程。
不得仅凭 `comm`、basename、进程名或命令行包含 `wechat` 做宽松匹配；`ps -ef`
只能辅助排查，不能作为 worker 放行证据。

```bash
sudo docker exec cf-agent-wechat ps -ef
sudo docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  logs --since=15m agent-wechat
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

如果原流程已经退出，重新运行完整入口。不要单独运行普通 `login.sh` 恢复旧会话，也
不要手工删除 data 或 wechat-home。

## `runtime is not clean`

`login.sh --force-qr` 在全新 runtime 中发现 `logged_in` 时必须报：

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

预期为 secrets `root:root 700`、Token `root:root 600`，且都不是符号链接。严禁读取
内容、`chmod 644`、复制到 runtime/archive 或生成替代 Token。

## Gateway 或 Hermes 边界

### Debian 启动后 worker 提前运行

本仓库未修改 Gateway 的 restart policy 或 boot 配置，不能保证人工运行脚本前 worker
已停止。必须在 CFserver 检查并实机重启验证 Gateway Compose/systemd 的 stop gate。
若 worker 在启动窗口提前运行，停止业务消息并转交 Gateway/CFserver 运维处理；不能在
本仓库文档中把该门禁写成已保证。

只有以下条件都成立时，才把“没有 AI 回复”转交下游：

- `status.sh` 返回生产可用；
- messages 读取验证成功；
- `Gateway WeChat Worker` 已启动；
- 容器仍连接 `cf-internal`。

Gateway 和 Hermes 上下文仍由各自数据库持久化。轮换微信 runtime 不修改这些数据库；
本项目故障处理也不得修改 `CF_agent-gateway`、PostgreSQL 或 Hermes 数据。

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
