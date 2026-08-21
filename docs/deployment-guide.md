# Deployment Guide

本文用于在一台新的 Debian 主机上部署 CF_agent-wechat V1 Beta。生产入口是
`scripts/bootstrap-cfserver.sh` 和 `docker/compose.cfserver.yaml`。

## 1. 部署结果

部署完成后应得到：

```text
/opt/cf-agent-wechat/                  # 默认代码目录
└── docker/
    └── .env                           # bootstrap 创建时权限 0600

/srv/storage/cf-agent-wechat/          # 默认持久根
├── data/                              # agent 数据库和服务状态
├── wechat-home/                       # 微信用户目录和会话
└── secrets/
    └── auth-token                     # API Token
```

容器名默认 `cf-agent-wechat`，宿主监听默认 `127.0.0.1:6174`，并接入外部 Docker
网络 `cf-internal`。Compose 使用 `restart: unless-stopped`。

## 2. 主机前置条件

推荐至少 2 CPU、2 GB RAM、10 GB 可用磁盘。部署前确认：

- Debian 主机时间同步正常；
- 已安装 Docker Engine，Docker daemon 已启动；
- `docker compose version` 返回 Compose v2；
- 已安装 Bash、coreutils、util-linux（含 `flock`）、`curl`、`openssl`、Python 3 和
  `python3-venv`；
- 主机可访问批准的容器镜像仓库和 Python 包源，或已预置登录 venv；
- 有 root 或 sudo 权限；
- 已取得批准的代码版本和 `agent-wechat` 镜像 digest。

bootstrap 负责检查 Docker 和 Compose，不静默安装或升级它们。检查失败会非零退出并给出
缺失项。

## 3. 变量与默认值

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CF_AGENT_WECHAT_ROOT` | 脚本所在仓库根 | 标准安装路径为 `/opt/cf-agent-wechat` |
| `CF_GATEWAY_ROOT` | 仓库同级的 `cf-agent-gateway` | 仅检查并提示；不管理 Gateway |
| `CF_RUNTIME_ROOT` | `/srv/storage/cf-agent-wechat` | 持久数据、微信 HOME 和 Token 根目录 |
| `CF_RUNTIME_UID` / `CF_RUNTIME_GID` | `1000` / `1000` | `data`、`wechat-home` 的数值属主 |
| `CF_RUNTIME_MODE` | `700` | `data`、`wechat-home` 权限；生产固定为 `700` |
| `CF_STORAGE_UID` / `CF_STORAGE_GID` | `0` / `0` | runtime 根目录的数值属主 |
| `CF_SECRETS_UID` / `CF_SECRETS_GID` | `0` / `0` | `secrets` 和 Token 的数值属主 |
| `CF_BOOTSTRAP_TIMEOUT` | `180` | container、health、auth 每个阶段各自的等待窗口（秒） |
| `CF_BOOTSTRAP_POLL_INTERVAL` | `2` | 等待轮询间隔秒数 |
| `CF_BOOTSTRAP_HTTP_CONNECT_TIMEOUT` | `3` | 单次 HTTP 连接超时秒数 |
| `CF_BOOTSTRAP_HTTP_TIMEOUT` | `45` | 单次 HTTP 请求超时秒数；会限制在当前阶段剩余时间内 |

Compose 内部兼容变量 `CF_AGENT_WECHAT_RUNTIME_ROOT` 由 bootstrap 映射到
`CF_RUNTIME_ROOT`；运维时两者必须指向同一绝对路径。不要让 Compose 和管理脚本使用
不同的持久根。

这两个 runtime 变量会以未加引号的值写入 Compose dotenv，只支持由 ASCII 字母、数字和
`/ . _ - @ % + , = : ~` 组成的绝对路径。路径不得包含空白、`$`、`#`、单双引号或
反斜杠；例如使用 `/srv/storage/cf-agent-wechat`，不要使用包含 `$USER`、空格或 shell
转义的路径。bootstrap 会在调用 Docker 和写入 `docker/.env` 前拒绝不符合该约束的值。

现有生产 `docker/.env` 的权限只能是 `0600` 或受控组可读的 `0640`；bootstrap 新建时
固定使用 `0600`。不得使用 `0644` 或更宽权限。

## 4. 首次部署

