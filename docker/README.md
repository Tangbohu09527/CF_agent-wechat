# CF_wechat-lab 部署准备

本目录提供 CF_agent-wechat 的独立 V1 测试部署配置。当前任务只生成配置文件，没有连接目标机器、安装 Docker、启动容器、登录微信或连接 Hermes。

## 目标环境

| 项目 | 值 |
| --- | --- |
| 主机 | 由私有部署记录指定 |
| 操作系统 | Debian 13 |
| 部署目录 | `~/docker/agent-wechat` |
| Compose 项目 | `cf-wechat-lab` |
| 容器名称 | `cf-agent-wechat-lab` |
| 测试镜像 | 从 `ghcr.io/thisnick/agent-wechat:0.11.15` 解析并锁定的 digest |

测试镜像使用已发布的版本标签，不使用 `latest`。版本标签仍可能被上游重建，因此第一次启动前必须解析镜像 digest，并将 `.env` 中的 `AGENT_WECHAT_IMAGE` 锁定为 `ghcr.io/thisnick/agent-wechat@sha256:...`。

发布镜像 `0.11.15` 对应上游提交 `3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616`；本地源码基线为 `f72e7552c04f8ffa0eab22f888985a4c79ee3a91`。两者之间的 3 个提交涉及 CI 和 OpenClaw 适配，不涉及 `docker/` 或 `packages/agent-server-rust/`，因此核心容器运行时源码一致。如果后续要求逐提交验证本地源码快照，仍应在独立、明确授权的阶段构建并记录专用镜像标签和 digest。

## 文件说明

- `docker-compose.yml`：CF_wechat-lab 独立 Compose 配置。
- `.env.example`：非敏感环境变量模板。
- `.gitignore`：防止 token、运行数据、备份和本地 `.env` 被提交。
- `.gitattributes`：确保部署脚本在 Debian 上使用 LF 换行。
- `preflight.sh`：只读部署前检查脚本；不安装软件、不修改权限、不启动容器。
- `README.md`：部署前提和后续验证步骤。

认证 token 不放入 `.env`。服务同时使用该 token 进行 API 认证和内部 `agent.db` 加密。源码在无法使用当前 token 打开或迁移已有数据库时，会删除 `agent.db`、WAL、SHM 后重新创建数据库；因此 token 与数据必须作为一个备份单元，存在数据后不得直接轮换或丢失 token。

## Compose 设计

- API 服务固定监听容器内 `0.0.0.0:6174`。
- 默认只绑定目标机回环地址 `127.0.0.1:6174`，通过 SSH 隧道从受信任终端访问。
- noVNC 通过同一个 `6174` 端口下的 `/vnc/` 路径访问，不开放 `5900` 或 `6080`。
- `/health` 用作容器健康检查，启动宽限期为 90 秒。
- 日志使用 Docker `json-file`，单文件 20 MB，最多保留 3 个文件。
- 数据使用相对部署目录的 bind mounts，便于检查和备份；所有宿主机路径必须预先创建，Compose 不会自动创建。
- 默认不配置透明代理，因此不授予 `NET_ADMIN`。
- V1 初始阶段使用 `restart: "no"`，避免宿主机重启后未经审批自动恢复微信客户端；完成稳定性验证后再评审自动重启策略。

## 部署前提

以下内容仅说明后续执行条件，本次没有修改目标系统：

- Debian 13 已有可用的 Docker Engine 和 Docker Compose v2，且 Compose 支持 `bind.create_host_path: false`；目标机必须以 `docker compose config` 实测确认。
- 部署用户可以使用 Docker，并拥有部署目录及其子目录的读写权限。Docker daemon 或 `docker` 组访问等价于宿主机 root 权限，应作为高权限运维授权管理。
- 当前固定镜像假设容器内 `wechat` 用户为 UID `1000`。每次更新镜像 digest 后均应重新确认；如果部署用户不是 UID `1000`，先停止部署并单独设计 `wechat-home` 的属主或 ACL，不要用全局可写权限绕过。
- 主机至少有 2 GB RAM、10 GB 可用磁盘；建议 2 CPU 核心。
- Docker 运行环境允许 `seccomp=unconfined` 和 `SYS_PTRACE`。
- 主机能够访问 GHCR 以拉取镜像，并能访问微信所需的外部网络服务。

## 端口需求

| 方向 | 协议/端口 | 用途 |
| --- | --- | --- |
| 入站 | TCP `22` | SSH 管理和本地端口转发，通常为目标机已有管理入口 |
| 回环 | TCP `6174` | REST API、登录 WebSocket、noVNC WebSocket，不对局域网直接开放 |
| 入站 | TCP `5900`、`6080` | 不开放，仅在容器内部使用 |
| 出站 | TCP `443` | 拉取 GHCR 镜像及 HTTPS 访问 |
| 出站 | DNS、微信客户端网络 | 微信登录和消息通信，实际目标由微信客户端决定 |

默认配置不需要新增入站防火墙端口。服务本身没有 TLS，token 会以明文 HTTP/WebSocket 传输，因此管理终端应通过 SSH 隧道访问。若后续确需从实验网直接连接，可将 `AGENT_WECHAT_BIND_IP` 改为目标机的局域网地址，但必须同时将 TCP `6174` 严格限制到指定源地址，或先部署 HTTPS/WSS 终止层。不能暴露到公网。本配置未修改防火墙。

## 持久化目录

在目标部署目录中使用以下路径：

