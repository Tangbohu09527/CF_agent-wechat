# QR Login Guide

本文覆盖首次微信登录和会话失效后的重新登录。正常重启不需要主动扫码：先检查会话能否
恢复，只有 auth 明确要求登录时才运行 `scripts/login.sh`。

## 1. 先判定是否需要登录

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
status_rc=$?
printf 'status exit code: %s\n' "$status_rc"
```

| 返回码 | 含义 | 动作 |
| --- | --- | --- |
| `0` | 容器、health、API 正常且 `logged_in` | 不执行登录；保留现有会话 |
| `2` | 服务正常但 `logged_out` 或处于登录等待态 | 运行 `login.sh` |
| `1` | 配置、Token、Docker 查询或 API 访问失败 | 先排障 |
| `3` | 容器停止、unhealthy、微信进程异常或未知 auth | 先恢复基础服务 |

## 2. 登录前置条件

- 在 stdout 连接 TTY、宽度至少 80 列且能清晰显示二维码的交互式 SSH/终端中操作；
- 容器为 running 且 Docker health 为 healthy；
- `/health` 可用，认证 API 返回需要登录；
- 默认 Token 位于 `/srv/storage/cf-agent-wechat/secrets/auth-token`；
- 主机安装 Python 3、`python3-venv`、`curl` 和 util-linux（含 `flock`）；
- 首次使用登录工具时，普通运维用户能够从批准的 Python 包源安装
  `scripts/requirements.txt` 中的依赖，或已预置并验证登录 venv。

登录依赖安装在普通用户的隔离 venv 中，默认位置为
`~/.local/share/cf-agent-wechat/venv`，不应使用 sudo 运行 Python 或 pip。

## 3. 执行登录

```bash
cd /opt/cf-agent-wechat
./scripts/login.sh
```

脚本会：

1. 读取并确认当前 auth 状态；
2. 已为 `logged_in` 时直接返回，不触发扫码；
3. 获取当前用户的非阻塞登录锁，再以 `newAccount=true` 建立本次 fresh 登录 WebSocket；
4. 只渲染该连接收到的新二维码；
5. 等待手机扫描和确认；
6. 收到成功事件后再次确认 auth 为 `logged_in`。

脚本只有在本次 `newAccount=true` 连接确实渲染过新二维码后才接受 `login_success`；
旧的 HTTP QR 不会满足该条件。stdout 不是 TTY、终端过窄、响应没有可显示的 QR、二维码
过期或 WebSocket 提前断开时，流程会非零退出，不会泄露 QR 或误报登录成功。

完成后：

```bash
./scripts/status.sh --wait
```

## 4. 扫码操作

1. 使用手机微信扫描终端中最新出现的二维码；
2. 按手机提示确认登录；
3. 保持终端连接，直到脚本显示登录成功并完成 auth 复核；
4. 不要复用截图或之前一次运行留下的二维码。

二维码、账号和登录事件可能包含敏感信息。不要录屏、贴入工单或写入 CI 日志。

## 5. 支持的环境变量

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `API_URL` | 由 `docker/.env` 的 loopback 端口推导 | 只允许本机 HTTP API，显式值必须一致 |
| `WS_URL` | 由 `API_URL` 推导的 `/api/ws/login` | 不允许独立指向其他主机 |
| `TOKEN_FILE` | 由权威 `docker/.env` 的持久 runtime 推导 | 显式值必须精确等于该 runtime 的派生路径 |
| `SESSION_ID` | 固定 `default` | 生产不支持其他 session ID |
| `LOGIN_TIMEOUT_MS` | `300000` | 扫码登录超时，毫秒 |
| `LOGIN_CONFIRM_RETRIES` | `5` | 成功事件后的 auth 复核次数 |
| `LOGIN_CONFIRM_INTERVAL` | `2` | auth 复核间隔，秒 |
| `CF_AGENT_WECHAT_VENV` | `~/.local/share/cf-agent-wechat/venv` | 登录工具 venv |
| `QR_MAX_WIDTH` | 按实际终端宽度计算 | 二维码最大字符宽度，不能超过可用列 |

生产环境一般不需要覆盖这些值；`login.sh` 会安全读取固定 `docker/.env` 中的 runtime
和端口。存在有效的权威 `docker/.env` 时，`TOKEN_FILE` 不是独立的路径配置入口；任何
显式值都必须精确等于该 runtime 派生的 `secrets/auth-token` 路径。默认 sudo reader 只允许
`/srv/storage/cf-agent-wechat/secrets/auth-token`。非标准 runtime 必须由固定登录用户
直接持有 `secrets`（mode `700`）和 Token（mode `600`），无需重复导出路径。
非标准 runtime 的 `secrets` 和 Token 不支持 ACL/`0640`；不要混用 root 与普通用户，
以免造成 venv 所有权和后续升级问题。

## 6. 重试规则

- 超时：等待当前脚本退出，再重新运行 `login.sh` 获取新二维码。
- 手机未出现确认：只扫描当前终端最新二维码，检查手机网络与微信状态。
- `login_success` 后仍非 `logged_in`：保留日志，检查 agent-server；不要删除会话目录。
- `app_not_running`：查看容器日志和 WeChat 进程，扫码无法修复进程故障。
- 已有另一个登录流程：停止并发操作，只保留一个交互终端完成登录。

## 7. 安全边界

- 不把 Token 作为命令行参数或环境变量传给 Python 子进程；
- 不启用 shell trace (`set -x`) 采集登录现场；
- 不把 auth 响应、二维码、账号或聊天内容写入监控标签；
- 不通过 UI logout 测试生产恢复；应在批准的测试账号和窗口验证；
- 登录失败不代表持久数据损坏，不要删除 `data` 或 `wechat-home`。
