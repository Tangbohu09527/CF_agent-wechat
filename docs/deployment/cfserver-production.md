# CFserver 生产 Runbook

> [!IMPORTANT]
> 本文是详细生产操作的唯一权威入口。当前状态、SHA 和现场镜像证据见
> [生产状态](../production-status.md)；一次性验收见
> [2026-09-03 R2 生产验收](../validation/2026-09-03-forced-qr-r2-production.md)。

## Preconditions

- 项目根固定为 `/opt/cf-agent-wechat`。
- 正式 Compose 为 `/opt/cf-agent-wechat/docker/compose.cfserver.yaml`。
- 正式环境文件为 `/opt/cf-agent-wechat/docker/.env`。
- Compose project、容器名均为 `cf-agent-wechat`。
- `AGENT_WECHAT_IMAGE` 使用批准的不可变 digest，不使用 tag-only 或 `latest`。
- Agent API 的 6174 只绑定 `127.0.0.1`；容器接入 external `cf-internal`。
- Docker 为本机 rootful/default context，endpoint 为
  `unix:///var/run/docker.sock`，`live-restore=false`。
- Gateway Runtime Controller 固定为
  `/opt/cf-agent-gateway/deploy/wechat-runtime-control`，Contract version 1。
- 操作终端不得录制、转发或保存二维码，也不得打印 `.env`、Token、代理凭据。

生产 Compose 为 `restart: "no"`。Bootstrap、fresh QR、stop 和 status 是四种不同
职责；不要合并成裸 Compose 操作。

## Read-only preflight

以下检查不创建 Session、不启动 Agent/Worker：

~~~bash
cd /opt/cf-agent-wechat
git status --short
git rev-parse HEAD

sudo -v
sudo -n /opt/cf-agent-gateway/deploy/wechat-runtime-control contract
sudo -n /opt/cf-agent-gateway/deploy/wechat-runtime-control status

sudo docker compose +  --env-file /opt/cf-agent-wechat/docker/.env +  --project-directory /opt/cf-agent-wechat +  --project-name cf-agent-wechat +  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml +  config --quiet

./scripts/status.sh
~~~

`status.sh` 在 Agent 离线时按设计返回非零；此时输出用于判断，不要把非零改写成脚本
故障。不要运行 `docker compose config` 的完整输出，也不要读取 Token 内容。

## First bootstrap

首次部署：

~~~bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
~~~

Bootstrap 只负责：

- Host、systemd、固定工具、Docker socket/context/rootful/live-restore 检查；
- 仓库、Compose、`.env`、路径、owner/mode/symlink/hardlink 检查；
- Token 当前格式、唯一 legacy 格式迁移或安全生成；
- storage/archive/secrets 管理目录与 external `cf-internal`；
- Compose render 与 `restart: "no"`、loopback、挂载、日志、安全选项 attestation；
- Gateway Runtime Contract version 1 检查；
- 确认 Agent 未被作为 boot service 或长期运行服务。

Bootstrap 不创建或恢复微信 Session，不创建 fresh Runtime data/HOME，不启动
`agent-wechat`，不显示二维码，不登录，不启动 Gateway Worker，也不表示生产入口在线。
成功后的下一步始终是 “Normal fresh QR start”。

## Existing deployment configuration change

Compose、`.env`、代码、镜像 digest、Runtime 参数或权限输入变化时：

1. 在**旧的已批准输入**下运行 Normal stop。
2. 确认 Agent 和 Poll/Delivery Worker 均停止。
3. 应用新的已批准输入；不要打印环境文件。
4. 运行 Bootstrap。
5. 运行 Normal fresh QR start。
6. 运行 Status verification。

不要先替换输入再尝试用新配置停止旧容器。

## Normal fresh QR start

普通人工启动、Agent 容器重建、Runtime 轮换或上次 Session 不可用时，在交互式 SSH
TTY 中执行：

~~~bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
~~~

脚本按当前实现：

