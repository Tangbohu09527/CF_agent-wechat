# Recovery Guide

生产恢复的首要原则是保留会话数据。`data/`、`wechat-home/` 和 `auth-token` 是同一
数据恢复单元；权威 `docker/.env` 保存其路径和权限合同，也必须纳入配置备份。容器重启、
重建和主机重启都不应替换这些内容。
> [!WARNING]
> 固定的 `docker/.env` 是 runtime 路径和权限设置的权威来源，`status.sh` 与
> `login.sh` 会安全读取它。非标准 runtime 必须由同一固定管理用户持有 `secrets`
> （mode `700`）和 Token（mode `600`）；自定义路径不支持 ACL/`0640`。不要通过
> stale shell 变量覆盖 `.env`，也不要混用 root 与普通用户运行管理脚本。
> 若该文件缺失，两个管理脚本都会 fail closed；已有 runtime 时 bootstrap 也不会猜测或
> 重建配置，必须先从同一恢复单元还原匹配的 `docker/.env`。

所有恢复路径都必须操作 systemd 管理的本机 rootful Docker，使用 `default` context 和
`unix:///var/run/docker.sock`；rootless 或远程 daemon 不受支持。运行前不得设置
`DOCKER_HOST`、`DOCKER_CONTEXT`、`DOCKER_TLS_VERIFY` 或 `DOCKER_CERT_PATH`。
普通用户需要提权时，脚本会先以前台 `sudo -v` 授权，再让受超时保护的调用使用
非交互 `sudo -n`；下列手工 Docker 命令也遵循同一顺序。

## 恢复模型

| 事件 | 预期行为 | 人工动作 |
| --- | --- | --- |
| 容器进程异常退出 | `unless-stopped` 自动重启 | 运行 `status.sh --wait`，必要时看日志 |
| Docker daemon 或主机重启 | Docker 自动启动未被人工停止的容器 | 等待恢复；会话有效时无需扫码 |
| Compose 重新创建容器 | bind mount 重新挂载原数据 | 验证挂载路径和 auth |
| 微信会话失效 | 服务健康但 auth 为 `logged_out` | 运行 `login.sh` 扫新二维码 |
| 持久盘或文件损坏 | 自动重启不能修复 | 停止服务，从完整一致备份恢复 |

`restart: unless-stopped` 会尊重人工停止。容器被显式 `docker stop`、Compose `stop` 或
`down` 后，不能假设它会自行恢复；进入代码根目录重跑 `./scripts/bootstrap-cfserver.sh`，
由 bootstrap 使用固定生产输入启动并完成 container、health、挂载和 API 验证。不要裸跑
Compose `up -d`。

## 1. 重启后的标准检查

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh --wait
```

`--wait` 默认使用 180 秒总轮询预算检查：

1. 容器是否 running；
2. Docker health 是否 healthy；
3. 宿主 `/health` 是否可访问；
4. `/api/status/auth` 是否为 `logged_in`。

`DOCKER_INSPECT_TIMEOUT=10` 是每次 `docker inspect` 的独立硬上限。在 `--wait` 模式下，
单次查询实际使用该值与整体预算剩余时间中的较小值，并在普通用户查询失败转入 sudo
fallback 前再次计算剩余时间。`STATUS_WAIT_TIMEOUT=180` 才是整个轮询阶段的总预算。
只有确认本机 daemon 正常但单次 inspect 确实超过 10 秒时才临时调大单次上限；这不会
延长 `STATUS_WAIT_TIMEOUT`。

结果：

- 返回 `0`：会话已恢复，可以继续服务；
- 返回 `2`：基础服务可用但会话需要重新登录；
- 返回 `1`：配置、Token、Docker 查询或 API 访问失败；
- 返回 `3`：容器/health/微信进程或认证状态不满足生产要求。

## 2. 计划内容器重启

使用固定生产 Compose 和权威 `docker/.env`：

```bash
cd /opt/cf-agent-wechat
sudo -v
sudo -n -- env \
  -u AGENT_WECHAT_IMAGE \
  -u AGENT_WECHAT_BIND_IP \
  -u AGENT_WECHAT_PORT \
  -u AGENT_WECHAT_CONTAINER_NAME \
  -u CF_AGENT_WECHAT_RUNTIME_ROOT \
  -u CF_AGENT_WECHAT_STORAGE_ROOT \
  -u PROXY \
  -u RUST_LOG \
  -u COMPOSE_PROJECT_NAME \
  -u DOCKER_HOST \
  -u DOCKER_CONTEXT \
  -u DOCKER_TLS_VERIFY \
  -u DOCKER_CERT_PATH \
  docker --host unix:///var/run/docker.sock compose \
  --env-file docker/.env \
  --project-directory "$PWD" \
  --project-name cf-agent-wechat \
  -f docker/compose.cfserver.yaml \
  restart agent-wechat
