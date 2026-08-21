# Troubleshooting

按“容器 -> Docker health -> HTTP health -> auth”顺序排查。不要把 `logged_out`、API
不可用和容器停止混为同一种故障，也不要通过清空 runtime 解决一般问题。

## 快速诊断

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
status_rc=$?
printf 'status exit code: %s\n' "$status_rc"
```

| 返回码 | 分类 | 常见原因 |
| --- | --- | --- |
| `0` | 全部正常 | 会话已恢复且 `logged_in` |
| `1` | 管理/访问错误 | 配置、命令、Token、Docker 查询或 API 访问失败 |
| `2` | 需要登录 | `logged_out` 或登录等待态 |
| `3` | 运行态异常 | 容器停止、health 非 healthy、微信进程异常或未知 auth |

重启窗口使用 `./scripts/status.sh --wait`，避免把正常启动中的 `starting` 当成最终故障。
日常诊断首选 `status.sh`；它会读取权威配置并同时检查容器、health、API 与 auth。
只有需要查看原始 Docker 数据时才使用下列 helper：

生产管理只支持 systemd 管理的本机 rootful Docker；context 必须为 `default`，endpoint
必须为 `unix:///var/run/docker.sock`。rootless 或远程 daemon 不受支持。
脚本会拒绝 `DOCKER_HOST`、`DOCKER_CONTEXT`、`DOCKER_TLS_VERIFY` 和
`DOCKER_CERT_PATH` 覆盖。普通用户需要提权时，脚本先在前台执行 `sudo -v`，
受超时保护的 Docker 调用随后只使用非交互 `sudo -n`。下方 helper 和 raw Docker
命令采用相同顺序；若授权票据在长时间排障中失效，重新以前台 `sudo -v` 授权，
不要让受超时保护的命令等待密码。

```bash
cd /opt/cf-agent-wechat
ROOT="$(pwd -P)"
COMPOSE_FILE="$ROOT/docker/compose.cfserver.yaml"
ENV_FILE="$ROOT/docker/.env"

sudo -v
compose_prod() {
  sudo -n -- env \
    -u AGENT_WECHAT_IMAGE \
    -u AGENT_WECHAT_BIND_IP \
    -u AGENT_WECHAT_PORT \
    -u AGENT_WECHAT_CONTAINER_NAME \
    -u CF_RUNTIME_ROOT \
    -u CF_AGENT_WECHAT_RUNTIME_ROOT \
    -u CF_AGENT_WECHAT_STORAGE_ROOT \
    -u PROXY \
    -u RUST_LOG \
    -u COMPOSE_FILE \
    -u COMPOSE_PROJECT_NAME \
    -u DOCKER_HOST \
    -u DOCKER_CONTEXT \
    -u DOCKER_TLS_VERIFY \
    -u DOCKER_CERT_PATH \
    docker --host unix:///var/run/docker.sock compose --env-file "$ENV_FILE" \
      --project-directory "$ROOT" \
      --project-name cf-agent-wechat \
      -f "$COMPOSE_FILE" "$@"
}
```

每次 raw Compose 调用都通过该 helper 清理 stale shell 值，并固定本机 socket、
`--env-file`、`--project-name` 与 `-f`。不要 `source` 环境文件。项目名
`cf-agent-wechat` 是固定 Compose 契约，但容器名可由 `docker/.env` 覆盖；
需要 `docker inspect` 时必须从 service `agent-wechat` 获取容器 ID。

## bootstrap 失败

`bootstrap-cfserver.sh` 任一步失败都会非零退出并保留现场。按错误类型检查：

- `docker` 是否安装且 daemon 为 active；
- `docker --host unix:///var/run/docker.sock compose version` 是否为 v2；
- Docker context 是否为 `default`，endpoint 是否为 `unix:///var/run/docker.sock`，
  daemon 是否为 rootful，且当前 shell 是否清除了全部 `DOCKER_*` daemon 覆盖；
- 代码根、`docker/` 目录、固定 Compose 和 env 是否由 root 或当前固定管理用户持有；
  Compose/env 是否为非符号链接普通文件、hardlink 计数为 `1`，且权限满足生产合同；
- 镜像是否使用完整 `@sha256:<64 hex>` digest；
- `CF_RUNTIME_ROOT` 是否位于可写、空间充足的持久文件系统；
- 现有目录是否为真实目录而非符号链接，属主和权限是否符合生产基线；
- `docker/.env` 中 `AGENT_WECHAT_PORT` 对应的 loopback 宿主端口
  （默认 `6174`）是否已被其他进程占用；
- systemd 是否为 `running`/`degraded`，且 `docker.service` 是否已启用开机启动；
- 首次扫码所需 Python 依赖能否从批准包源安装，或登录 venv 是否已预置；
- 外部网络 `cf-internal` 是否能创建或读取。

缺少 `docker/.env` 时要在首次执行环境中提供 `AGENT_WECHAT_IMAGE`。已有 `.env` 时先
修复该文件，不要创建第二个环境文件让脚本和人工 Compose 使用不同输入。

