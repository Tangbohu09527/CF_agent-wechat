# 新设备部署引导

本文说明如何仅使用本仓库资料，在一台全新的 Debian 主机上准备并启动
`CF_agent-wechat` forced-QR 目标基线。完成首次部署后，日常操作转到
[CFserver 正式部署](cfserver-production.md)和[生产运维](../operations.md)。

> [!WARNING]
> 本流程仅适用于 `feat/forced-qr-login@9cb7163` 及其后续合入版本。
> 本文审计的 `main` 代码基线 `96264e2` 不包含所需脚本和 runtime 版 Compose，必须在第 4 节代码能力门禁处
> 停止。目标实现已完成本地自动化验证；截至 2026-08-20，真实手机扫码和 Debian
> 启动窗口的 worker stop gate 仍未完成 CFserver 实机验证。

> [!CAUTION]
> 不得复制 `docker/.env.example`，它是历史实验模板。不得用 `docker compose up`、
> `restart` 或 `down` 代替生命周期脚本，也不得恢复旧微信 runtime 为活跃会话。

## 1. 部署前输入

准备以下受控输入：

- Debian 13 主机和具备批准 sudo 权限的普通运维账号；
- 本仓库地址，以及包含 forced-QR 实现的批准 Commit 或 Tag；
- 经批准、按 digest 固定的 agent-wechat 镜像引用；
- 出站访问代码、Docker 软件源、镜像仓库和 Python 包源的能力；
- 手机微信，以及至少 80 列宽的交互式 SSH 终端；
- 微信账号中至少有一个经批准、可由 API 读取的测试会话，用于 messages 放行验证；
- 三个外部调用方控制路径：Compose 文件、环境文件和 Compose 项目目录；
- 维护窗口，以及停机期间消息可能无法补拉的业务确认。

外部 Compose 只需满足本项目契约：它定义名为 `wechat-worker` 的服务，并允许生命周期
脚本停止、查询和启动该服务。本仓库不依赖其内部实现文档。

先判断数据场景：

- **全新安装**：没有 runtime、legacy `data`/`wechat-home`、归档和旧 Token。
- **迁移或恢复**：保留原 Token，并从同一备份集恢复需要留存的旧目录；旧目录只会在
  首次启动时归档，不会恢复成活跃微信会话。

已有任何数据时不得生成替代 Token。

## 2. Debian 环境准备

确认系统、架构、时间和空间：

```bash
cat /etc/os-release
dpkg --print-architecture
timedatectl status
df -h /opt /srv /var/lib/docker 2>/dev/null || df -h /
```

确认镜像支持当前架构，并至少预留 10 GiB 空间。安装基础工具：

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates curl git openssl python3 python3-venv sudo util-linux gawk
```

`util-linux` 提供 `flock`。登录工具首次运行会在普通用户目录创建 Python venv；不要用
`sudo ./scripts/start-qr-login.sh`，也不要只为运行脚本把用户加入 `docker` 组。

## 3. 安装 Docker Engine

使用 Docker 官方 Debian 软件源安装 Engine 和 Compose v2：

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

验证：

```bash
sudo docker version
sudo docker info
sudo docker compose version
```

必须使用 `docker compose` v2，不使用旧的 `docker-compose`。

## 4. 部署代码并执行能力门禁

```bash
APPROVED_VERSION='<APPROVED_COMMIT_OR_TAG>'
sudo install -d -o "$USER" -g "$(id -gn)" -m 0755 /opt/cf-agent-wechat
git clone https://github.com/Tangbohu09527/CF_agent-wechat.git \
  /opt/cf-agent-wechat
