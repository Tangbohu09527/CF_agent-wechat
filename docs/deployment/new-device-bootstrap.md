# 新设备部署引导

本文只说明 CFserver 的基础部署准备。Bootstrap 不是微信登录脚本，也不是 Runtime
恢复脚本。

## 结果定义

成功执行：

```bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
```

只表示：

> 基础部署准备完成。下一步由人工在受控 SSH TTY 运行
> `./scripts/start-qr-login.sh`。

它不表示微信已登录、session 已恢复、Runtime 已上线或 `wechat-worker` 已启动。

## 前置条件

- Debian Host 使用 systemd。
- 生产工具使用 Debian 固定系统路径；测试替身只能在显式测试模式使用。
- Docker 是本机 rootful daemon，不是 rootless 或 remote context；context endpoint
  必须为 `unix:///var/run/docker.sock`。
- `/var/run/docker.sock` 必须是真实 Unix socket，且不能是符号链接。
- Docker daemon 必须配置 `live-restore=false`。
- Docker Compose v2 可用。
- 仓库位于批准的生产路径和 Commit。
- Gateway 固定 Compose/env/project/profile/service 为
  `/opt/cf-agent-gateway/docker-compose.prod.yml`、`/opt/cf-agent-gateway/.env`、
  `/opt/cf-agent-gateway`、`worker`、`worker`。
- Gateway 兼容 commit 已部署 versioned contract 和固定 checker；当前 PR #4 尚未兼容，
  因而现状为 **BLOCKED BY GATEWAY CONTRACT**。
- 镜像已批准并以完整 digest 配置。
- CFserver Host 时区为 `Asia/Shanghai`；容器和日志使用 UTC。

Bootstrap 不修改真实微信账号、Gateway 数据库、PostgreSQL、Checkpoint 或其他仓库。

## 校验范围

Bootstrap 按阶段 fail closed：

1. 检查 Debian 固定系统工具、systemd 与 `docker.service`。
2. 检查 default context、真实非 symlink Unix socket、
   `unix:///var/run/docker.sock`、local rootful daemon 与 `live-restore=false`。
3. 检查 Docker Compose v2，并拒绝已启用的 `cf-agent-wechat.service` 或同类
   auto-start unit。
4. 校验仓库、脚本、Compose 与 `docker/.env` 的固定路径、owner、mode、symlink 和
   hardlink。
5. 安全解析 `docker/.env` 完整白名单，不执行 shell；拒绝 Secret、重复键、控制字符、
   非批准路径/digest/loopback/UID/GID/mode/阈值和带凭证 Proxy。
6. 校验 Runtime/legacy 目录精确符合批准非 root UID/GID 与 mode `700`，不接受
   `root:root 700` 或 mode `755`；校验 Archive root、secrets 和管理锁合同。
7. 创建或复用唯一 root-only Agent Token，确认它在 Runtime/Archive 外并只读挂载。
8. 校验 Gateway contract v1、checker 元数据、固定 project/profile/service、file
   credential pointer 和唯一只读 Token bind；不 source/eval 或改写 Gateway `.env`。
9. 校验外部 `cf-internal` 为 local bridge，固定 alias `cf-agent-wechat`。
10. 在 clean environment 中渲染 Compose，精确确认批准 image/project/container、
    `restart=no`、三项 mount、loopback port、alias、`PROXY`、`RUST_LOG`、
    healthcheck/log rotation、`seccomp=unconfined` 与 `SYS_PTRACE`。
11. 真实创建临时 `python3 -m venv`，确认 ensurepip 和 pip 可执行。
12. 确认 Agent 未作为长期服务运行，Gateway `worker` 不会读取未验证 fresh Runtime。

Docker、Compose 和 curl/API 探测必须有 connect/total 或 hard timeout。普通用户管理路径
需要提权时，先通过 `sudo -v` 获得授权，后续只使用 `sudo -n`；不得让自动步骤无限
等待密码。

Gateway 固定 contract/checker 为：

```text
/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json
/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat
```