把批准的仓库检出放在目标目录，并确保 shell 脚本使用 LF 换行。首次运行时，如果生产
环境文件尚不存在，必须通过环境变量提供固定到 digest 的镜像：

```bash
cd /opt/cf-agent-wechat
AGENT_WECHAT_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>' \
  ./scripts/bootstrap-cfserver.sh
```

推荐由具备 sudo 权限的普通运维用户直接执行；脚本只在需要时调用 sudo。不要使用裸
`sudo ./scripts/bootstrap-cfserver.sh` 丢失镜像或路径环境变量。

非标准布局示例：

```bash
CF_AGENT_WECHAT_ROOT=/opt/cf-agent-wechat \
CF_GATEWAY_ROOT=/opt/cf-agent-gateway \
CF_RUNTIME_ROOT=/srv/custom/cf-agent-wechat \
CF_SECRETS_UID="$(id -u)" \
CF_SECRETS_GID="$(id -g)" \
AGENT_WECHAT_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>' \
./scripts/bootstrap-cfserver.sh
```

已有有效 `docker/.env` 时不需要再次传入镜像变量。bootstrap 不会用新的 Token 或空目录
替换已有运行数据。
> [!WARNING]
> 默认 runtime 的 Token 由固定 sudo reader 以只读方式访问。使用非标准
> `CF_RUNTIME_ROOT` 时，`CF_SECRETS_UID` 必须是当前固定管理用户的 UID；该用户直接持有
> `secrets`（mode `700`）和 Token（mode `600`）。bootstrap 会把 runtime 与权限设置持久化
> 到固定的 `docker/.env`，后续 `status.sh` 和 `login.sh` 会安全读取，不需要重复导出路径。
> 自定义 Token 不支持 ACL/`0640`，也不要混用 root 与普通用户运行管理脚本。

## 5. bootstrap 执行内容

脚本依次执行：

1. 校验代码根、固定生产文件、绝对路径和必要命令；
2. 检查 Docker daemon、Compose v2 和 systemd 开机恢复状态；
3. 原子创建或安全读取 `docker/.env`，先持久化 runtime 与权限合同；
4. 拒绝不完整恢复，再创建或校验 `data`、`wechat-home`、`secrets` 和原 Token；
5. 使用固定项目名执行 Compose validate，并创建或复用 `cf-internal`；
6. 执行 `docker compose up -d agent-wechat`；
7. 有界等待 container running 和 Docker health healthy；
8. 验证实际 restart policy、bind mount 与只读 Token；
9. 验证宿主 `/health` 和带 Token 的 `/api/status/auth`。

运行目录默认要求：

| 路径 | 属主 | 权限 |
| --- | --- | --- |
| runtime root | `root:root` | `0755` |
| `data` | `1000:1000` | `0700` |
| `wechat-home` | `1000:1000` | `0700` |
| `secrets` | `root:root` | `0700` |
| `secrets/auth-token` | `root:root` | `0600` |

UID/GID `1000:1000` 是当前镜像中的 `wechat` 用户假设。升级镜像前必须重新核对。
发现已有目录类型、属主或权限不符合时，bootstrap 会停止，不会自动放宽权限或接管未知
数据。

### 镜像升级前核对容器用户

对每个候选镜像使用已批准、固定到 digest 的引用直接查询 `wechat` 用户，不使用 tag，也不
读取或 `source` 生产 `docker/.env`：

```bash
set -eu
AGENT_WECHAT_IMAGE='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>'
sudo docker pull "$AGENT_WECHAT_IMAGE"
WECHAT_UID="$(sudo docker run --rm --entrypoint /usr/bin/id \
  "$AGENT_WECHAT_IMAGE" -u wechat)"
WECHAT_GID="$(sudo docker run --rm --entrypoint /usr/bin/id \
  "$AGENT_WECHAT_IMAGE" -g wechat)"
[[ "$WECHAT_UID" =~ ^[0-9]+$ && "$WECHAT_GID" =~ ^[0-9]+$ ]]
printf 'wechat uid=%s gid=%s\n' "$WECHAT_UID" "$WECHAT_GID"
unset AGENT_WECHAT_IMAGE WECHAT_UID WECHAT_GID
```

