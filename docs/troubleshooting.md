# CFserver 生产故障排查

## 排查顺序

本文只处理 CFserver 上 `CF_agent-wechat` 的容器、微信客户端、登录管理和
agent-server 问题。按以下顺序排查，避免用重启掩盖根因：

1. 正式 Compose 和容器是否运行。
2. 容器健康检查和进程是否正常。
3. Token 是否存在且权限正确。
4. `./scripts/status.sh` 返回的微信状态。
5. `./scripts/login.sh` 的登录事件和登录后复核。

所有 Compose 命令都必须在正式目录执行，并显式指定生产配置：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200 agent-wechat
./scripts/status.sh
```

> **不得在 CFserver 上裸用 `docker compose down`。**
> `docker/docker-compose.yml` 是实验室或验证配置，不是正式部署配置。

## 容器未运行

### 现象

生产 Compose 中服务为 `exited`、容器不存在，或 `status.sh` 显示容器
`stopped`。

### 检查与处理

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps -a
sudo docker compose -f docker/compose.cfserver.yaml config --quiet
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200 agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml up -d
sudo docker compose -f docker/compose.cfserver.yaml ps
```

若配置校验或启动失败，先处理 `.env` 缺项、镜像不可用、外部网络
`cf-internal` 不存在、端口冲突或持久化路径不存在等日志中的明确错误。不要删除
持久化目录或重新生成 Token。

## 容器 `unhealthy`

### 检查

```bash
sudo docker inspect --format \
  '{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{.Output}}{{println}}{{end}}' \
  cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=300 agent-wechat
sudo docker exec cf-agent-wechat \
  curl --fail --silent --show-error http://127.0.0.1:6174/health
```

重点检查 agent-server 是否监听 6174、Xvfb 与 WeChat 是否反复退出，以及启动时间是否
仍在健康检查的宽限期内。记录去敏日志后再决定是否重启：

```bash
sudo docker compose -f docker/compose.cfserver.yaml restart agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
```

若重启后再次 `unhealthy`，停止重复重启并保留现场。

## `status.sh` 显示 Token 文件不存在

默认路径是：

```text
/srv/storage/cf-agent-wechat/secrets/auth-token
```

使用 root 权限检查路径、类型、属主和权限，不要输出文件内容：

```bash
sudo stat -c '%F %U:%G %a %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
```

正确状态为：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

文件确实不存在时，从受控备份恢复原 Token，或按批准的新部署流程初始化。已有数据环境
不得随意生成新 Token。路径存在但脚本仍报告不存在时，检查是否误设 `TOKEN_FILE`，
以及路径是否为符号链接；默认 secrets 目录和 Token 都不得是符号链接。

## 普通用户无法读取 root-only Token

这是预期权限边界。保持 secrets 目录 `root:root 700`、Token `root:root 600`；
严禁 `chmod 644 auth-token`，也不要复制到普通用户目录。

脚本对默认路径使用受控 `sudo` 读取，并在读取前校验路径类型、属主和权限。以普通用户
运行：

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
```

出现 sudo 权限错误时，检查当前运维账号是否具有批准的定点 sudo 权限。不要改用
`sudo ./scripts/status.sh` 或给整个仓库提权。自定义 `TOKEN_FILE` 不支持此受控
sudo 读取，必须由当前用户本身可读。

## Docker socket 无权限

`status.sh` 先以当前用户执行 `docker inspect`。仅当错误明确来自 Docker socket
权限时，才回退到 `sudo docker inspect`；不需要把普通用户加入 `docker` 组。

```bash
docker inspect --format '{{.State.Running}}' cf-agent-wechat
sudo docker inspect --format '{{.State.Running}}' cf-agent-wechat
```

若第一条显示 socket 权限错误而第二条成功，fallback 应能工作。若第二条也失败，修复
批准的 sudo 权限或 Docker daemon 状态；不要放宽 Docker socket 权限。

## 微信状态为 `logged_out`

`logged_out` 表示 agent-server 可访问，但微信会话未登录。`status.sh` 在该状态
返回码 2，并提示运行登录脚本：

```bash
cd /opt/cf-agent-wechat
./scripts/login.sh
./scripts/status.sh
```

已信任设备的实机验证路径是手机确认登录。完全新设备的 SSH 终端二维码扫码流程已
实现，但尚未完成实机验证，不应视为已验证能力。

不要通过删除 `data`、`wechat-home`、更换 Token 或启用 VNC 来处理
`logged_out`。

## 微信状态为 `app_not_running`

`app_not_running` 表示 agent-server 可访问，但微信客户端进程未正常运行；
`status.sh` 返回码 3，`login.sh` 不会启动登录流程。

```bash
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=300 agent-wechat
sudo docker exec cf-agent-wechat ps -ef |
  grep -E '[w]eixin|[w]echat|agent-server|Xvfb|fluxbox|dunst'
