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

旧 Archive 是 `restricted` 敏感资产，只用于受控审计、故障分析和批准的受限备份；
它可能包含完整 session、账号/聊天标识和消息数据。Manifest schema v2 对 manifest
自身脱敏，不声称 payload 无敏感数据。任何 Archive 都不得挂回生产 `data` 或
`wechat-home`；独立 Agent Token 被严格禁止进入 payload。容量/inode、inventory、
默认 dry-run retention 和 schema v1 兼容见
[Archive Management Contract](archive-management.md)。

## 标准恢复步骤

1. 停止业务消息。
2. 确认 Gateway boot/restart stop gate 下 `wechat-worker` 已停止；无法确认时 fail
   closed 并转交 Gateway/CFserver 运维。
3. 运行 `./scripts/stop-qr-runtime.sh` 进行受控停止，不执行 Compose `down`。
4. 检查失败 runtime 和 archive，只查看脱敏元数据。
5. 部署输入变化时运行 `sudo ./scripts/bootstrap-cfserver.sh`。
6. 清除调用 shell 中全部生产管理覆盖变量，在受控 SSH TTY 运行
   `./scripts/start-qr-login.sh`。
7. 等待脚本重新核验 Host/Compose/Gateway contract、精确 Runtime 权限和安全树扫描，
   停止并确认 Worker，再通过 Archive bytes/percent/inode、inventory 与 Hash 锁定 QR
   venv 门禁；任一门禁失败时 Worker 保持停止。
8. 扫描当前终端显示的新二维码。
9. 等待 process、auth、chats 和 messages 验证。
10. 确认 Gateway `worker` running/healthy，contract checker 对 heartbeat、最新 Poll
    Cycle 与 auth 稳定通过后恢复业务消息。

Bootstrap 只准备部署，不登录、不启动 Agent 或 Worker。没有配置变化时，也不能用
Bootstrap 代替扫码启动。

## Crash

生产 Compose 为 `restart: "no"`。容器进程退出后，Docker 不应自动拉起
`agent-wechat`。外部监控发现 Agent 停止时，应确保 `wechat-worker` 不再消费该
Runtime；本仓库只能在脚本取得控制后停止并复核 Worker，不能修改 Gateway 的自动门禁。

保留失败现场后重新运行完整 fresh-QR 入口。不要先执行 `docker restart`，也不要把
旧 `logged_in` 当作恢复证据。

## Docker Daemon 或 Host 重启

Docker 必须保持 local rootful、default context、固定
`unix:///var/run/docker.sock` endpoint、真实非符号链接 socket 和
`live-restore=false`；systemd/docker.service 必须可用，`cf-agent-wechat.service` 和
同类 auto-start unit 不得 enabled。每次 `start-qr-login.sh` 都重新核验这些条件与
渲染的 `restart=no`，创建后还精确检查实际 RestartPolicy/image/mount/port/alias；
任一偏离都在 Archive/QR 前失败。

重启后预期：

- `agent-wechat` 不存在或保持停止；
- 旧 runtime 仍在存储上，但不是可恢复的活跃 session；
- `wechat-worker` 由 Gateway boot stop gate 保持停止；
- PostgreSQL、Gateway 和其他 Worker 按各自批准规则处理，本仓库不干预。

如果 Agent 自动启动，说明生产 Compose 或外部服务偏离 `restart: "no"`，必须先停止
并修复配置，不能继续验证。随后人工运行 `start-qr-login.sh` 并扫描新二维码。

## Recreate、升级与回滚

`docker compose up --force-recreate` 后 bind mount 仍存在，只能证明文件持久化，不
证明微信 session 可恢复。生产操作不得直接以 recreate 投入工作。

升级或回滚步骤：

1. 在旧的已批准代码、Compose 和环境输入下运行 `stop-qr-runtime.sh`，确认
   Agent/Worker 均已停止。
2. 修改到新的已批准代码 Commit、Compose、环境输入和镜像 digest。
3. 运行 Bootstrap 验证新输入、权限、网络和 Token，不启动服务。
4. 运行 forced fresh QR 入口。
5. 完整验证后再放行 Worker。

`seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求。每次镜像变化必须重新
审查，不能因为旧版本需要就永久豁免。

## 数据与 Token

- 旧 Runtime 和失败 Runtime 保留，不自动删除。
- Archive root/顶层目录保持 `root:root 700`，payload 按 `restricted` 管理，不挂回生产。
- 启动前必须满足容量/inode 阈值并成功 inventory；不会因磁盘压力自动删除 Archive。
- Retention 默认 dry-run；实际删除必须明确 Archive、审批、TTY 二次确认和审计记录。
- Token 是 Agent/Gateway 唯一权威 API secret，可以由 Bootstrap 安全复用，但不代表
  微信 session 复用。
- Token 不进入 Runtime、Archive、manifest、argv、environment、inspect、Compose
  config、日志或备份说明。
- 不通过 PostgreSQL、Checkpoint、`bootstrap_mode=latest` 或 localId 回退修复微信
  Runtime。

## Gateway 边界

本仓库只协调 Gateway `worker` service（角色名 WeChat worker），不启停
`dispatch-worker` 或 `delivery-worker`，不修改 Gateway 代码、PostgreSQL、
Checkpoint、Hermes 数据或其他仓库。Gateway boot stop gate 和 Worker runtime contract
需要在真实 CFserver 验证。

固定 contract/checker 为
`/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json` 和
`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`。它们必须由兼容 Gateway
commit 部署；checker 只以管理用户无参数执行，10 秒内无输出，并确认当前实例、
Docker health、30 秒 heartbeat、最新成功 Poll Cycle 和 auth=`logged_in`。缺失、
版本/Token mismatch、stale、失败、超时或输出内容均撤销 Worker 放行。Gateway PR #4
尚未兼容，当前状态为 **BLOCKED BY GATEWAY CONTRACT**；不得使用 fake checker。

`restart=no Docker policy fixture` 已用 Alpine/Nginx 容器覆盖正常/异常退出和
daemon restart 后保持停止，但未运行实际 Agent/WeChat/QR；对应 commit 的成功 GitHub Actions
run 只证明此 fixture，Run ID 记录在 PR #3。该 CI 场景不是 Host reboot；真实 Host 与 Gateway
boot stop gate 仍需在 CFserver 验证。

## 时间与记录

CFserver Host 使用 `Asia/Shanghai`；容器、日志、archive manifest 和原始审计证据
使用 UTC。记录转换后的展示时间时必须标明时区。

故障材料只能包含 Commit、镜像 digest、UTC 时间、脱敏状态、退出码和 archive path，
不得包含 Token、二维码、账号、联系人、聊天 ID 或消息正文。

操作细节见[生产运维](operations.md)和[故障排查](troubleshooting.md)。
