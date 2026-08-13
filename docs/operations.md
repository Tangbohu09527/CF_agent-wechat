# CFserver 生产运维

## 适用范围

本文只适用于 CFserver 上的 `CF_agent-wechat` 正式部署。当前生产基线为：

- 工作目录：`/opt/cf-agent-wechat`
- 正式部署文件：`docker/compose.cfserver.yaml`
- 容器名：`cf-agent-wechat`
- Docker 网络：`cf-internal`
- 容器内显示环境：`DISPLAY=:99`，Xvfb `1280x800x24`
- 运行组件：Xvfb、fluxbox、dunst、WeChat Linux 客户端、agent-server
- `ENABLE_VNC=0`

`docker/docker-compose.yml` 是实验室或验证配置，不是 CFserver 正式配置。本文中的
Compose 命令必须在仓库根目录执行，并显式指定正式部署文件。

> **生产警告：不得在 CFserver 上执行不带 `-f` 的 `docker compose down`。**
> 裸命令可能选中实验配置，导致错误的容器或资源被停止、删除。

## 日常检查

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker inspect --format \
  '{{.State.Status}} / {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
  cf-agent-wechat
./scripts/status.sh
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200 agent-wechat
```

正常结果应满足：

- 容器处于 `running`，健康状态为 `healthy`，没有持续重启。
- `status.sh` 显示 `logged_in`；`logged_out` 表示服务可用但微信需要登录。
- 日志中 Xvfb、fluxbox、dunst、WeChat 和 agent-server 没有持续报错。
- 容器内没有 x11vnc 或 websockify 进程。
- `cf-internal` 网络仍连接到容器，Gateway 可通过
  `http://cf-agent-wechat:6174` 访问服务。

需要直接复核容器内健康端点时执行：

```bash
sudo docker exec cf-agent-wechat \
  curl --fail --silent --show-error http://127.0.0.1:6174/health
```

## 启动、停止与重启

启动或应用当前配置：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml up -d
sudo docker compose -f docker/compose.cfserver.yaml ps
```

停止正式部署：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml down
```

仅重启服务时也必须指定正式 Compose：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml restart agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
./scripts/status.sh
```

重启容器不等于微信会话一定恢复。`status.sh` 返回 `logged_out` 时按“微信登录”章节
重新登录；不要通过删除数据目录或更换 Token 处理登录失效。

## 重建与升级

正式配置使用外部镜像，不在 CFserver 上执行本地镜像构建。变更镜像版本或重建容器前，
先确认受控变更记录和回滚目标，并按“备份与恢复”保存同一时间点的持久化数据和 Token。

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml config --quiet
sudo docker compose -f docker/compose.cfserver.yaml pull agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml up -d --force-recreate agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
./scripts/status.sh
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200 agent-wechat
```

不要使用 `latest` 替代受控版本，也不要在未验证数据兼容性时只切换镜像。

## 微信登录

登录管理由普通用户在仓库根目录执行：

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
./scripts/login.sh
```

已登录时 `login.sh` 会短路退出；未登录时会启动登录流程并监听 WebSocket 登录事件。
当前实机验证通过的是“已信任设备 -> 手机确认 -> 登录成功”。完全新设备在 SSH 终端
显示二维码并扫码的路径已实现，但尚未完成实机验证。

不要以 `sudo ./scripts/login.sh` 运行登录工具，也不要打印 Token。详细流程、返回码和
验证边界见 [微信登录管理](login-management.md)。

## CFserver 重启后检查

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker inspect --format \
  '{{.State.Status}} / {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
  cf-agent-wechat
./scripts/status.sh
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200 agent-wechat
```

若容器未自动运行：

```bash
sudo docker compose -f docker/compose.cfserver.yaml up -d
```

容器健康后再处理微信登录。`logged_out` 执行 `./scripts/login.sh`；
`app_not_running` 或容器 `unhealthy` 应先查日志，不要反复触发登录。

## 持久化、备份与恢复

正式 Compose 已确认的持久化对象只有：

