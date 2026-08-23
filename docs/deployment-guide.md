# Deployment Guide

本文给出 CFserver 上 `CF_agent-wechat` 的生产部署总览。详细路径、权限和命令以
[CFserver 正式部署](deployment/cfserver-production.md)为准。

> [!IMPORTANT]
> 一键部署由两个受控动作组成：一次 Bootstrap 完成基础准备；一次
> `start-qr-login.sh` 完成人工扫码、运行时验证和 Worker 放行。两者不能合并成
> 自动登录或 session recovery。

## 生产不变量

- 正式 Compose：`docker/compose.cfserver.yaml`。
- 正式环境文件：`docker/.env`。
- 镜像使用批准的 digest，禁止 tag-only 和 `latest`。
- 6174 只绑定 loopback。
- 使用外部 `cf-internal`，固定 alias 为 `cf-agent-wechat`。
- 只使用受信任的固定系统工具和非符号链接 `/var/run/docker.sock`；Docker 必须为
  local rootful daemon，context endpoint 固定且 `live-restore=false`。
- Token 以 root-only 文件独立只读挂载，不属于 runtime。
- 当前 runtime 只包含全新的 `data` 和 `wechat-home`。
- 旧 runtime 原子归档并保留，不恢复成活跃 session。
- 生产重启策略必须为 `restart: "no"`。
- `agent-wechat` crash、Docker daemon 重启和 Host 重启均不自动恢复。
- 唯一生产登录入口是 `./scripts/start-qr-login.sh`。

## 阶段一：Bootstrap

首次部署时运行。已运行环境的 Compose、环境文件、目录、权限、Token 或镜像等部署
输入发生变化时，必须先运行 `./scripts/stop-qr-runtime.sh`，确认 Agent/Worker 均已
停止，再运行：

```bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
```

Bootstrap 检查 Debian 固定系统工具、systemd、本机 rootful Docker、真实 Unix socket、
固定 context endpoint、`live-restore=false`、Compose v2、仓库、Compose、环境文件、
runtime/archive/secrets、owner/mode/link count、镜像 digest、loopback、网络 alias、
Gateway 路径、固定 `check-wechat-worker-heartbeat` 和 Token。它准备管理目录、
`cf-internal` 和独立 API Token，渲染生产 Compose，并确认 Agent 和 Worker 没有被
Bootstrap 投入生产。

Bootstrap 完成只表示基础部署准备完成。它不创建或恢复微信 session，不启动
`agent-wechat`，不启动 `wechat-worker`，不表示微信已经登录或 Runtime 已上线。
详细说明见[新设备部署引导](deployment/new-device-bootstrap.md)。

## 阶段二：人工 Fresh QR

每次生产启动都由人工在受控 SSH TTY 执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

固定状态机：

```text
停止并确认 wechat-worker
  -> 停止并移除旧 agent-wechat 容器
  -> 原子归档旧 runtime
  -> 创建全新 data/wechat-home
  -> 以 restart=no 启动 agent-wechat
  -> 显示 fresh/new-account QR
  -> 手机确认
  -> container + Docker health + WeChat process
  -> auth logged_in + chats readable + messages readable
  -> 启动并确认 wechat-worker
```

已有 `logged_in` 也不能跳过 fresh QR。未在当前 TTY 实际显示二维码前，任何成功事件
都不能作为登录成功。详细操作见[QR Login Guide](qr-login-guide.md)。

生产流程只接受可在渲染前审计 Token 的文本 QR payload；PNG-only `qrDataUrl`
必须 fail closed，不能降级成无法检查内容的二维码显示路径。

## 成功与失败

成功必须同时满足：

1. 正式容器 running。
2. Docker health 通过。
3. WeChat canonical process 稳定。
4. auth 为 `logged_in`。
5. chats 可读且非空。
6. 对 API 返回的一个聊天读取 messages 成功。
7. `wechat-worker` running/healthy，Gateway 提供的 heartbeat 正常。

Compose healthcheck 只证明容器和 Agent API 健康，不能证明第 3 至第 7 项。

任一步失败都必须返回非零，保持 `wechat-worker` 停止，保留当前失败 runtime 和历史
archive，不输出 Token、账号、聊天 ID 或消息正文，也不把本轮已在受控 TTY 显示的
二维码再次回显或写入错误、日志、文件。配置修复后可以安全重试；不得通过恢复旧
session 获得绿色状态。

## 重启与恢复

进程 crash、Docker daemon 重启和 Host 重启属于非显式启动场景；`restart: "no"`
与 Docker `live-restore=false` 共同要求 Agent 保持停止，随后只能人工运行
`start-qr-login.sh` 并扫描新二维码。

显式 `docker compose up --force-recreate` 会启动容器，不能依赖 `restart: "no"`
阻止，因此禁止把它用作生产恢复入口。镜像、代码、Compose 或环境输入变化时，严格按
“旧输入下运行 `stop-qr-runtime.sh` 并确认 Agent/Worker 停止 -> 修改受控输入 ->
Bootstrap -> `start-qr-login.sh`”执行。不得把 recreate 后 bind mount 仍存在描述为
session recovery。完整流程见 [Recovery Guide](recovery-guide.md)。

真实 Docker E2E 已覆盖正常退出、异常退出和 daemon restart 后保持停止；最终证据以
新 PR 的绿色 GitHub Actions Run ID 为准。CI 只模拟 daemon 初始化，不能证明真实 Host
reboot；Host 与 Gateway boot stop gate 仍必须在 CFserver 实机验证。

## 安全与时间

- `seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求，必须持续安全审查。
- CFserver Host 使用 `Asia/Shanghai`。
- 容器、日志、archive manifest 和原始审计证据使用 UTC。
- 展示层可以转换时区，但必须标明时区。
- 旧 runtime archive 可能包含历史 session、缓存和消息数据，必须 root-protected；
  Token 严禁进入 archive，且任何 archive 都不得挂回生产复用。
- 本仓库只协调 Gateway `wechat-worker`，不启停 `dispatch-worker` 或
  `delivery-worker`，不修改 Gateway、PostgreSQL、Checkpoint 或其他仓库。

## 下一步

- [新设备 Bootstrap](deployment/new-device-bootstrap.md)
- [QR Login Guide](qr-login-guide.md)
- [生产运维](operations.md)
- [Recovery Guide](recovery-guide.md)
- [故障排查](troubleshooting.md)
- [验证总览](validation.md)
- [Deployment Audit](deployment-audit.md)
