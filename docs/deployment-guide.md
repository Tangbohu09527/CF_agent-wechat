# Deployment Guide

本文给出 CFserver 上 `CF_agent-wechat` 的生产部署总览。详细路径、权限和命令以
[CFserver 正式部署](deployment/cfserver-production.md)为准。

> [!IMPORTANT]
> 一键部署由两个受控动作组成：一次 Bootstrap 完成基础准备；一次
> `start-qr-login.sh` 完成人工扫码、运行时验证和 Worker 放行。两者不能合并成
> 自动登录或 session recovery。

## 生产不变量

- 正式 Compose：`docker/compose.cfserver.yaml`。
- 正式环境文件：`docker/.env`；生产不接受调用环境覆盖。
- API/WS 仅由批准的 `127.0.0.1:<port>` 派生，Token 与 session 使用固定合同。
- Compose 在 clean environment 中执行，并精确核验批准 image/project/container/环境。
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

Bootstrap 检查 Debian 固定系统工具、systemd/docker.service、本机 rootful default
Docker、真实 socket、`live-restore=false`、未启用的 Agent auto-start unit、Compose
v2、固定生产路径、白名单 `docker/.env`、精确 Runtime 权限、Archive/secrets/锁、
digest/loopback/alias、Gateway contract/checker/Token 一致性，并真实创建临时 Python
venv 验证 ensurepip。它准备管理目录、`cf-internal` 和唯一 root-only API Token，在
clean environment 中精确 attest Compose，但不把 Agent 或 Worker 投入生产。

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
拒绝生产环境覆盖并重新核验 Host/Compose/Gateway/Runtime 合同
  -> 获取 0640 管理锁
  -> 停止并确认 Gateway worker service
  -> Archive bytes/percent/inode + inventory
  -> Hash 锁定 QR venv 验证
  -> 停止并移除旧 agent-wechat 容器
  -> 原子归档旧 runtime，按批准权限创建全新 data/wechat-home
  -> 以 restart=no 创建并精确 attest 实际容器
  -> 显示 fresh/new-account QR
  -> 手机确认
  -> container + Docker health + WeChat process
  -> auth logged_in + chats readable + messages readable
  -> 启动 worker，contract checker 稳定通过
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
7. Gateway `worker` running/healthy，contract v1 checker 在 10 秒 hard timeout 内
   无输出，并确认 heartbeat 新鲜、最新 Poll Cycle 成功与 auth=`logged_in`。

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

`restart=no Docker policy fixture` 已用 Alpine/Nginx 容器覆盖正常退出、异常退出和
daemon restart 后保持停止；它不运行实际 Agent/WeChat/QR。对应 commit 的成功 GitHub Actions run
只证明此 fixture，Run ID 记录在 PR #3。CI 只模拟 daemon 初始化，不能证明真实 Host
reboot；Host 与 Gateway boot stop gate 仍必须在 CFserver 实机验证。

## 安全与时间

- `seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求，必须持续安全审查。
- CFserver Host 使用 `Asia/Shanghai`。
- 容器、日志、archive manifest 和原始审计证据使用 UTC。
- 展示层可以转换时区，但必须标明时区。
- 旧 Archive 是 `restricted` 资产，可能含完整 session、账号/聊天标识和消息数据；
  Manifest schema v2 只对自身脱敏，Token 严禁进入 payload，且不得挂回生产。
- 扫码前执行 Archive bytes/percent/inode 与 inventory 门禁；retention 默认 dry-run，
  不自动删除。见 [Archive Management Contract](archive-management.md)。
- `PROXY` 只允许无凭证 `scheme://host:port`；QR Python 依赖使用 Hash lock、
  binary-only wheel、clean environment 和 hard timeout。
- 本仓库只协调 Gateway `worker` 服务（WeChat worker 角色），不启停 `dispatch-worker` 或
  `delivery-worker`，不修改 Gateway、PostgreSQL、Checkpoint 或其他仓库。

> [!CAUTION]
> Gateway PR #4 尚未发布 contract v1 兼容 producer。当前实现保持
> **BLOCKED BY GATEWAY CONTRACT**，不得以 fake checker 或 CI fixture 宣称跨仓长期目标完成。

## 下一步

- [新设备 Bootstrap](deployment/new-device-bootstrap.md)
- [QR Login Guide](qr-login-guide.md)
- [生产运维](operations.md)
- [Recovery Guide](recovery-guide.md)
- [故障排查](troubleshooting.md)
- [验证总览](validation.md)
- [Deployment Audit](deployment-audit.md)
- [Gateway-WeChat Runtime Contract v1](contracts/gateway-wechat-runtime-contract.md)
- [Archive Management Contract](archive-management.md)