./scripts/status.sh --wait
```

重启前后不要移动或清空 `data` 和 `wechat-home`。若返回 `2`，按
[QR Login Guide](qr-login-guide.md) 重新登录；这不是数据清理信号。

## 3. 主机重启恢复

主机维护前记录脱敏基线：容器状态、Docker health、`status.sh` 返回码和镜像 digest。
重启后：

```bash
sudo systemctl is-active docker
cd /opt/cf-agent-wechat
./scripts/status.sh --wait
```

若容器未启动，先确认它是否在维护前被人工停止。确认持久根和生产 env 正确后，可重跑：

```bash
./scripts/bootstrap-cfserver.sh
```

bootstrap 会复用原目录和 Token。不要为了让服务启动而创建另一套空 runtime。

## 4. 登录恢复

只有状态明确为 `logged_out` 或需要登录的等待态时执行：

```bash
./scripts/login.sh
./scripts/status.sh --wait
```

若会话仍有效，`login.sh` 会短路返回，不触发新二维码。`app_not_running`、unhealthy 或
API 不可用时不要反复扫码；先修复基础服务。

## 5. 备份一致性

至少备份权威 `docker/.env` 中 `CF_AGENT_WECHAT_RUNTIME_ROOT` 指向的完整集合：

```text
<runtime-root>/data
<runtime-root>/wechat-home
<runtime-root>/secrets/auth-token
```

同时备份 `/opt/cf-agent-wechat/docker/.env` 及其 owner/mode；它不含 auth Token，但
`PROXY` 等配置仍可能敏感。恢复时必须让代码 Commit、镜像 digest、env 和 runtime
对应同一批准基线。

备份包含 API Token、数据库和微信个人数据，必须加密、限制访问并记录保留期限。建议使用
文件系统快照或在服务停止后制作一致备份。在线逐文件复制可能得到不一致的数据库状态。

备份前停止入口容器，不删除容器和卷；备份后重跑 `./scripts/bootstrap-cfserver.sh`，再运行
`status.sh --wait`。备份工具必须保留数值 UID/GID、权限和时间属性。不得把 Token 单独
发送、打印哈希或写入部署日志。

## 6. 从备份恢复

恢复应在维护窗口执行：

1. 确认备份包含配套 `docker/.env` 及同一时点的 `data`、`wechat-home` 和原 Token；
2. 停止 `agent-wechat`，确认没有进程继续写入；
3. 将当前持久根整体改名隔离，保留现场，不直接删除；
4. 按已恢复 `docker/.env` 的权威路径还原完整 runtime；
5. 按 `docker/.env` 中持久化的 UID/GID/mode 恢复目录和 Token 元数据；默认值为数据目录
   `1000:1000 0700`、secrets `root:root 0700`、Token `root:root 0600`；
6. 运行 bootstrap，随后执行 `status.sh --wait`；
7. auth 为 `logged_out`、处于需要登录的等待态，或 `status.sh` 返回 `2` 时才运行
   `login.sh`。

不要把备份 `data` 与新生成的 Token 混用，也不要只恢复空的 `wechat-home`。恢复工具和
存储平台各异，具体复制命令应由备份系统 runbook 给出；本项目不会自动删除被隔离现场。

## 7. 升级与回滚

升级前记录当前 Commit、镜像 digest、环境文件元数据和完整备份。先按
[Deployment Guide](deployment-guide.md) 使用候选 digest 镜像执行 `/usr/bin/id -u wechat`
和 `/usr/bin/id -g wechat`，据此核对权威 `CF_RUNTIME_UID` / `CF_RUNTIME_GID` 与已有目录
数值属主。然后在同一受控变更中更新 `docker/.env` 的 digest 和必要 UID/GID；不要
`source` 或输出该文件。完成数据属主迁移后重跑 `./scripts/bootstrap-cfserver.sh`，最后运行
`./scripts/status.sh --wait`。不要以裸 Compose `up -d` 代替 bootstrap。

回滚同时要求：

- 使用已批准的旧镜像 digest；
- 确认旧镜像兼容当前数据库格式；
- 必要时恢复升级前的完整持久数据集合；
- 保留失败镜像日志和数据现场。

不要使用 `latest`，不要仅回滚镜像后假设数据格式兼容。

## 禁止操作

- `docker compose down -v`
- 删除或清空 `data/`、`wechat-home/` 解决一般登录故障
- 在已有 `data/` 时生成新的 `auth-token`
- 把持久根切换到一个空目录后宣称恢复成功
- `chmod -R 777` 或把 Token 改为可被所有用户读取
- 将历史实验 Compose 用于生产恢复