## Docker CLI 或 Compose 超时

bootstrap 默认将 Docker/Compose 元数据、配置和 inspect 命令限制为 30 秒
（`CF_BOOTSTRAP_DOCKER_TIMEOUT`），将 `compose up -d` 单独限制为 900 秒
（`CF_BOOTSTRAP_COMPOSE_UP_TIMEOUT`）。后者包含首次镜像拉取。状态脚本的单次
`docker inspect` 默认限制为 10 秒（`DOCKER_INSPECT_TIMEOUT`）；`status.sh --wait`
还会将每次普通查询和 sudo fallback 收紧到总轮询预算的剩余时间。

发生超时时：

1. 检查 `systemctl status docker`、daemon 日志、磁盘空间、DNS 和镜像仓库；
2. 确认没有卡住的交互式 sudo 提示；
3. 不删除或替换 `docker/.env`、`data`、`wechat-home` 和原 Token；
4. daemon 或网络恢复后原样重跑 bootstrap，再执行 `status.sh --wait`。

超时强制结束的是 CLI 客户端；daemon 可能仍在完成已经提交的 pull/create。Compose 项目
使用固定名称并可幂等重跑。只有经过现场测量确认主机或仓库正常但确实较慢时，才在变更窗口
临时调大对应正整数秒数；不要用 `0` 禁用上限。

## 生产配置权威校验失败

`status.sh` 和 `login.sh` 在 `docker/.env` 缺失、属主不受批准、权限过宽或存在额外
hardlink 时会拒绝执行。若 runtime 已存在，先停止变更并从配套备份还原原 `.env`；
只有全新且空的 runtime 才能由 bootstrap 使用批准的镜像 digest 初始化新配置。

```bash
cd /opt/cf-agent-wechat
stat -c '%F %u:%g %a %h %n' \
  . docker docker/compose.cfserver.yaml docker/.env
```

代码根和 `docker/` 目录的 owner 必须是 `0` 或执行管理命令的固定用户 UID；固定
Compose/env 的 owner 也遵循该规则，且上面输出的 hardlink 计数必须为 `1`。确认文件
来源后恢复批准的 owner/mode 或从配置备份还原，不要复制到第二个 env、`source` 文件，
也不要用进程变量绕过校验。

## 容器不存在或未运行

```bash
compose_prod ps --all
CONTAINER_ID="$(compose_prod ps --all -q agent-wechat)"
if [ -n "$CONTAINER_ID" ]; then
  sudo -n -- docker --host unix:///var/run/docker.sock inspect "$CONTAINER_ID" --format \
    '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}'
fi
```

若容器被人工停止，`unless-stopped` 会保留停止意图。确认变更窗口后重跑 bootstrap。若容器
反复退出，先收集日志，不要循环重启：

```bash
compose_prod logs --tail=200 agent-wechat
```

## Docker health 为 starting 或 unhealthy

Compose healthcheck 请求容器内固定端口
`http://127.0.0.1:6174/health`；这不是可配置的宿主发布端口。首次启动可在启动
宽限期内显示 `starting`；使用 `status.sh --wait` 做有界等待。

最终为 `unhealthy` 时检查 health 日志：

```bash
CONTAINER_ID="$(compose_prod ps -q agent-wechat)"
test -n "$CONTAINER_ID"
sudo -n -- docker --host unix:///var/run/docker.sock inspect "$CONTAINER_ID" --format '{{json .State.Health}}'
compose_prod logs --tail=200 agent-wechat
```

常见原因包括 agent-server 未监听、WeChat/桌面进程启动失败、数据目录不可写、数据库与
Token 不匹配、磁盘满或镜像不兼容。

## `/health` 宿主访问失败

先区分容器内 health 与宿主端口发布：

```bash
HEALTH_ENDPOINT="$(compose_prod port agent-wechat 6174)"
printf 'published health endpoint: %s\n' "$HEALTH_ENDPOINT"
curl --fail --silent --show-error "http://${HEALTH_ENDPOINT}/health"
```

- 容器 healthy 但宿主失败：检查 `.env` 中 bind IP/port、端口冲突和防火墙；
- 容器内外都失败：回到容器日志；
- 不要临时改成 `0.0.0.0` 暴露公网来绕过检查。

## Token 读取失败

默认元数据应为：

```bash
sudo stat -c '%F %U:%G %a %n' \
  '<runtime-root>/secrets' \
  '<runtime-root>/secrets/auth-token'
```

先把 `<runtime-root>` 替换为 `docker/.env` 中的精确持久值；不要 source 该文件。默认
`secrets` 是 `root:root 700` 的真实目录，Token 是 `root:root 600` 的非符号链接
普通文件。普通用户脚本通过受控 sudo 读取默认路径。错误修复原则：