cd /opt/cf-agent-wechat
git checkout --detach "$APPROVED_VERSION"
git rev-parse --verify HEAD
git status --short
unset APPROVED_VERSION
```

`git status --short` 应无输出。随后执行强制能力门禁：

```bash
set -eu
test -x scripts/start-qr-login.sh
test -x scripts/stop-qr-runtime.sh
test -f scripts/qr-runtime-common.sh
grep -q -- '--force-qr' scripts/login.sh
grep -q 'newAccount=true' scripts/qr_login.py
grep -q 'on-failure:3' docker/compose.cfserver.yaml
grep -q 'CF_AGENT_WECHAT_RUNTIME_ROOT' docker/compose.cfserver.yaml
```

任一命令失败都表示代码与本文不匹配。停止部署，切换到批准的实现版本；不得自己补脚本、
改 Compose 或退回旧的普通登录流程。本文审计的 `main` 代码基线 `96264e2` 预期无法通过该门禁。

## 5. 固定镜像并核对容器用户

```bash
CANDIDATE_IMAGE='ghcr.io/thisnick/agent-wechat:<APPROVED_TAG>'
sudo docker pull "$CANDIDATE_IMAGE"
sudo docker image inspect \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' \
  "$CANDIDATE_IMAGE"
unset CANDIDATE_IMAGE
```

从输出中选择经批准的完整 digest，记为：

```text
ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>
```

核对镜像内 `wechat` 用户：

```bash
IMAGE_REF='ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>'
WECHAT_UID="$(sudo docker run --rm --entrypoint /usr/bin/id "$IMAGE_REF" -u wechat)"
WECHAT_GID="$(sudo docker run --rm --entrypoint /usr/bin/id "$IMAGE_REF" -g wechat)"
printf 'wechat uid=%s gid=%s\n' "$WECHAT_UID" "$WECHAT_GID"
```

UID/GID 必须是十进制整数。目标脚本在没有旧目录可继承时默认使用 `1000:1000`；若镜像
不同，首次启动及之后每次生命周期操作都必须显式设置：

```bash
export CF_AGENT_WECHAT_RUNTIME_UID="$WECHAT_UID"
export CF_AGENT_WECHAT_RUNTIME_GID="$WECHAT_GID"
export CF_AGENT_WECHAT_RUNTIME_MODE=700
```

这些值不是凭据，但应进入受控部署记录。镜像 digest 变化后重新核对。

## 6. 准备存储与 Token

目标布局由生命周期脚本维护：

```text
/srv/storage/cf-agent-wechat/
├── runtime/
│   ├── data/
│   └── wechat-home/
├── session-archive/
└── secrets/
    └── auth-token
```

全新安装只预创建存储根和 secrets；不要手工创建空 legacy `data`/`wechat-home`：

```bash
sudo install -d -o root -g root -m 0755 /srv/storage/cf-agent-wechat
sudo install -d -o root -g root -m 0700 \
  /srv/storage/cf-agent-wechat/secrets
```

仅在确认是全新安装时生成 Token：

```bash
sudo sh -eu -c '
root=$1
token=$root/secrets/auth-token
for path in \
  "$root/runtime" "$root/data" "$root/wechat-home" "$root/session-archive"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    printf "Refusing fresh Token creation: path exists: %s\n" "$path" >&2
    exit 1
  fi
done
if [ -e "$token" ] || [ -L "$token" ]; then
  printf "%s\n" "Refusing fresh Token creation: Token path exists." >&2
  exit 1
