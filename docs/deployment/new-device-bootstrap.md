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
- Gateway 生产 Compose/config 路径已由 CFserver 运维提供。
- Gateway 已提供固定 heartbeat checker，见下文契约。
- 镜像已批准并以完整 digest 配置。
- CFserver Host 时区为 `Asia/Shanghai`；容器和日志使用 UTC。

Bootstrap 不修改真实微信账号、Gateway 数据库、PostgreSQL、Checkpoint 或其他仓库。

## 校验范围

Bootstrap 按阶段 fail closed：

1. 检查 Debian 必需工具和 systemd。
2. 检查 Docker service 为 running。
3. 检查 Docker context、非符号链接 Unix socket、endpoint 和
   `live-restore=false`，拒绝 rootless/remote daemon。
4. 检查 Docker Compose v2。
5. 校验仓库路径、owner、mode、符号链接和 hardlink。
6. 校验 `docker/compose.cfserver.yaml`。
7. 安全解析 `docker/.env`，不执行任意 shell 内容。
8. 校验 runtime、archive 和 secrets root。
9. 校验目录和文件的 owner、mode、symlink 与 link count。
10. 校验镜像引用是 `@sha256:<64-hex>`。
11. 校验 6174 只绑定 loopback。
12. 校验外部 `cf-internal` 和固定 alias `cf-agent-wechat`。
13. 校验 Token 是 root-only 普通文件，且只读挂载到容器。
14. 校验 Gateway Compose/config 和固定 heartbeat checker 存在、可读且权限安全。
15. 创建必要的管理目录。
16. 创建或复用独立的 agent-wechat API auth Token。
17. 渲染生产 Compose，并确认 `restart: "no"`。
18. 确认 `agent-wechat` 没有被 Bootstrap 作为长期服务运行。
19. 确认 `wechat-worker` 不会读取未验证的 fresh runtime。

Docker、Compose 和 curl/API 探测必须有 connect/total 或 hard timeout。普通用户管理路径
需要提权时，先通过 `sudo -v` 获得授权，后续只使用 `sudo -n`；不得让自动步骤无限
等待密码。

固定 checker 路径为：

```text
/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat
```

它由 Gateway 部署提供，本仓库不创建或修改。它必须是无符号链接、无额外 hardlink、
owner/mode 合规且由管理用户直接执行的普通文件；脚本不得通过 `sudo` 执行它。checker
无参数运行，只在当前 `wechat-worker` 应用 heartbeat 可用时返回 `0`，且不输出敏感值。

## Token

Token 路径：

```text
/srv/storage/cf-agent-wechat/secrets/auth-token
```

要求：

- secrets 目录为 `root:root 700`。
- Token 为 `root:root 600` 的普通非符号链接文件。
- Token 不得有额外 hardlink。
- Token 不进入 `docker/.env`、runtime、archive、manifest、日志、命令行或 CI。
- 重试 Bootstrap 可以复用同一 API Token，但不能复用微信 session。
- Bootstrap 只验证 Token 元数据和受控读取路径，不输出内容、摘要或指纹。

旧 runtime archive 可能包含历史 session、缓存和消息数据，因此 archive root 必须保持
root-protected。只有 Token 被明确禁止进入 archive；旧 session 数据仍不得挂回生产复用。

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