- Token 缺失且 `data` 已存在：停止，不要生成新 Token；从配套备份恢复；
- 权限错误：确认来源和属主后恢复到精确权限，不使用 `644` 或 `777`；
- 自定义 Token 路径：当前用户必须能直接安全读取，默认 sudo 规则不会代读；
- 不用 `cat`、shell trace 或环境变量验证 Token 内容。
受控 sudo reader 只允许固定批准路径
`/srv/storage/cf-agent-wechat/secrets/auth-token`。非标准 runtime 必须由固定管理用户
持有非符号链接 `secrets` 目录（mode `700`）和 `auth-token` 普通文件（mode `600`）。
`status.sh` 与 `login.sh` 自动读取权威 `docker/.env`，无需每次导出路径。自定义 Token
不支持 ACL/`0640`；也不要在 root 与普通用户之间切换，否则登录 venv 的所有权会
不一致。

## 状态为 logged_out

这表示基础服务可用但微信会话无效，不表示 runtime 损坏：

```bash
./scripts/login.sh
./scripts/status.sh --wait
```

保持一个交互终端完成扫码。每次重试使用脚本新渲染的二维码。不要删除 `data` 或
`wechat-home`，也不要先执行 UI logout。

## 二维码未显示、过期或登录超时

1. 确认 stdout 连接交互式 TTY，终端宽度至少 80 列，`TERM` 设置合理；
2. 确认 Python venv 和 `scripts/requirements.txt` 依赖安装成功；
3. 若依赖缺失，检查批准的 Python 包源网络或预置离线 venv；
4. 检查 API 是否使用 `docker/.env` 端口推导的 loopback 地址；
5. 等待失败的脚本完全退出，再重新运行并扫描最新 QR；
6. 手机确认后仍失败时，保留脱敏事件类型和时间，不记录二维码或账号。

登录工具若未实际渲染 QR，会拒绝把 `login_success` 当作有效完成。这是保护行为，不应
通过手工调用底层 Python 工具绕过。

## 状态为 app_not_running

API 已能响应但微信客户端进程不存在。`login.sh` 无法修复该状态。查看容器日志，重点
检查 Xvfb、桌面进程、WeChat 可执行文件、持久 HOME 权限和磁盘空间。修复后重建容器并
运行 `status.sh --wait`，不要先扫码。

## 重启后会话没有恢复

检查挂载是否仍指向同一持久根：

```bash
CONTAINER_ID="$(compose_prod ps -q agent-wechat)"
test -n "$CONTAINER_ID"
sudo -n -- docker --host unix:///var/run/docker.sock inspect "$CONTAINER_ID" --format \
  '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

预期同一根下的 `data` 挂到 `/data`、`wechat-home` 挂到 `/home/wechat`、原
`auth-token` 只读挂到 `/data/auth-token`。若路径变成空目录：

1. 停止继续登录或写入；
2. 保留错误目录现场；
3. 修正权威 `docker/.env` 中的 runtime/Compose 映射；
4. 从完整一致备份恢复，参考 [Recovery Guide](recovery-guide.md)。

挂载正确但 auth 为 `logged_out` 时，直接按 QR Login Guide 重新登录，不要归档或轮换
runtime。

## 外部网络或 Gateway 调用失败

```bash
sudo -n -- docker --host unix:///var/run/docker.sock network inspect cf-internal
CONTAINER_ID="$(compose_prod ps -q agent-wechat)"
test -n "$CONTAINER_ID"
sudo -n -- docker --host unix:///var/run/docker.sock inspect "$CONTAINER_ID" --format \
  '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}'
```

宿主 `/health` 正常而 Gateway 失败时，检查调用方是否接入 `cf-internal`。Gateway
使用固定网络别名和容器内端口 `http://cf-agent-wechat:6174`；这里的
`cf-agent-wechat` 是 Compose network alias，不是对可配置容器名的假设。本仓 bootstrap
不启动、停止或修改 Gateway；调用方内部权限、任务调度和业务错误应转交 Gateway 责任域。

## 磁盘与权限问题

```bash
df -h '<runtime-root>'
grep -E '^(CF_RUNTIME_UID|CF_RUNTIME_GID)=' "$ENV_FILE"
sudo stat -c '%F %u:%g %a %n' \
  '<runtime-root>/data' '<runtime-root>/wechat-home'
```

`data` 和 `wechat-home` 的 mode 应为 `700`，数值 owner 必须匹配权威
`docker/.env` 中的 `CF_RUNTIME_UID`/`CF_RUNTIME_GID`；`1000:1000` 只是默认值，
不能作为自定义部署的修复常量。这里只读取两个数值键，不要 `source` 整个 env。发现 UID
假设与镜像不符时先核对镜像内用户，不要递归改属主。磁盘耗尽时先按备份和保留策略处理
日志/备份，不直接删除运行数据库或微信 HOME。

## 收集升级信息

升级问题应记录以下脱敏信息：

- 代码 Commit 和镜像 digest；
- Debian、Docker Engine 和 Compose 版本；
- bootstrap/status 返回码及时间；
- 容器 State、Health 和重启次数；
- `/health` HTTP 结果和 auth 状态名；
- 最近 200 行脱敏容器日志；
- runtime 路径、文件类型、UID/GID、权限和可用空间。

不要收集 Token、二维码、账号、联系人、聊天 ID、消息正文、完整 env 或数据库内容。