它们必须由 Gateway 仓库兼容 commit 部署，本仓库不创建或修改。contract 精确固定版本、
alias/port、Token source、project/service、30 秒 heartbeat freshness 和 checker interface。
checker 由管理用户从匹配批准摘要的只读密封快照无参数执行，不用 `sudo`，也不在
provenance 后按原路径二次执行；必须在 10 秒内无输出，并同时确认当前 `worker`
running/healthy、heartbeat 新鲜、最新 Poll Cycle 成功和 auth=`logged_in`。Bootstrap
只验证接口合同，不运行 checker 来宣称登录成功。完整规范见
[Gateway-WeChat Runtime Contract v1](../contracts/gateway-wechat-runtime-contract.md)。

## Token

Token 路径：

```text
/srv/storage/cf-agent-wechat/secrets/auth-token
```

要求：

- secrets 目录为 `root:root 700`。
- Token 为 `root:root 600` 的普通非符号链接文件。
- Token 不得有额外 hardlink。
- Token 是 Agent/Gateway 唯一权威 credential，不进入 `docker/.env`、Runtime、
  Archive、manifest、argv、process environment、inspect、Compose config、日志或 CI。
- Gateway 目标使用
  `CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/cf-agent-wechat-auth-token`；Gateway Compose
  必须把宿主权威文件单次、只读 bind 到该 Worker 路径，且不得注入明文 Token。
- legacy 环境副本只能用于常量时间迁移审计，即使一致也不构成生产兼容；Bootstrap 在
  准备放行前 fail closed，生产 start 先停止并确认 Worker，再在 Agent/Archive/QR 变更前
  fail closed。本仓库不自动同步 Gateway 配置。
- 重试 Bootstrap 可以复用同一 API Token，但不能复用微信 session。
- Bootstrap 只验证 Token 元数据和受控读取路径，不输出内容、摘要、指纹或长度。

旧 Archive 是 `restricted` 资产，可能包含完整 session、账号/聊天标识、消息元数据和
内容；Manifest schema v2 只保证 manifest 自身不写这些值。Token 被明确禁止进入 payload，
Archive 不得挂回生产。扫码前容量/inode、inventory、默认 dry-run retention 与受限备份见
[Archive Management Contract](../archive-management.md)。

## Compose 结果

Bootstrap 渲染后必须确认：

- `restart: "no"`；
- digest-pinned image；
- fresh runtime 的 `data` 和 `wechat-home` bind；
- Token 独立只读 bind；
- loopback port；
- 外部 `cf-internal`；
- alias `cf-agent-wechat`；
- healthcheck 和日志轮转；
- 当前上游镜像所需的 `seccomp=unconfined` 与 `SYS_PTRACE`。

`seccomp=unconfined` 与 `SYS_PTRACE` 必须持续安全审查。Healthcheck 只证明容器和
Agent API 健康，不证明微信登录、chats/messages 或 Gateway 链路。

## 明确禁止

Bootstrap 不得：

- 接受调用环境中的 `API_URL`、`WS_URL`、Token/session、Agent/Compose/Proxy、
  Python/venv、Runtime/Archive 或 Gateway 管理覆盖；
- 启动并长期保持 `agent-wechat` 在线；
- 启动 `wechat-worker`；
- 启停 `dispatch-worker` 或 `delivery-worker`；
- 创建、恢复或验证微信 session；
- 把旧 `data` 或 `wechat-home` 作为活跃恢复目标；
- 删除 archive；
- 修改 Gateway 代码或数据库；
- 伪造 initialized、logged-in 或 production-ready 状态。

## 失败与重试

任一阶段失败时返回非零，保留 archive 和现场，不泄露 Token，不启动 Worker。修复
配置后重新运行同一个 Bootstrap 命令。对已运行部署变更配置前，必须先运行
`./scripts/stop-qr-runtime.sh` 并确认 Agent/Worker 均已停止；Bootstrap 会拒绝活动中的
Agent 或 Worker。分阶段结果不能被当作整体成功，失败后也不能通过手工启动 Compose
跳过剩余检查。

成功后只执行：

```bash
./scripts/start-qr-login.sh
```

扫码与放行流程见[QR Login Guide](../qr-login-guide.md)，完整部署契约见
[CFserver 正式部署](cfserver-production.md)。