1. 验证操作环境、Compose、Token、Docker 与 Gateway Contract v1。
2. 通过 Controller 停止并确认 Poll/Delivery Worker。
3. 停止并移除旧 Agent 容器。
4. 在移动前扫描 Runtime/legacy tree，拒绝 Token 或 mixed layout。
5. 将旧 Runtime 原子移动到新的 UTC Archive，不覆盖历史目录。
6. 创建全新 `runtime/data` 和 `runtime/wechat-home`。
7. 以 `restart: "no"` 启动 Agent，验证实际容器、镜像与 restart policy。
8. 等待 Docker health、Agent Server 与 `/usr/bin/wechat` 稳定身份。
9. POST `/api/status/login?newAccount=true` 并连接登录 WebSocket。
10. 在当前 TTY 实际显示至少一个文本 QR，等待手机扫码确认。
11. 验证同一 `PID:start_time`、Auth、非空 chats 与一个 messages 读取。
12. 通过 Controller `start/status` 放行 Poll/Delivery Worker。

任何成功事件都不能替代真实 QR 输出。PNG-only `qrDataUrl` 当前 fail closed。

## Normal stop

~~~bash
cd /opt/cf-agent-wechat
./scripts/stop-qr-runtime.sh
~~~

该命令先通过 Controller 停止 Poll/Delivery Worker，再停止 Agent。它保留：

- 当前 Runtime；
- 独立 Token；
- 全部 Session Archive；
- Gateway/Hermes 数据。

停止后再次上线仍需 fresh QR，不能把保留的 Runtime 或 Archive当作自动恢复授权。

## Status verification

~~~bash
cd /opt/cf-agent-wechat
./scripts/status.sh
~~~

当前脚本准确输出 11 个状态项：

1. `Container`
2. `Docker Health`
3. `Agent Server`
4. `WeChat Process`
5. `Auth`
6. `QR Runtime Mode`
7. `Message API`
8. `Gateway Runtime Ready`
9. `Gateway Token Contract`
10. `Gateway Poll Worker Health`
11. `Gateway Delivery Worker Health`

完整在线要求：container running、Docker healthy、Agent reachable、真实 WeChat
进程身份稳定、Auth `logged_in`、Runtime mode `fresh`、chats/messages readable、
Gateway ready、Token Contract valid、Poll/Delivery healthy。

退出码：

| 码 | 当前实现含义 |
| --- | --- |
| `0` | 全部生产门槛通过 |
| `1` | 配置/依赖、容器或 Gateway 查询、Token、Message API 或 Gateway readiness 失败 |
| `2` | Auth 明确为 `logged_out`，需要完整 fresh QR |
| `3` | 容器、Docker health、Agent Server、WeChat process、Runtime mode 或其他认证状态不可用 |

Docker health 或 Auth `logged_in` 单项都不是完整成功。

## CFserver reboot recovery

真实 reboot 已证明 Agent 因 `restart: "no"` 保持停止，但 Gateway Worker 可能自动
恢复。**不要假设 Gate 已关闭。**

重启后必须先执行：

~~~bash
sudo -v

sudo -n +  /opt/cf-agent-gateway/deploy/wechat-runtime-control +  stop +  --timeout-seconds 30
~~~

只有 Controller 成功确认受控 Worker 已停止后，才执行：

~~~bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
./scripts/status.sh
~~~

`start-qr-login.sh` 自身仍会再次 stop/confirm；Host reboot 前置 stop 是强制运维步骤，
用于弥补尚未实现或证明的 automatic boot stop gate。重启窗口收到的消息可能无法由
本地微信客户端补拉。

## Gateway-only deployment boundary

若只部署或重建 Gateway，且未重启、停止、删除或 recreate `cf-agent-wechat`：

1. 不运行 Bootstrap 或 fresh QR。
2. 运行 `./scripts/status.sh` 确认 Agent 自身仍在线。
3. 由 Gateway 运维按其 Runbook 恢复 Controller/Worker/Hermes 链路。
4. Gateway 恢复后再次运行 `./scripts/status.sh`。

生产验收中已观察到 Gateway-only 受控切换保持 Agent Session。该证据不能外推为 Agent
容器重启可复用 Session。

