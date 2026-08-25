# Recovery Guide

生产恢复的含义是“重新建立一套经过 fresh QR 验证的 Runtime”，不是恢复旧微信 session。
所有恢复场景最终都回到 `start-qr-login.sh`。

## 恢复模型

| 场景 | Agent 自动行为 | 正确恢复 |
| --- | --- | --- |
| 容器进程 crash | `restart: "no"`，不自动重启 | 停止 Worker，运行完整 fresh-QR 入口 |
| Docker daemon 重启 | Agent 不自动恢复 | 确认 Worker stopped，运行完整 fresh-QR 入口 |
| Debian/Host 重启 | Agent 保持停止 | 验证 Gateway boot stop gate，再扫码 |
| Compose recreate | 不能作为 session recovery | 归档旧 runtime，创建全新 runtime 并扫码 |
| 镜像或代码升级 | 不继承活跃微信会话 | 必要时重跑 Bootstrap，再扫码 |
| 回滚 | 只回滚受控代码/镜像 | 仍创建全新 runtime 并扫码 |
| QR/API 验证失败 | Worker 保持停止 | 保留现场，修复后重新执行完整入口 |

旧 archive 只用于受控审计、故障分析和外部保留策略。任何 archive 都不得挂回生产
`data` 或 `wechat-home` 作为常规恢复目标。Archive payload 可能包含微信 session、
账号标识、聊天标识、消息元数据、缓存和数据库内容，必须保持 root-protected。
Archive manifest 只记录脱敏运行元数据，不得包含 Token、微信账号、Chat ID 或消息正文。

## 标准恢复步骤

1. 停止业务消息。
2. 部署输入变化时运行 `sudo ./scripts/bootstrap-cfserver.sh`。
3. 在受控 SSH TTY 运行 `./scripts/start-qr-login.sh`；非 root 用户只在变更前执行一次
   `sudo -v`，后续 Gateway 控制均使用 `sudo -n`。
4. 脚本先直接调用固定 controller 的 `contract`，严格验证 Contract v1；不匹配时在
   任何变更、归档或二维码显示前 fail closed。
5. 脚本通过 controller `stop` 停止 `worker` 和 `delivery-worker`，确认成功后才停止
   Agent、归档旧 runtime 并创建全新 runtime。
6. 扫描当前终端显示的新二维码。
7. 等待 process、Docker health、auth、chats 和 messages 验证。
8. 脚本通过 controller `start` 和 `status` 放行双 Worker，并要求 `ready=true`、Token
   合同有效且两个 Worker 均为 healthy，随后才恢复业务消息。

Bootstrap 只准备部署，不登录、不启动 Agent 或 Worker。没有配置变化时，也不能用
Bootstrap 代替扫码启动。

## Crash

生产 Compose 为 `restart: "no"`。容器进程退出后，Docker 不应自动拉起
`agent-wechat`。外部监控发现 Agent 停止时，应确保 `worker` 和 `delivery-worker`
不再消费该 Runtime；失败处理可以 best-effort 再次调用 controller `stop`。

保留失败现场后重新运行完整 fresh-QR 入口。不要先执行 `docker restart`，也不要把
旧 `logged_in` 当作恢复证据。

## Docker Daemon 或 Host 重启

Docker 必须保持 local rootful、固定 `unix:///var/run/docker.sock` endpoint、真实
非符号链接 socket 和 `live-restore=false`；任一条件偏离都先修复再恢复。

重启后预期：

- `agent-wechat` 不存在或保持停止；
- 旧 runtime 仍在存储上，但不是可恢复的活跃 session；
- `worker` 和 `delivery-worker` 由 Gateway boot stop gate 保持停止；
- PostgreSQL、Gateway 和其他 Worker 按各自批准规则处理，本仓库不干预。

如果 Agent 自动启动，说明生产 Compose 或外部服务偏离 `restart: "no"`，必须先停止
并修复配置，不能继续验证。随后人工运行 `start-qr-login.sh` 并扫描新二维码。

## Recreate、升级与回滚

`docker compose up --force-recreate` 后 bind mount 仍存在，只能证明文件持久化，不
证明微信 session 可恢复。生产操作不得直接以 recreate 投入工作。

升级或回滚步骤：

1. 在旧的已批准代码、Compose 和环境输入下运行 `stop-qr-runtime.sh`，确认 Agent、
   `worker` 和 `delivery-worker` 均已停止。
2. 修改到新的已批准代码 Commit、Compose、环境输入和镜像 digest。
3. 运行 Bootstrap 验证新输入、权限、网络和 Token，不启动服务。
4. 运行 forced fresh QR 入口。
5. 完整验证后再放行 Worker。

`seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求。每次镜像变化必须重新
审查，不能因为旧版本需要就永久豁免。

## 数据与 Token

- 旧 runtime 和失败 runtime 保留，不自动删除。
- archive root 保持 root-protected，因为归档可能包含历史 session、缓存和消息数据；
  这些数据不得挂回生产。
- Token 固定在 `/srv/storage/cf-agent-wechat/secrets/auth-token`：普通文件、非 symlink、
  hard link count=1、owner `10001:10001`、mode `0600`，内容为无尾随换行的 64 位小写
  十六进制值。
- Bootstrap 只自动迁移明确旧格式：`root:root`、`0600`、link count 1、64 位小写
  十六进制值加单个 LF；迁移不改变逻辑 Token 值，其他格式 fail closed。
- Token 不进入 runtime、archive、manifest、日志、argv 或备份说明。
- archive 到期处置只能由本项目之外的审批流程执行。
- 不通过 PostgreSQL、Checkpoint、`bootstrap_mode=latest` 或 localId 回退修复微信
  Runtime。

## Gateway 边界

本仓库只调用固定入口
`/opt/cf-agent-gateway/deploy/wechat-runtime-control` 的 `contract`、`stop`、`start` 和
`status`。Contract v1 来自 Gateway Commit
`2db9dff6ece65004cc75723e1243215a5d04b304`（分支
`codex/v2-runtime-production-hardening`）。本仓库不猜测 Gateway Compose、服务容器名、
heartbeat 文件或数据库状态。

controller 只控制 `worker` 和 `delivery-worker`。本仓库不启停 `gateway`、
`dispatch-worker`、`postgres` 或 migration，也不修改 Gateway 代码或数据库。
Controller、Token 合同、Docker/Host 重启行为和完整 forced fresh QR 流程尚待在真实
CFserver 验证；本仓库的基础静态检查不构成生产验收。

## 时间与记录

CFserver Host 使用 `Asia/Shanghai`；容器、日志、archive manifest 和原始审计证据
使用 UTC。记录转换后的展示时间时必须标明时区。

故障材料只能包含 Commit、镜像 digest、UTC 时间、脱敏状态、退出码和 archive path，
不得包含 Token、二维码、账号、联系人、聊天 ID 或消息正文。Archive payload 本身是
受限敏感资产，不得因 manifest 脱敏而视为无敏感数据。

操作细节见[生产运维](operations.md)和[故障排查](troubleshooting.md)。
