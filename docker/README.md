# CF_agent-wechat Docker 部署手册

> [!CAUTION]
> **V1 实验室部署，已废弃，非 CFserver 当前生产方案。**
> 本文包含 VNC/noVNC 等历史实验步骤，严禁在 CFserver 上作为生产 runbook 使用。
> 当前生产入口为
> [CFserver 正式部署](../docs/deployment/cfserver-production.md)。

本目录提供 V1 容器部署基线。镜像 `ghcr.io/thisnick/agent-wechat:0.11.15` 已在
Debian 13 环境完成基础部署和 API 验证，但仓库 Compose 与验证环境在重启策略和
VNC 修复资产上仍有差异。详细结论见
[V1 验证记录](../docs/05_V1验证结果.md)。

## 文件

| 文件 | 用途 |
| --- | --- |
| `docker-compose.yml` | Compose 基线 |
| `.env.example` | 非敏感环境变量模板 |
| `preflight.sh` | 只读部署前检查 |
| `.gitignore` | 排除 token、运行数据、备份和本地环境文件 |
| `.gitattributes` | 保证 shell 脚本使用 LF |

`docker/fix-vnc.sh` 和 `cf-wechat-vnc-fix.service` 已用于验证环境，但当前不在
仓库中。它们不能被视为本目录现有部署资产。

## 已验证环境

| 项目 | 基线 |
| --- | --- |
| 虚拟化 | VMware Workstation |
| 操作系统 | Debian 13 Trixie，kernel 6.12 |
| Docker | Docker CE / Docker Engine 29.x |
| Compose | Docker Compose v2 |
| 镜像 tag | `ghcr.io/thisnick/agent-wechat:0.11.15` |
| 运行镜像 | tag 解析后固定的 `sha256` digest |
| Compose 项目 | `cf-wechat-lab` |
| 容器名称 | `cf-agent-wechat-lab` |
| 建议部署目录 | `~/docker/agent-wechat` |

建议至少 2 CPU、2 GB RAM、10 GB 可用磁盘。当前镜像假设容器内 `wechat` 用户
UID 为 `1000`；每次升级 digest 后重新确认。

## 网络与安全

- 服务监听容器内 `0.0.0.0:6174`。
- 本 V1 实验模板将服务发布到宿主机 `127.0.0.1:6174`。
- noVNC 通过 `/vnc/` 访问，不对外开放 5900 或 6080。
- 服务没有 TLS；远程访问使用 SSH 隧道。
- 不得把 6174 暴露到公网。
- 默认不启用透明代理，也不授予 `NET_ADMIN`。
- Docker 配置使用 `seccomp=unconfined` 和 `SYS_PTRACE`，部署前应接受相应风险。

当前 Compose 还配置了以下运行保护：

- /health 检查间隔 30 秒、超时 5 秒、重试 5 次、启动宽限期 90 秒。
- 日志驱动为 json-file，单文件最大 20 MB，最多保留 3 个文件。
- 容器停止宽限期为 30 秒。
- bind mount 要求宿主机路径预先存在，不由 Compose 隐式创建。

示例隧道：

```bash
ssh -N -L 6174:127.0.0.1:6174 <deploy-user>@<server-host>
```

## 持久化

| 宿主机路径 | 容器路径 | 内容 |
| --- | --- | --- |
| `./data` | `/data` | 数据库和服务元数据 |
| `./wechat-home` | `/home/wechat` | 微信账号、消息、媒体和缓存 |
| `./secrets/auth-token` | `/data/auth-token` | API 认证和数据库加密 token |

token 不放在 `.env`。已有数据时，`data/` 与原 `secrets/auth-token` 必须同时
备份和恢复；不得生成新 token 替代原 token。详见
[运维与交接](../docs/operations.md)。

## 首次部署

### 1. 准备目录

```bash
mkdir -p ~/docker/agent-wechat
cd ~/docker/agent-wechat
cp -n .env.example .env
mkdir -p data wechat-home secrets backups
```

将本目录的 Compose、环境模板、preflight 和 README 放入部署目录。如果从备份
恢复，先停止并按恢复流程操作，不要执行下一步的 token 生成命令。

### 2. 生成 token

仅在 `data/` 为空且 `secrets/auth-token` 不存在的全新部署中执行：

```bash
test -z "$(find data -mindepth 1 -print -quit)" && \
  (umask 077; set -o noclobber; openssl rand -hex 32 > secrets/auth-token)
```

### 3. 固定镜像 digest

```bash
docker pull ghcr.io/thisnick/agent-wechat:0.11.15
docker image inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/thisnick/agent-wechat:0.11.15
```

把完整的 `ghcr.io/thisnick/agent-wechat@sha256:...` 写入 `.env` 的
`AGENT_WECHAT_IMAGE`。不要只写 tag，不要使用 `latest`。完整 digest 另存于
受控部署记录。

### 4. 权限与预检

```bash
chmod 700 data wechat-home secrets backups
chmod 600 secrets/auth-token
chmod 755 preflight.sh
id -u
id -g
./preflight.sh
```

预检应以部署用户执行，不使用 root。任何 `[FAIL]` 都应先解决。若部署用户 UID
不是 `1000`，应设计 bind mount 属主或 ACL，不能使用全局可写权限。

### 5. 配置与启动

```bash
docker compose --env-file .env config
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

## 启动验证

```bash
docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:6174/health
docker compose --env-file .env logs --tail=200 agent-wechat

TOKEN="$(cat secrets/auth-token)"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:6174/api/status/auth
unset TOKEN
```

预期容器最终为 `healthy`，`/health` 返回成功。认证接口显示 `logged_out` 时，
需要完成微信/agent-wechat 登录流程并再次查询状态。已验证成功状态为
`status=logged_in`。

## 微信初始化

```text
/api/ws/login
    ↓
login flow
    ↓
login_success
    ↓
userId
    ↓
contacts / chats / messages API 可用
```

GUI 登录不等于 agent-wechat 初始化完成。接口和验证能力见
[API 文档](../docs/api.md)。

## 自动恢复与 VNC

### Verified

验证环境使用 `restart: unless-stopped`。Docker 重启后容器自动恢复、container
health 正常且 VNC 可访问。微信客户端需要重新登录；重新登录后 agent-server 状态
恢复正常，`/api/status/auth` 返回 `status=logged_in`。

### Known Issue

仓库 `docker-compose.yml` 当前使用 `restart: "no"`，所以直接部署此文件不会
获得相同的容器自动恢复行为。本次文档工作没有修改 Docker 运行逻辑。

agent-wechat 默认 VNC 交互状态不稳定。验证环境使用：

- `docker/fix-vnc.sh`
- `/etc/systemd/system/cf-wechat-vnc-fix.service`

恢复 interactive x11vnc。上述文件未包含在仓库中；新部署必须从受控运维来源取得
后才能复现 VNC 恢复结论。

## 停止与日志

保留数据停止：

```bash
docker compose --env-file .env down
```

查看日志：

```bash
docker compose --env-file .env logs --tail=200 agent-wechat
journalctl -u cf-wechat-vnc-fix.service -n 100 --no-pager
```

不要删除 `data/`、`wechat-home/` 或 `secrets/auth-token` 处理一般启动故障。
完整排查流程见 [故障排查](../docs/troubleshooting.md)。
