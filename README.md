# CF_agent-wechat

`CF_agent-wechat` 是 CF 系统的微信入口服务。它运行 `agent-wechat` 容器，管理微信
登录和本地会话，并向同一 Docker 网络中的调用方提供健康、认证、聊天和消息 API。

V1 Beta 生产基线采用持久会话：宿主机上的 `data/`、`wechat-home/` 和
`secrets/auth-token` 会跨容器和主机重启保留。服务重启后先尝试恢复原微信会话；只有
认证状态明确为 `logged_out` 时才重新扫码。部署或排障时不要删除这些目录来“重置”
服务。

## 生产基线

- 生产 Compose：`docker/compose.cfserver.yaml`
- 初始化入口：`scripts/bootstrap-cfserver.sh`
- 状态入口：`scripts/status.sh [--wait]`
- 二维码登录：`scripts/login.sh`
- 容器恢复策略：`restart: unless-stopped`
- 宿主监听：默认 `127.0.0.1:6174`，不直接暴露公网
- 容器网络：外部 Docker 网络 `cf-internal`
- 持久目录：默认 `/srv/storage/cf-agent-wechat`

`docker/docker-compose.yml` 和 `docker/README.md` 是历史实验配置，不是生产入口。

## 快速部署

前置条件是 Debian 主机已安装 Docker Engine、Docker Compose v2、`curl`、`openssl`、util-linux（含 `flock`）
和 Python 3，且批准的代码已位于目标目录。首次启动还需要一个固定到 digest 的镜像引用。

```bash
cd /opt/cf-agent-wechat
export AGENT_WECHAT_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>'
./scripts/bootstrap-cfserver.sh
```

脚本默认使用：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `CF_AGENT_WECHAT_ROOT` | bootstrap 所在仓库根；标准路径 `/opt/cf-agent-wechat` | 代码、Compose 和环境文件 |
| `CF_GATEWAY_ROOT` | 与仓库同级的 `cf-agent-gateway` | 仅做可选存在性提示；本仓不修改或启动 Gateway |
| `CF_RUNTIME_ROOT` | `/srv/storage/cf-agent-wechat` | `data`、`wechat-home` 和 `secrets` 的持久根目录 |

非标准路径可在同一次执行中覆盖：

```bash
CF_AGENT_WECHAT_ROOT=/opt/cf-agent-wechat \
CF_GATEWAY_ROOT=/opt/cf-agent-gateway \
CF_RUNTIME_ROOT=/srv/custom/cf-agent-wechat \
CF_SECRETS_UID="$(id -u)" \
CF_SECRETS_GID="$(id -g)" \
AGENT_WECHAT_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>' \
./scripts/bootstrap-cfserver.sh
```

bootstrap 会检查 Docker/Compose，创建并校验持久目录和 Token，创建 `cf-internal`，
验证 Compose，启动服务，然后检查容器、Docker health、`/health` 和认证 API。
bootstrap 会把最终 runtime、端口、容器名和 UID/GID/mode 持久化到固定 `docker/.env`；
`status.sh` 与 `login.sh` 会安全读取同一文件，后续无需重复导出路径。

安全重跑，不会轮换、清空或替换已有会话数据和 Token。

启动完成后检查登录状态：

```bash
./scripts/status.sh
```

- 返回 `0`：容器、health、API 和已恢复的登录会话均正常，无需扫码。
- 返回 `2`：服务正常但需要登录，运行 `./scripts/login.sh` 并扫描终端二维码。
- 返回 `1` 或 `3`：先按故障排查处理，不要用删除 runtime 的方式重试。

## 重启恢复

计划内重启后等待完整恢复：

```bash
./scripts/status.sh --wait
```

`--wait` 默认使用 180 秒总轮询预算等待容器运行、Docker health、`/health` 和认证状态。若最终为
`logged_out`，持久数据仍应保留，只需执行二维码登录：

```bash
./scripts/login.sh
./scripts/status.sh --wait
```

`unless-stopped` 不会推翻人工停止意图。被显式 `stop` 或 `down` 的服务需要重新执行
`./scripts/bootstrap-cfserver.sh`，由 bootstrap 使用权威配置启动并验证；不要裸跑
`docker compose up -d`。

## 数据与安全

以下三项构成同一恢复单元，备份和恢复时必须保持配套：

```text
/srv/storage/cf-agent-wechat/
├── data/
├── wechat-home/
└── secrets/
    └── auth-token
```

- `data` 和 `wechat-home` 默认由 UID/GID `1000:1000` 持有，权限 `0700`。
- 默认 runtime 的 `secrets` 为 `root:root 0700`，`auth-token` 为 `root:root 0600`。
- 自定义 runtime 的 `secrets` 和 Token 必须由固定管理用户持有，权限分别为 `0700` 和
  `0600`；完整 UID/GID/mode 合同见 [Deployment Guide](docs/deployment-guide.md)。
- Token 不写入 `.env`、日志、命令行或工单。
- 不要只恢复 `data` 而生成新 Token；这可能使已有数据库无法使用。
- 服务没有 TLS。宿主端口保持 loopback；容器调用方通过 `cf-internal` 访问
  `http://cf-agent-wechat:6174`。
- 容器因微信运行要求启用 `seccomp=unconfined` 和 `SYS_PTRACE`；镜像必须固定到批准
  digest，且禁止增加敏感宿主挂载或 Docker socket。


## 文档

- [Deployment Guide](docs/deployment-guide.md)
- [Deployment Audit](docs/deployment-audit.md)
- [Recovery Guide](docs/recovery-guide.md)
- [QR Login Guide](docs/qr-login-guide.md)
- [Troubleshooting](docs/troubleshooting.md)
- [API 边界](docs/api.md)
- [文档索引](docs/README.md)