| 宿主机路径 | 容器路径 | 内容 |
| --- | --- | --- |
| `./data` | `/data` | `agent.db`、服务状态和内部元数据 |
| `./wechat-home` | `/home/wechat` | 微信账号数据、消息数据库、媒体和缓存 |
| `./secrets/auth-token` | `/data/auth-token` | API 与数据库加密 token，只读挂载 |

这些目录可能包含企业聊天、联系人、媒体和认证材料，应限制访问并纳入后续备份方案。`secrets/auth-token` 与 `data/` 必须同时备份、同时恢复，不能只保留其中之一。停止容器时不要删除目录，也不要使用会清理运行数据的操作。

## 部署流程

下列命令仅用于后续获得部署授权的阶段，当前未执行。

### 步骤 1：创建部署目录

```bash
mkdir -p ~/docker/agent-wechat
cd ~/docker/agent-wechat
```

将本目录中的 `docker-compose.yml`、`.env.example`、`.gitignore`、`.gitattributes`、`preflight.sh` 和 `README.md` 放入该部署目录。

### 步骤 2：准备数据目录、token 和镜像引用

先确认这是全新部署还是已有数据恢复：

- 全新部署：`data/` 为空且 `secrets/auth-token` 不存在，才允许生成新 token。
- 已有数据恢复：必须从同一个备份集中同时恢复 `data/` 和 `secrets/auth-token`，不要执行 token 生成命令。

全新部署使用以下命令。`noclobber` 会拒绝覆盖已存在的 token；`data/` 非空时也不会生成新 token：

```bash
cp -n .env.example .env
mkdir -p data wechat-home secrets backups
test -z "$(find data -mindepth 1 -print -quit)" && \
  (umask 077; set -o noclobber; openssl rand -hex 32 > secrets/auth-token)
docker pull ghcr.io/thisnick/agent-wechat:0.11.15
docker image inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/thisnick/agent-wechat:0.11.15
```

将完整的 `ghcr.io/thisnick/agent-wechat@sha256:...` 引用写入 `.env` 的 `AGENT_WECHAT_IMAGE`，确认 `AGENT_WECHAT_BIND_IP=127.0.0.1`，并将 digest 记录在私有部署日志中。

如果上述 token 命令失败，立即停止并检查现有数据，不要删除或覆盖文件后重试。

### 步骤 3：设置权限

```bash
chmod 700 data wechat-home secrets backups
chmod 600 secrets/auth-token
chmod 755 preflight.sh
id -u
id -g
```

预期部署用户 UID 为 `1000`。如果不是 `1000`，不要继续启动，应先完成 bind mount 属主或 ACL 的专项设计。

### 步骤 4：运行部署前检查

```bash
./preflight.sh
```

脚本只读取当前状态，不会调用 `sudo`、修改系统、创建目录或启动容器。只有最终输出 `[PASS] Preflight completed successfully` 时才可继续；任何 `[FAIL]` 都应先人工处理并重新检查。端口检查是瞬时结果，执行启动命令前仍需避免并发占用。

### 步骤 5：验证 Compose 配置

```bash
docker compose --env-file .env config
```

该命令是 Compose 语法、变量插值和当前 Compose v2 兼容性的最终检查。

### 步骤 6：启动 V1 测试

完成配置评审和变更审批后，才执行：

```bash
docker compose --env-file .env pull
docker compose --env-file .env up -d
```

## 启动后的验证步骤

以下验证先确认基础设施，不进行微信登录：

1. 检查容器和健康状态：

   ```bash
   docker compose --env-file .env ps
   ```

   预期服务最终显示为 `healthy`，且没有反复重启。

2. 检查公开健康接口：

   ```bash
   curl --fail --silent --show-error http://127.0.0.1:6174/health
   ```

   预期返回 `{"status":"ok"}`。

3. 检查启动日志：

   ```bash
   docker compose --env-file .env logs --tail=200 agent-wechat
   ```

   确认 Rust 服务监听 `6174`，并记录微信进程、Xvfb、AT-SPI 或数据库初始化错误。

4. 使用 token 检查认证接口，但不触发登录：

   ```bash
   TOKEN="$(cat secrets/auth-token)"
   curl --fail --silent --show-error \
     -H "Authorization: Bearer ${TOKEN}" \
     http://127.0.0.1:6174/api/status/auth
   unset TOKEN
   ```

   未登录时可返回 `logged_out` 或其他未登录状态；此步骤不扫描二维码。

5. 在受信任管理终端建立 SSH 隧道：

   ```bash
   ssh -N -L 6174:127.0.0.1:6174 <deploy-user>@<server-host>
   ```

   隧道建立后，在该管理终端打开 `http://127.0.0.1:6174/vnc/`，输入 token，确认虚拟桌面可见。不要在本阶段扫描登录二维码。token 可能进入浏览器会话和 URL，应使用受控终端并避免记录到共享日志。

6. 检查持久化目录已产生预期数据，并记录目录权限和磁盘占用：

   ```bash
   ls -ld data wechat-home secrets
   du -sh data wechat-home
   ```

7. 基础设施验证通过后，停止点设为“容器健康、微信未登录”。微信登录、消息收发、文件能力和掉线恢复属于下一项明确授权的 V1 验证任务。

如需停止容器并保留数据：

```bash
docker compose --env-file .env down
```

## 代理说明

首轮验证保持 `PROXY=`。如果后续必须启用透明代理，需要单独评审代理凭据保存方式，并在 Compose 的 `cap_add` 中增加 `NET_ADMIN`。不要在未评审时直接启用。
