# CFserver 生产运维

本文覆盖日常只读检查、正常停止、维护、重启边界、Archive 盘点、日志和交接。生命周期
命令的权威步骤见 [CFserver 生产 Runbook](deployment/cfserver-production.md)。

## Lifecycle table

| 场景 | 唯一入口 | 当前语义 |
| --- | --- | --- |
| 预演 | `start-qr-login.sh --dry-run` | 不改容器、Controller、目录、Archive 或锁 |
| 正式启动 | `start-qr-login.sh` | Controller stop，轮换 Runtime，fresh QR，验证后 start/status |
| 正式停止 | `stop-qr-runtime.sh` | Controller stop 后停止 Agent，保留 Runtime/Token/Archive |
| Host reboot | Controller stop + fresh QR | Agent 因 `restart: "no"` 保持停止；Gate 必须显式确认 |
| 升级/回滚 | stop -> Bootstrap -> fresh QR -> status | 不恢复旧 Archive，不复用旧 Session |
| 失败 cleanup | 启动脚本自动处理 | 再次 stop Gate，尝试 stop/remove Agent，不删除持久数据 |

任何场景都不得用裸 `docker compose up/restart/down` 或手工 Worker 启动替代生命周期入口。
## Daily status

~~~bash
cd /opt/cf-agent-wechat
./scripts/status.sh
~~~

生产在线要求 11 个状态项全部通过：

- Container running
- Docker Health healthy
- Agent Server reachable
- WeChat Process running 且稳定
- Auth `logged_in`
- QR Runtime Mode `fresh`
- Message API chats/messages readable
- Gateway Runtime Ready `true`
- Gateway Token Contract `true`
- Gateway Poll Worker Health `healthy`
- Gateway Delivery Worker Health `healthy`

`status.sh` 只读；退出码 `0/1/2/3` 的准确含义见
[登录生命周期](login-management.md#exit-codes)。不要只看 Docker health 或 Auth。

## Normal stop

计划维护或主动下线：

~~~bash
cd /opt/cf-agent-wechat
./scripts/stop-qr-runtime.sh
./scripts/status.sh
~~~

stop 保留 Runtime、Token、Archive 和 Agent 容器定义。状态命令在离线状态返回非零属于
预期；确认输出与计划一致即可。再次上线必须 fresh QR。

## Planned maintenance

1. 通知业务方进入离线窗口，说明窗口内消息可能无法补拉。
2. 在旧的批准输入下执行 Normal stop。
3. 确认 Poll/Delivery Gate 与 Agent 都已停止。
4. 记录旧 Commit、镜像引用和脱敏状态。
5. 仅在需要时更改批准的代码、Compose、环境或镜像输入。
6. 运行 Bootstrap。
7. 在 SSH TTY 完成 fresh QR。
8. 运行 status，全部通过后结束维护窗口。

不要在 Agent 在线时直接替换 `docker/.env` 或显式 recreate。

## CFserver reboot

真实验收表明 Agent 会保持停止，但 Gateway Worker 可能自动恢复。重启后：

1. 不假设 Gate 已关闭。
2. 按 [CFserver reboot recovery](deployment/cfserver-production.md#cfserver-reboot-recovery)
   显式 Controller `stop --timeout-seconds 30`。
3. 运行 fresh QR。
4. 运行 status。

Automatic Gateway boot stop gate 仍是已知限制，不得在交接中写成已保证。

## AI/Hermes host reboot

若 CFserver 和 `cf-agent-wechat` 未重启：

- 不需要 fresh QR。
- 运行 `./scripts/status.sh` 确认本项目在线。
- Gateway/Hermes 连通性、队列与业务恢复交给对应项目。

不要为了下游恢复主动重建 Agent。

## Gateway-only deployment

若 Gateway 单独部署且未重启或删除 Agent：

- 微信 Session 可以保持，已在生产受控切换中观察到。
- 部署前后运行 `./scripts/status.sh`。
- Gateway Worker 生命周期只通过正式 Controller 管理。
- 若最终本仓库 11 项状态未通过，按层级判断；不要先轮换 Agent。

该结论不能外推为 Agent restart/recreate 后可复用 Session。

## Archive inventory

只盘点路径、时间与容量，不读取 payload：

~~~bash
sudo -v

sudo -n find /srv/storage/cf-agent-wechat/session-archive \
  -mindepth 1 \
  -maxdepth 1 \
  -printf '%f\n'

sudo -n du -sh \
  /srv/storage/cf-agent-wechat/runtime \
  /srv/storage/cf-agent-wechat/session-archive
~~~

Archive 不覆盖、不自动删除、不恢复。payload 可能含 Session、账号/Chat 标识、消息
metadata、cache 和数据库内容，访问与备份按受限敏感资产管理。

## Disk monitoring

监控：

- storage filesystem 剩余空间；
- active Runtime 增长；
- `session-archive` 目录数量和总容量；
- Docker `json-file` 日志占用。

本仓库不提供 Archive 自动删除命令。保留期、容量阈值、备份和安全销毁必须由外部运维
策略与审批决定。

## Token metadata verification

只查看元数据：

~~~bash
sudo -v

sudo -n stat -c '%F %u:%g:%a:%h %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
~~~

预期父目录 `0:0:700`；Token 为普通非 symlink 文件、`10001:10001:600:1`。
内容格式由生命周期脚本安全验证。不要用 `cat`、`sha256sum`、`head`、`od` 或
其他命令读取、哈希、截取 Token。

## Log inspection

Agent 自身日志策略为 `json-file 20m × 3`：

~~~bash
cd /opt/cf-agent-wechat
sudo -v

sudo -n docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  --project-name cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  logs --tail=200 agent-wechat
~~~

不要使用 verbose curl trace，不打印 Authorization、`.env` 或代理凭据。Gateway 的
`64m × 10` 是另一个项目的日志策略。

## Handover

- [ ] 当前生产状态链接指向 [production-status.md](production-status.md)。
- [ ] 操作人员知道 Bootstrap 不上线。
- [ ] 操作人员知道 fresh QR、stop、status 是不同入口。
- [ ] Host reboot 后先显式关闭 Gateway Gate。
- [ ] Gateway-only/AI Host restart 不应主动重建 Agent。
- [ ] 11 项状态和退出码已交接。
- [ ] Runtime、Archive、Token 的路径和访问责任已交接。
- [ ] Archive 保留、容量、备份和销毁有外部负责人。
- [ ] 日志按 `20m × 3` 监控，且敏感信息规则明确。
- [ ] Repository branch authority 为 `main`、PR #1 promotion baseline 为
  `02583fe76220916019ca961bb37dfa015640384e`、baseline CI Run `33853255941`
  成功的状态已交接。
- [ ] Live `main` tip 动态查询；没有选定 Release Commit 被证明已重新部署，Source
  与现场 Image ID 的精确绑定仍未验证。

## Upgrade/rollback decision

出现以下任一变化必须走 stop -> approved inputs -> Bootstrap -> fresh QR -> status：

- Agent 镜像 digest；
- Compose、端口、网络、挂载或 restart policy；
- Runtime/Archive/Token 契约；
- 登录 API、QR payload 或超时；
- Gateway Runtime Contract；
- `seccomp=unconfined` 或 `SYS_PTRACE`。

回滚只回滚代码/配置/镜像，不恢复旧 Archive 为 active Session。失败时使用
[Recovery Guide](recovery-guide.md)，不要修改数据库或手工启动 Worker。