fi
umask 077
tmp="${token}.new.$$"
trap '\''rm -f -- "$tmp"'\'' 0 1 2 15
openssl rand -hex 32 > "$tmp"
grep -Eq "^[0-9a-f]{64}$" "$tmp"
chown root:root "$tmp"
chmod 0600 "$tmp"
ln "$tmp" "$token"
rm -f -- "$tmp"
trap - 0 1 2 15
' sh /srv/storage/cf-agent-wechat
```

迁移或恢复场景跳过生成命令，恢复原 `auth-token` 和需要保留的旧目录。若恢复的是 legacy
`data`/`wechat-home`，保持它们位于存储根且不要同时创建 `runtime`；首次启动会将它们放入
同一个归档。`runtime` 与任一 legacy 目录并存属于 mixed layout，脚本会 fail-fast。

只检查 Token 元数据：

```bash
sudo stat -c '%F %U:%G %a %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
```

预期 secrets 为 `root:root 700`，Token 为非符号链接普通文件、`root:root 600`。禁止
`cat`、计算指纹、复制到用户目录或执行 `chmod 644`。

## 7. 创建生产环境文件

forced-QR 目标基线使用 `/opt/cf-agent-wechat/docker/.env`，不是仓库根 `.env`，也不是
`docker/.env.example`。

```bash
cd /opt/cf-agent-wechat
sudo install -o root -g root -m 0600 /dev/null docker/.env
sudoedit docker/.env
```

写入非敏感 Compose 输入并替换 digest：

```dotenv
AGENT_WECHAT_IMAGE=ghcr.io/thisnick/agent-wechat@sha256:<APPROVED_DIGEST>
AGENT_WECHAT_BIND_IP=127.0.0.1
AGENT_WECHAT_PORT=6174
AGENT_WECHAT_CONTAINER_NAME=cf-agent-wechat
PROXY=
RUST_LOG=info
```

- Token 不写入 `.env`。
- 新设备基线将宿主端口绑定到 loopback；容器间调用使用 `cf-internal`。
- 服务没有 TLS，不得将 6174 暴露公网。
- 环境文件必须是绝对路径上的普通非符号链接文件。

## 8. 配置 worker 控制契约

在普通用户的当前维护会话中显式设置三个受控绝对路径：

```bash
export CF_AGENT_GATEWAY_COMPOSE_FILE='<APPROVED_ABSOLUTE_COMPOSE_FILE>'
export CF_AGENT_GATEWAY_ENV_FILE='<APPROVED_ABSOLUTE_ENV_FILE>'
export CF_AGENT_GATEWAY_PROJECT_DIR='<APPROVED_ABSOLUTE_PROJECT_DIR>'
```

确认：

- Compose 文件和环境文件存在、是普通文件且不是符号链接；
- 项目目录存在；
- Compose 静态配置包含 `wechat-worker` 服务；
- 运维账号具有停止、查询和启动该服务的批准权限；
- 不打印环境文件内容。

这些变量只定位外部调用方控制面。本项目不修改其代码、数据库、restart policy 或
systemd 配置。Debian 启动到人工运行脚本之前 worker 是否持续停止仍需现场验证。

## 9. 创建网络并执行静态检查

```bash
if ! sudo docker network inspect cf-internal >/dev/null 2>&1; then
  sudo docker network create cf-internal
fi
```

使用与生命周期脚本相同的 Compose 输入做静态校验和拉取：

```bash
cd /opt/cf-agent-wechat
WECHAT_COMPOSE_FILE="${CF_AGENT_WECHAT_COMPOSE_FILE:-/opt/cf-agent-wechat/docker/compose.cfserver.yaml}"
WECHAT_ENV_FILE="${CF_AGENT_WECHAT_ENV_FILE:-/opt/cf-agent-wechat/docker/.env}"
WECHAT_RUNTIME_ROOT="${CF_AGENT_WECHAT_RUNTIME_ROOT:-/srv/storage/cf-agent-wechat/runtime}"
sudo env CF_AGENT_WECHAT_RUNTIME_ROOT="$WECHAT_RUNTIME_ROOT" \
  docker compose \
  --env-file "$WECHAT_ENV_FILE" \
  --project-directory /opt/cf-agent-wechat \
  -f "$WECHAT_COMPOSE_FILE" \
  config --quiet
sudo env CF_AGENT_WECHAT_RUNTIME_ROOT="$WECHAT_RUNTIME_ROOT" \
  docker compose \
  --env-file "$WECHAT_ENV_FILE" \
  --project-directory /opt/cf-agent-wechat \
  -f "$WECHAT_COMPOSE_FILE" \
  pull agent-wechat
