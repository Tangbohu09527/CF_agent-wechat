# CF_agent-wechat

CF_agent-wechat 是企业 AI 自动化体系的微信入口项目，负责运行 WeChat Linux
客户端与 agent-server，提供登录管理、消息接口、CFserver 生产部署和本项目运维资料。
本项目不负责 AI 推理、Gateway 内部权限、Hermes 调度或企业业务逻辑。

> **当前生产状态（截至 2026-08-14）：** 2026-08-13 已完成 CFserver 正式部署、
> 登录管理和基础接口验证；2026-08-14 已追加文本发送、群消息字段、引用结构和
> 图片媒体读取的生产实机证据。微信入口、登录管理、消息接口和 Gateway 网络访问
> 已完成实机验证。

## 当前生产架构

CFserver 正式容器为 `cf-agent-wechat`，由
`docker/compose.cfserver.yaml` 管理。容器内部运行：

```text
Xvfb (:99, 1280x800x24)
  -> fluxbox / dunst
  -> WeChat Linux 客户端
  -> agent-server (:6174)
  -> CF_agent-gateway
```

生产环境固定 `ENABLE_VNC=0`，使用容器内部 `DISPLAY=:99`。VNC、noVNC、
x11vnc、websockify、宿主桌面 X11 挂载、宿主 XFCE 和 RDP 均不在当前生产链路中，
也不需要登录 CFserver 桌面操作微信。

`CF_agent-gateway` 通过外部 Docker 网络 `cf-internal` 访问：

```text
http://cf-agent-wechat:6174
```

Gateway 是本项目的调用方；其内部权限与上层编排属于另一个项目边界，本文档不展开。

## 正式部署入口

生产代码目录：

```text
/opt/cf-agent-wechat
```

所有正式 Compose 操作必须显式指定生产文件：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker compose -f docker/compose.cfserver.yaml up -d
sudo docker compose -f docker/compose.cfserver.yaml logs
sudo docker compose -f docker/compose.cfserver.yaml down
```

> **警告：不得在 CFserver 上误用不带 `-f` 的
> `docker compose down`。**
>
> `docker/docker-compose.yml` 是实验室或验证配置，不是 CFserver 正式配置。

完整生命周期操作、目录、权限、重建和回滚要求见
[CFserver 正式部署](docs/deployment/cfserver-production.md)。

## 登录管理

通过 SSH 进入 CFserver 后，以普通用户执行：

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
./scripts/login.sh
```

- `status.sh` 区分 `logged_in`、`logged_out`、`app_not_running` 和不可用状态。
- 已登录时，`login.sh` 会短路成功，不重复触发登录。
- 未登录时，`login.sh` 启动 HTTP/WebSocket 登录流程并等待手机操作。
- 默认登录工具 venv 位于 `~/.local/share/cf-agent-wechat/venv`。
- 普通用户通过受控 sudo 读取 root-only Token；不得放宽 Token 权限。

生产 Token 权限必须保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

禁止执行 `chmod 644 auth-token`。详细流程、返回码和安全模型见
[微信登录管理](docs/login-management.md)。

## 验证边界

### 已实现并实机验证

- `docker/compose.cfserver.yaml` 配置校验、正式容器启动和健康状态。
- 容器内 Xvfb `1280x800x24`、`DISPLAY=:99`、fluxbox、dunst、WeChat 和
  agent-server 运行正常。
- `ENABLE_VNC=0`，且 x11vnc、websockify 不存在。
- 普通用户运行 `status.sh` 与 `login.sh`，包括登录状态识别、已登录短路、
  未登录流程、手机确认、WebSocket 成功事件和登录后状态复核。
- Docker socket 无权限时的 `sudo docker inspect` fallback、root-only Token
  受控读取和普通用户 venv 创建。
- 登录后 90 秒稳定性，健康监控未终止微信进程。
- Gateway 经 `cf-internal` 访问 `/health`、`/api/status/auth`、
  `/api/chats` 和 `/api/messages/{chat_id}`。
- `POST /api/messages/send` 使用 `chatId` 和 `text` 完成私聊、群聊文本发送，
  文本均实际出现在微信中。
- 群消息提供 `sender`、`senderName`、`chatId`、`timestamp` 和 `isMentioned`；
  普通群消息为 `false`，通过微信成员选择真正 @机器人时为 `true`。
- 私聊和群聊引用样本均可读取 `type=49` 与 `reply` 结构，并提取被引用消息摘要。
- 图片消息可读取 `type=3`、可用的 `localId` 和 `serverId`；media 接口已取得
  5712 字节的 JPEG 数据并通过文件签名检查。
- 机器人发送的文本会出现在消息列表中，可由 `isSelf` 或机器人发送者信息识别。

### 已实现但尚未实机验证

- 完全新设备在 SSH 终端显示二维码、手机扫码并完成登录。

当前实机验证通过的是“已信任设备 -> 手机确认 -> 登录成功”。不得把新设备二维码
场景写成已验证。

### 尚未完成生产实机验证

- 图片发送接口。
- 文件发送接口。

这一状态只说明尚无生产实机验证证据，不据此推断接口属于“已实现”或“规划中”。
图片接收与 media 读取也不能外推为图片或文件发送已经验证。

### 规划中或不在本次验证范围

`isMentioned`、`reply` 和 `isSelf` 是本项目提供的消息字段，不代表本项目负责权限判断、
下游防回环或 AI 调度。图片媒体读取不证明 Hermes 已读取图片，也不证明 Gateway 已完成
附件持久化。Gateway 内部权限、Hermes 和企业业务逻辑不属于本项目的实现与运维边界。

## 文档入口

- [文档索引](docs/README.md)
- [项目说明](docs/00_项目说明.md)
- [架构设计](docs/01_架构设计.md)
- [CFserver 正式部署](docs/deployment/cfserver-production.md)
- [微信登录管理](docs/login-management.md)
- [API 边界](docs/api.md)
- [生产运维](docs/operations.md)
- [故障排查](docs/troubleshooting.md)
- [验证总览](docs/validation.md)
- [2026-08-13 CFserver 生产验证](docs/validation/2026-08-13-cfserver-production.md)
- [2026-08-14 消息与媒体生产验证](docs/validation/2026-08-14-message-media-production.md)

上游镜像项目为 [thisnick/agent-wechat](https://github.com/thisnick/agent-wechat)。
上游源码不属于本仓库；升级镜像前应独立确认许可、版本兼容性与回滚基线。
