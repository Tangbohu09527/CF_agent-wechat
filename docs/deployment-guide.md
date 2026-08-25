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
- Token 固定为 `/srv/storage/cf-agent-wechat/secrets/auth-token`：非 symlink 普通
  文件、link count 1、`10001:10001`、`0600`、64 位小写十六进制且无尾随 LF；
  secrets 父目录保持 `root:root 0700`。
- 生产 API/WS 只从 `127.0.0.1` 和批准的 Agent port 派生；继承的 `API_URL` /
  `WS_URL` 被清理，Token 不发送到非 loopback 地址。
- `PROXY` 只允许空值或无认证的 `http`/`https`/`socks5`/`socks5h`
  `host:port`；userinfo、query、fragment 和控制字符一律拒绝。
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

Bootstrap 检查 Debian、systemd、本机 rootful Docker、真实 Unix socket、固定
context endpoint、`live-restore=false`、Compose、目录/权限、镜像、loopback、alias、
Token 及 Gateway Contract v1。Gateway 事实来源固定为
`Tangbohu09527/CF_agent-gateway` SHA
`2db9dff6ece65004cc75723e1243215a5d04b304`，控制入口固定为
`/opt/cf-agent-gateway/deploy/wechat-runtime-control`。Bootstrap 可创建新 Token，
或只迁移精确旧格式 `root:root 0600 + 64 lowercase hex + 单个 LF`；其他格式不覆盖。

Bootstrap 完成只表示基础部署准备完成。它不创建或恢复微信 session，不启动
`agent-wechat` 或 Gateway Worker，不表示微信已经登录或 Runtime 已上线。
详细说明见[新设备部署引导](deployment/new-device-bootstrap.md)。

## 阶段二：人工 Fresh QR

每次生产启动都由人工在受控 SSH TTY 执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

固定状态机：

```text
直接校验 Contract v1；非 root 一次 sudo -v
  -> sudo -n controller stop，并确认 {"stopped":true}
  -> 停止并移除旧 agent-wechat 容器
  -> 原子归档旧 runtime
  -> 创建全新 data/wechat-home
  -> 以 restart=no 启动 agent-wechat
  -> 显示 fresh/new-account QR
  -> 手机确认
  -> container + Docker health + WeChat process
  -> auth logged_in + chats readable + messages readable
  -> sudo -n controller start
  -> status: ready/token_contract_valid=true，worker/delivery health=healthy
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
7. Gateway `ready` 和 `token_contract_valid` 为 true，`worker` 与
   `delivery-worker` health 均为 healthy。

Compose healthcheck 只证明容器和 Agent API 健康，不能证明第 3 至第 7 项。

任一步失败都必须返回非零，保持两个受控 Gateway Worker 停止，保留失败 runtime 和历史
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

本次 R2 只执行基础语法、compile、ShellCheck（若可用）和 diff 检查；这些不是生产
验收。真实扫码、Host/Docker reboot、Gateway 开机停止状态、Token contract 和 controller
失败回停仍待 CFserver 实机验证。

## 安全与时间

- `seccomp=unconfined` 和 `SYS_PTRACE` 是当前上游镜像要求，必须持续安全审查。
- CFserver Host 使用 `Asia/Shanghai`。
- 容器、日志、archive manifest 和原始审计证据使用 UTC。
- 展示层可以转换时区，但必须标明时区。
- Archive payload 可能含 WeChat session、账号/Chat 标识、消息 metadata、cache 和
  数据库内容，必须受限保存且不得用于自动复用；manifest 本身不含 Token、账号标识、
  Chat ID 或消息正文。
- controller 只协调 `worker` 和 `delivery-worker`；不控制 `gateway`、
  `postgres`、`dispatch-worker` 或 migration，也不修改其他仓库。

## 下一步

- [新设备 Bootstrap](deployment/new-device-bootstrap.md)
- [QR Login Guide](qr-login-guide.md)
- [生产运维](operations.md)
- [Recovery Guide](recovery-guide.md)
- [故障排查](troubleshooting.md)
- [验证总览](validation.md)
- [Deployment Audit](deployment-audit.md)