```

不要执行 `up`。先运行 dry run：

```bash
./scripts/start-qr-login.sh --dry-run
```

Dry run 应只打印计划，不停止容器或 worker，不移动/创建 runtime 与归档，也不创建或遗留
`/run/lock/cf-agent-wechat-qr-runtime.lock`。任何失败都先按错误修复，不得跳过检查。

## 10. 首次 forced-QR 启动

在维护窗口、普通用户的交互式 SSH 会话中执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

脚本按固定顺序：

1. 获取独占锁并停止、复核 `wechat-worker`；
2. 停止并删除旧入口容器，但不执行 Compose `down`；
3. 原子归档当前 runtime 或首次 legacy 布局；
4. 创建全新 `runtime/data` 和 `runtime/wechat-home`；
5. 启动入口容器并验证 agent-server 与 WeChat 进程；
6. 以 `newAccount=true` 请求二维码，并要求当前 SSH 终端实际渲染至少一张 QR；
7. 等待手机扫描最新二维码并确认；
8. 有界等待同一 WeChat 进程身份、auth、chats 和 messages 全部通过；
9. 只有全部通过才启动 `wechat-worker`。

不要单独运行 `login.sh --force-qr`。扫码超时或流程失败后，等待当前脚本退出并释放锁，
按[登录管理](../login-management.md)和[故障排查](../troubleshooting.md)处理，再重新运行完整
入口。失败时不得手工启动 worker、恢复旧 runtime、删除归档或执行 UI logout。

## 11. 本项目独立验证

启动成功后执行：

```bash
./scripts/status.sh
sudo docker inspect --format \
  '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  cf-agent-wechat
sudo docker inspect --format \
  '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' \
  cf-agent-wechat
sudo docker exec cf-agent-wechat ps -ef |
  grep -E '[x]11vnc|[w]ebsockify' || true
```

`status.sh` 至少显示：

- `Container`
- `Agent Server`
- `WeChat Process`
- `Auth`
- `QR Runtime Mode`
- `Message API`
- `Gateway WeChat Worker`

本项目独立验收要求：

- 容器运行且健康，接入 `cf-internal`；
- WeChat canonical executable 对应的同一 `PID:start_time` 身份稳定；
- auth 为 `logged_in`，chats 可读；
- 启动过程确认 chats 非空且一次 messages 读取成功；
- x11vnc/websockify 检查无实际进程；
- 输出和记录不含账号、聊天 ID、正文、二维码或 Token。

`status.sh` 返回 `0` 不表示 worker 已运行，也不验证 chats 非空或 messages；进入
集成验证前仍须检查 `Agent Server` 展示项，并确认本次启动已完成非空 chats 与
messages 验证。第七项 worker 状态在下一节单独确认。

## 12. 集成验证

只有本项目独立验收通过后才检查调用方：

- `status.sh` 显示 `Gateway WeChat Worker` 已运行；
- 实际调用方通过 `cf-internal` 访问 `http://cf-agent-wechat:6174`；
- 依次验证 `/health`、`/api/status/auth`、`/api/chats` 和
  `/api/messages/{chat_id}`；
- 只记录脱敏状态和 HTTP 结果，不打印 Token、聊天 ID 或响应正文。

本仓库只确认接口和控制契约，不负责调用方内部权限、任务调度或 AI 回复。消息可读但
没有 AI 回复时，按[故障排查](../troubleshooting.md)完成边界确认后转交对应责任域。

## 13. 验收清单

以下清单必须保持未勾选，直到现场实际完成并建立带日期的脱敏记录：

- [ ] 批准 Commit 通过 forced-QR 代码能力门禁。
- [ ] 镜像使用批准 digest，容器 UID/GID 已核对。
- [ ] `docker/.env` 为 root-only，Token 不在其中。
- [ ] runtime、archive、legacy 和 Token 布局通过预检，无 mixed layout。
- [ ] Token 为 `root:root 600`，secrets 为 `root:root 700`。
- [ ] 三个外部 worker 控制路径已显式设置，dry run 无状态变化。
- [ ] SSH 终端实际显示全新二维码并完成手机扫码。
- [ ] 进程、auth、chats、messages 验证全部通过后 worker 才启动。
- [ ] `status.sh` 七项结果满足生产可用要求且无敏感输出。
- [ ] Debian 重启窗口中的 worker stop gate 已实机验证。
- [ ] 至少一个失败场景确认脚本未放行 worker、cleanup 状态报告准确、数据未删除。
- [ ] 验收记录不含 Token、二维码、账号、联系人、聊天 ID、正文或服务器地址。

当前未验证项和完整现场清单见[验证总览](../validation.md)。
