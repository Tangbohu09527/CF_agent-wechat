# 新设备 Bootstrap

本文说明首次 CFserver 部署或部署输入变化后的基础准备。Bootstrap 不是登录流程、启动
流程或 Session 恢复流程。

## Result definition

~~~bash
cd /opt/cf-agent-wechat
sudo ./scripts/bootstrap-cfserver.sh
~~~

成功只表示：

~~~text
部署输入和管理边界已准备完成；Agent 仍停止，尚未创建微信 Session。
~~~

下一步由人工在受控 SSH TTY 运行 `./scripts/start-qr-login.sh`。

## Required platform and tools

- Debian/Ubuntu family Host，systemd 为 running 或 degraded。
- `docker.service` active 且 enabled；`cf-agent-wechat.service` 不得 boot-enabled。
- 固定系统工具包括 `/usr/bin/docker`、`/usr/bin/systemctl`、
  `/usr/bin/openssl`、`/usr/bin/timeout`。
- 还需要 `apt-get`、`awk`、`chmod`、`chown`、`curl`、`dirname`、
  `dpkg-query`、`env`、`flock`、`grep`、`id`、`install`、`mktemp`、
  `mv`、`python3`、`readlink`、`realpath`、`rm`、`stat` 和 `wc`。
- Python 3 必须提供 `json` 与 `venv`；Docker Compose v2 必须可用。

生产模式拒绝测试替身或 PATH 中可被普通用户替换的关键工具。

## Docker contract

Bootstrap 验证：

- `/var/run/docker.sock` 是真实、非 symlink 的 Unix socket；
- Docker context 为 `default`；
- endpoint 为 `unix:///var/run/docker.sock`；
- daemon 为本机 rootful，不是 rootless 或 remote；
- `live-restore=false`；
- Docker/Compose 调用有硬超时。

任一不满足都 fail closed。不要用环境变量覆盖到远端 daemon 或其他 context。

## Repository and environment

- repository：`/opt/cf-agent-wechat`
- Compose：`/opt/cf-agent-wechat/docker/compose.cfserver.yaml`
- environment：`/opt/cf-agent-wechat/docker/.env`
- Compose project：`cf-agent-wechat`

`docker/.env` 必须是已存在的普通非 symlink 文件，owner 为 root 或固定管理用户，mode
为 `0600` 或 `0640`，且无额外 hard link。脚本只解析批准的字面量键值，不执行
shell 语法；禁止任何 Token/Password/Secret 键。镜像必须是不可变
`@sha256:<64-hex>` 引用，bind IP 必须为 `127.0.0.1`。

不要打印完整 `.env`、代理凭据或完整 Compose render。

## Storage and permissions

Bootstrap 创建或验证：

| 路径 | 契约 |
| --- | --- |
| `/srv/storage/cf-agent-wechat` | root 管理的 storage root |
| `session-archive` | root-protected，mode `0700` |
| `secrets` | `root:root 0700` |
| existing Runtime/legacy directories | 必须匹配配置的 UID/GID/mode，默认 `1000:1000/0700` |

Bootstrap 不创建 `runtime/data` 或 `runtime/wechat-home` 作为新 Session；这些只由
fresh QR start 创建。若新 Runtime 与 legacy `data`/`wechat-home` 同时存在，
Bootstrap fail closed，不猜测、不合并。

## Token migration boundary

完整 Token 契约见 [当前生产状态](../production-status.md#storage-and-token)。Bootstrap
只允许三种结果：

1. 当前格式已合规：原样复用。
2. Token 不存在：安全生成新 Token。
3. 唯一受支持 legacy 格式：`root:root 0600`、link count 1、64 位小写十六进制加
   单个 LF；迁移为当前 `10001:10001 0600`、无尾随 LF，逻辑值不变。

其他格式一律保留现场并 fail closed。Token 不写入 `.env`，也不进入 Runtime/Archive。

## Network and Compose attestation

Bootstrap 创建或复用 external `cf-internal`，并确认它是 local bridge。Compose render
必须精确满足：

- service `agent-wechat`，container `cf-agent-wechat`
- `restart: "no"`
- 6174 loopback-only
- alias `cf-agent-wechat`
- 三个 bind：Runtime data、WeChat HOME、只读 Token
- `ENABLE_VNC=0`
- `seccomp=unconfined`、`SYS_PTRACE`
- healthcheck 与 `json-file 20m × 3`

`cf-internal` 是外部共享网络，Bootstrap 可以在缺失时按契约创建，但本项目不得在日常
操作中删除它。

## Gateway Contract

Bootstrap 只读取固定 Controller：

~~~text
/opt/cf-agent-gateway/deploy/wechat-runtime-control
~~~

它必须是可执行的普通非 symlink 文件，并返回精确 Runtime Contract version 1。脚本
动态核对 Poll/Delivery/Dispatch 服务名、file Token 模式及 Token container path。
Bootstrap 不启动或停止 Gateway Worker；Worker 生命周期由 fresh QR/stop 脚本通过
Controller `stop/start/status` 管理。

## Retry and completion

Bootstrap 可在配置修复后重复执行。它可能准备管理目录、Token 和 external network，
但不会：

- 创建或恢复微信 Session；
- 创建 fresh Runtime data/HOME；
- 启动 `agent-wechat`；
- 显示二维码或登录；
- 启动 Poll/Delivery Worker；
- 宣称生产入口在线。

完成后执行 [CFserver 生产 Runbook](cfserver-production.md)中的 “Normal fresh QR
start”。若是已运行部署的配置变化，必须先按旧输入完成正式 stop。