```

先根据日志处理 Xvfb、桌面管理器、WeChat 启动或资源不足问题。确需重启时执行：

```bash
sudo docker compose -f docker/compose.cfserver.yaml restart agent-wechat
```

容器恢复健康后先运行 `status.sh`，只有状态为 `logged_out` 才运行
`login.sh`。

## 微信进程被健康监控重启

WeChat 进程 PID 频繁变化、登录反复失效，或日志显示健康监控反复拉起客户端时：

```bash
sudo docker compose -f docker/compose.cfserver.yaml logs --since=15m agent-wechat
sudo docker exec cf-agent-wechat ps -ef |
  grep -E '[w]eixin|[w]echat|agent-server|Xvfb|fluxbox|dunst'
```

保存两个时间点的进程列表与去敏日志，区分一次正常启动和持续重启。当前生产验证已确认
登录后 90 秒内健康监控没有杀死微信进程；持续重启属于异常。

不要启用 x11vnc/websockify 或修改 entrypoint 绕过监控。先检查资源、Xvfb、
WeChat 崩溃信息和 agent-server 日志；保留现场后再按批准流程重启或回滚镜像。

## 登录流程卡在 `phone_confirm`

`phone_confirm` 表示登录事件已到达手机确认阶段：

1. 在手机微信完成确认，保持 SSH 会话和 `login.sh` 运行。
2. 确认手机网络正常，账号没有额外的安全验证提示。
3. 查看容器日志是否有登录超时、WebSocket 断开或 WeChat 进程重启。
4. 超时后先执行 `./scripts/status.sh`；若已是 `logged_in`，无需重试。
5. 仍为 `logged_out` 时，在确认上一次流程已退出后再运行一次
   `./scripts/login.sh`。

```bash
sudo docker compose -f docker/compose.cfserver.yaml logs --since=10m agent-wechat
./scripts/status.sh
```

收到 `login_success` 后，脚本还会复核认证接口；只有最终返回 `logged_in` 才算
登录成功。不要并行启动多个登录脚本，也不要把二维码或账号信息放入工单。

## 确认生产环境没有 x11vnc 和 websockify

当前生产配置固定 `ENABLE_VNC=0`，VNC/noVNC 不在运行链路。以下命令不依赖容器内
安装 `pgrep`，并用字符类避免 `grep` 匹配自身：

```bash
sudo docker exec cf-agent-wechat ps -ef |
  grep -E '[x]11vnc|[w]ebsockify' || true
```

正常结果为空。若出现实际进程，再确认生效的环境变量与 Compose 配置：

```bash
sudo docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' \
  cf-agent-wechat | grep '^ENABLE_VNC='
sudo docker compose -f docker/compose.cfserver.yaml config --quiet
```

预期为 `ENABLE_VNC=0`，且静默 Compose 校验成功。不要在公开故障单中粘贴未经
检查的完整环境变量或 Compose 渲染输出。

## Gateway 或 Hermes 问题不属于本项目边界

本项目负责微信入口、登录管理、消息接口，以及在 `cf-internal` 网络上提供
`http://cf-agent-wechat:6174`。可以在本仓库边界内确认：

- 容器为 `healthy`。
- `status.sh` 为 `logged_in`。
- agent-server 健康、认证、聊天和消息接口正常。
- 容器已加入 `cf-internal`。

若这些检查正常，但 Gateway 的权限、路由、轮询、消息存储或 Hermes 调度失败，应转交
对应项目排查。本仓库文档不提供 Gateway/Hermes 内部修复步骤，也不要为处理其故障而
修改本项目 Token、微信数据或生产 Compose。

## 历史实验（已废弃、非当前生产方案）

VNC/noVNC、x11vnc、websockify、宿主 X11 挂载、XFCE、RDP 和
`DISPLAY=:10.0` 仅属于早期历史实验。这些组件不用于当前生产登录、诊断或恢复；
CFserver 无需登录宿主桌面操作微信。旧实验中的 VNC 修复脚本或 systemd 服务不得应用
到生产。

## 提交故障信息前

记录时间点、当前 Commit、镜像版本、Compose 状态、健康状态、登录脚本返回码和去敏
日志。不得附带 Token、Token 摘要、二维码、账号标识、联系人、群聊标识、聊天正文、
媒体文件、服务器地址、API Key 或密码。