| 宿主机路径 | 容器路径 | 用途 |
| --- | --- | --- |
| `/srv/storage/cf-agent-wechat/data` | `/data` | agent-server 持久化数据 |
| `/srv/storage/cf-agent-wechat/wechat-home` | `/home/wechat` | 微信客户端用户目录 |
| `/srv/storage/cf-agent-wechat/secrets/auth-token` | `/data/auth-token` | API Token，只读挂载 |

Token 权限必须保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

严禁使用 `chmod 644`。不要把 Token 写入命令行、环境输出、日志、工单或普通用户目录。

备份原则：

1. 在批准的维护窗口记录当前镜像版本、容器状态和时间点。
2. 使用正式 Compose 停止写入：
   `sudo docker compose -f docker/compose.cfserver.yaml down`。
3. 使用组织批准的备份工具，将上述三个对象作为同一时间点的备份集处理。
4. 备份必须加密、限制访问，并按组织策略保存；本文不假定备份目标目录或工具。
5. 使用正式 Compose 恢复服务并重新执行日常检查。

恢复原则：

1. 保留故障现场，确认备份时间点和目标镜像兼容。
2. 使用正式 Compose 停止服务，确认持久化目录没有并发写入。
3. 从同一备份集恢复 `data`、`wechat-home` 和原 `auth-token`，不要混用时间点。
4. 恢复原属主和权限，尤其保持 secrets 目录 `root:root 700`、Token
   `root:root 600`。
5. 执行 Compose 配置校验、启动、健康检查和登录状态复核。

不得通过删除 `agent.db`、生成新 Token、放宽文件权限或反复重启来掩盖恢复失败。

## 回滚原则

- 回滚前保留当前故障现场和去敏日志。
- 镜像、Compose 配置、持久化数据和 Token 必须按兼容的受控基线整体判断。
- 优先回到最近一次已验证的镜像和部署配置；涉及数据格式变化时，恢复匹配的同一时间点
  备份集。
- 回滚后依次验证容器健康、`status.sh`、必要时的 `login.sh`，以及 Gateway 经
  `cf-internal` 对健康、认证、聊天和消息接口的访问。
- 未完成上述复核前，不宣告回滚成功。

## 安全边界

- 6174 提供 HTTP/WebSocket，不应暴露到公网。
- Docker daemon 和 `docker` 组等同于高权限访问；不因日常检查而把普通用户加入
  `docker` 组。脚本在 Docker socket 无权限时会受控调用 `sudo docker inspect`。
- 日志、截图和故障单不得包含 Token、二维码、账号标识、联系人、聊天正文、群聊标识
  或服务器地址。
- Gateway 只通过 `cf-internal` 调用本服务；Gateway 内部权限与 Hermes 调度不属于
  本项目运维范围。

## 交接清单

- [ ] 正式目录、生产 Compose 文件和容器名已明确。
- [ ] 所有正式 Compose 命令均显式包含
  `-f docker/compose.cfserver.yaml`，并已强调禁止裸用 `docker compose down`。
- [ ] 当前受控镜像版本、变更历史和回滚目标已有记录。
- [ ] `data`、`wechat-home`、`auth-token` 的备份责任、保留策略和恢复演练结果明确。
- [ ] secrets 目录和 Token 权限分别保持 `root:root 700`、`root:root 600`。
- [ ] 容器健康、微信登录和登录管理责任人明确。
- [ ] `cf-internal` 网络和 Gateway 调用地址已交接。
- [ ] 已知验证边界已交接：已信任设备手机确认通过；完全新设备 SSH 二维码扫码尚未
  实机验证。

## 历史实验（已废弃、非当前生产方案）

早期实验环境曾使用 VNC/noVNC、x11vnc、websockify、宿主桌面 X11 挂载、XFCE、
RDP 和 `DISPLAY=:10.0` 进行 GUI 调试。这些方式已从 CFserver 正式运行链路中移除，
不得作为生产启动、登录、恢复或健康检查步骤，也不需要登录宿主桌面操作微信。

需要追溯实验结论时只查阅带有“历史实验”标记的验证记录；不得把实验配置
`docker/docker-compose.yml` 或旧桌面修复服务应用到生产环境。