## AI host restart boundary

AI/Hermes Host 重启但 CFserver 和 Agent 未重启时：

- 微信 Session 保持，无需 fresh QR。
- 本仓库只用 `./scripts/status.sh` 确认 agent-wechat。
- Hermes 连通性、队列和业务恢复属于 Gateway/Hermes 运维边界。

不要为了下游故障主动重建 Agent 或轮换 Runtime。

## Failed start recovery

若 `start-qr-login.sh` 非零退出：

1. 记录失败 phase、退出码和脱敏 Archive path。
2. 确认 Controller stop 是否成功；不确定时再次使用正式 Controller `stop`。
3. 确认 Agent 容器 stop/remove 结果；cleanup 失败时保留容器状态，禁止先重启 Docker
   或 Host。
4. 保留当前 Runtime、全部 Archive 和 manifest；不要删除未知状态来换取重试。
5. 只查看必要的轮转日志，确认没有 Token、二维码、账号、Chat ID 或正文。
6. 修复根因后重新运行完整 fresh QR start。

Archive 不是 Session 恢复源。不得跳过 Token scan、绕过 Controller 或只凭
`logged_in` 手工启动 Worker。

## Upgrade

1. 在旧输入下 Normal stop。
2. 记录旧批准 Commit 与镜像 digest，但不打印 `.env`。
3. 切换到新的已批准 Commit，更新受控 `AGENT_WECHAT_IMAGE` digest。
4. 可只拉取镜像，不启动：

~~~bash
cd /opt/cf-agent-wechat
sudo docker compose +  --env-file /opt/cf-agent-wechat/docker/.env +  --project-directory /opt/cf-agent-wechat +  --project-name cf-agent-wechat +  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml +  pull agent-wechat
~~~

5. 运行 Bootstrap。
6. 运行 fresh QR start 与 status。
7. 新上游版本必须重新验证 API/schema、`seccomp=unconfined` 与 `SYS_PTRACE`。

## Rollback

代码或镜像回滚只允许回到已批准的不可变版本：

1. 若当前流程可控，先 Normal stop；失败状态则先确保 Gate 关闭并保留证据。
2. 恢复已批准代码、Compose/`.env` 输入和镜像 digest。
3. 运行 Bootstrap。
4. 运行 fresh QR start。
5. 运行 status。

回滚后仍创建 fresh Runtime。不得把旧 Archive、旧 Runtime 或旧可信设备 Session 挂回
生产。

## Evidence preservation

允许保留：

- repository Commit/branch；
- 已批准镜像引用和现场 Image ID（不宣称无证据的源码映射）；
- UTC 时间、脚本退出码、11 个脱敏状态项；
- Archive path、manifest lifecycle/permission/cleanup 结果；
- Agent 容器 name/image/restart policy 和日志结果类别。

禁止保留：

- Token 内容、哈希、前缀或 Authorization；
- 二维码内容或截图；
- 真实账号、联系人、群名、Chat ID、消息正文；
- `.env`、代理凭据、内网 IP、数据库 URL。

Archive payload 本身可能含敏感 Session 与消息 metadata，访问、保留、备份和销毁由
外部运维策略管理。

## Do not do

- 不执行 `docker compose up`、`restart` 或 `down` 替代生命周期脚本。
- 不执行 `docker restart cf-agent-wechat`。
- 不使用 `--remove-orphans`，避免误删其他项目容器。
- 不删除 external `cf-internal`。
- 不手工启动 Poll/Delivery Worker；只调用正式 Controller。
- 不手工恢复、复制或挂载 Archive 为 active Session。
- 不删除 Runtime 来掩盖 mixed/unknown 状态。
- 不读取或打印 Token，不把 Token 写入 `.env`、Runtime、Archive 或日志。
- 不把 Docker health 或 `logged_in` 当作完整生产在线。
- 不启用 VNC/noVNC、Host X11、XFCE 或 RDP。
- 不修改 Gateway、Hermes、PostgreSQL、Checkpoint 或其他仓库。