根据输出在受控变更中设置权威 `docker/.env` 的 `CF_RUNTIME_UID` 和
`CF_RUNTIME_GID`。如果候选值与现有值不同，必须先制定 `data` 和 `wechat-home` 的数值
属主迁移与回滚步骤；bootstrap 不会自动 `chown` 已有数据。镜像 digest、两个 UID/GID
值和目录元数据必须作为同一批准变更处理，完成后重跑 bootstrap。上述命令只输出非敏感的
数值 UID/GID，不显示 `.env`、Token 或微信数据。

bootstrap 新建的 `docker/.env` 为调用它的固定管理用户所有，mode `0600`。若迁移时已有
root-owned `0600` 文件，必须选择一种一致策略：全程以 root 管理，或经审批改为固定运维
用户所有的 `0600`；需要运维组只读时可用 `root:<ops>` 与 `0640`。目录和文件不得被
group/other 写入，且 `status.sh`、`login.sh` 的调用用户必须能读取该文件。

## 6. 启动结果判读

bootstrap 返回 0 表示容器、Docker health、两个 API 入口可用，且 auth 响应可以解析；
它不保证微信已经登录。根据脚本报告的 auth 状态继续：

- `logged_in`：原会话已恢复，部署完成，不需要二维码；
- `logged_out` 或登录等待态：基础服务部署成功，但还需要人工扫码，按
  [QR Login Guide](qr-login-guide.md) 操作。
- 其他 auth 状态：即使 bootstrap 已完成基础设施检查，也必须运行 `status.sh` 并按
  [Troubleshooting](troubleshooting.md) 处理，不得视为生产可用。

独立复核：

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
```

状态脚本不会输出登录账号。返回 `0` 才表示生产所需的容器、health、API 和 auth 均已
通过。返回 `2` 表示需要登录；返回 `1` 或 `3` 应转到
[Troubleshooting](troubleshooting.md)。

## 7. Compose 静态复核

需要人工核对渲染结果时，使用与 bootstrap 相同的输入：

```bash
cd /opt/cf-agent-wechat
sudo env \
  -u AGENT_WECHAT_IMAGE \
  -u AGENT_WECHAT_BIND_IP \
  -u AGENT_WECHAT_PORT \
  -u AGENT_WECHAT_CONTAINER_NAME \
  -u CF_AGENT_WECHAT_RUNTIME_ROOT \
  -u CF_AGENT_WECHAT_STORAGE_ROOT \
  -u PROXY \
  -u RUST_LOG \
  -u COMPOSE_PROJECT_NAME \
  docker compose \
  --env-file docker/.env \
  --project-directory "$PWD" \
  --project-name cf-agent-wechat \
  -f docker/compose.cfserver.yaml \
  config --quiet
```

不要把 `docker/.env` 或渲染后的敏感配置贴入工单。Token 不应出现在环境文件中。

生产入口不支持覆盖 Compose 或 env 文件；固定文件和 `docker/.env` 是唯一权威输入。

镜像为运行微信客户端启用了 `seccomp=unconfined` 和 `SYS_PTRACE`，权限高于普通容器。
因此镜像必须使用批准的 digest，禁止再增加敏感宿主目录、Docker socket 或设备挂载，并将
该容器视为受限生产工作负载而不是通用执行环境。

## 8. 验收清单

- [ ] 代码 Commit 和镜像 digest 已记录并批准。
- [ ] Docker daemon 开机启动，Compose v2 可用。
- [ ] 生产 Compose 是 `docker/compose.cfserver.yaml`。
- [ ] 宿主端口只绑定 `127.0.0.1`。
- [ ] `data`、`wechat-home`、`secrets/auth-token` 位于批准的持久文件系统。
- [ ] 目录和 Token 权限符合表格，Token 未进入 `.env` 或日志。
- [ ] 容器为 running，Docker health 为 healthy。
- [ ] `/health` 成功，认证 API 可读。
- [ ] `status.sh` 返回 `0`，或返回 `2` 后已完成二维码登录。
- [ ] 已执行一次容器重启恢复验证并留下脱敏结果。
- [ ] 已安排主机重启和真实手机扫码的现场验证。

## 9. 重跑与失败语义

bootstrap 是幂等初始化入口。重复执行会复用现有目录、Token、网络、环境文件和会话，
不会归档或清空 runtime。任一步失败都返回非零，并保留当前目录、Token、容器和日志现场。
先修复错误再重跑，不要通过 `chmod 777`、删除数据库或生成新 Token 绕过检查。
