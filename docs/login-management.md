# 微信登录管理

## 适用范围

本文说明 CFserver 正式环境中 `cf-agent-wechat` 容器的登录状态检查与登录操作。通过 SSH 登录 CFserver 后，在仓库目录以普通用户运行：

```bash
cd /opt/cf-agent-wechat

./scripts/status.sh
./scripts/login.sh
```

VNC、noVNC、RDP 和宿主桌面登录均为历史实验路径，已废弃，非当前生产方案。当前脚本调用容器内 agent-server 的 HTTP API 和登录 WebSocket，不修改微信客户端启动方式、持久化数据或容器配置。

默认配置：

| 配置 | 默认值 | 说明 |
| --- | --- | --- |
| HTTP API | `http://127.0.0.1:6174` | `status.sh`、`login.sh` 的默认请求地址 |
| 登录 WebSocket | `ws://127.0.0.1:6174/api/ws/login` | 登录脚本默认连接地址 |
| Token 文件 | `/srv/storage/cf-agent-wechat/secrets/auth-token` | root-only 认证凭据 |
| Session | `default` | 请求使用的 session 标识 |
| 容器名 | `cf-agent-wechat` | 辅助判断容器是否运行 |
| 登录工具 venv | `~/.local/share/cf-agent-wechat/venv` | 普通用户拥有的隔离环境 |

必须区分三类访问路径：

- `status.sh` 和 `login.sh` 默认请求 `http://127.0.0.1:6174`；这是脚本的
  `API_URL` 默认值，`WS_URL` 默认由它派生。
- Docker 在宿主机上的发布地址由生产 Compose 的必填变量
  `AGENT_WECHAT_BIND_IP` 决定，发布端口由 `AGENT_WECHAT_PORT` 决定。
- Gateway 不使用脚本默认地址，而是经 `cf-internal` 访问
  `http://cf-agent-wechat:6174`。

不得根据脚本的 `API_URL` 推断 Docker 的宿主发布地址；本文也不记录或虚构当前
生产环境的 `AGENT_WECHAT_BIND_IP` 实值。

## 状态检查

```bash
cd /opt/cf-agent-wechat
./scripts/status.sh
```

脚本读取受保护的 Token 后调用 `GET /api/status/auth`。认证状态接口成功返回时，容器显示为 `running`；接口无法访问时，脚本尝试用 Docker inspect 辅助区分 `running`、`stopped` 或 `unknown`。

| WeChat 状态 | 含义 | 下一步 |
| --- | --- | --- |
| `logged_in` | 微信已登录 | 无需执行登录流程 |
| `logged_out` | 微信未登录 | 执行 `./scripts/login.sh` |
| `app_not_running` | agent-server 可访问，但微信客户端未运行 | 先检查容器健康状态和日志 |
| `unavailable` | 配置、Token、网络、鉴权或响应解析失败 | 按错误信息排查，不能等同于 `logged_out` |

账号字段可能包含实际微信账号标识。公共文档、工单和截图中应使用 `<BOT_WECHAT_ACCOUNT_ID>`，不要记录真实值。

## 执行登录

以普通用户执行，不要使用 `sudo ./scripts/login.sh`：

```bash
cd /opt/cf-agent-wechat
./scripts/login.sh
```

实际流程：

1. 校验 URL、超时参数、Python 3 和 `curl`。
2. 受控读取 Token，调用 `GET /api/status/auth`。
3. 状态为 `logged_in` 时输出“微信已经登录”并立即返回成功，不创建 venv，也不调用登录接口。
4. 只有状态为 `logged_out` 时，才创建或复用普通用户 venv，并按 `scripts/requirements.txt` 检查依赖。
5. 调用 `POST /api/status/login` 触发登录，并尝试显示响应中已有的二维码。
6. 连接 `/api/ws/login`，处理 `status`、`qr`、`phone_confirm`、`login_success`、`login_timeout` 和 `error` 事件。
7. 收到 `login_success` 后再次查询认证状态，最多检查 5 次、间隔 2 秒；只有接口返回 `logged_in` 才判定完成。

### 已信任设备：手机确认

2026-08-13 的 CFserver 实机验证使用已信任设备。登录进入 `phone_confirm` 后：

1. 保持 SSH 终端和 `login.sh` 运行。
2. 在手机微信完成确认。
3. 等待 WebSocket `login_success`。
4. 等待脚本复核状态为 `logged_in`。
5. 再执行 `./scripts/status.sh` 确认结果。

“已信任设备 -> 手机确认 -> 登录成功”已经实机验证。

### 完全新设备：SSH 二维码

工具已实现二维码事件处理，预期流程如下：

1. `login.sh` 在 SSH 终端输出二维码。
2. 用手机微信扫描终端中最后显示的二维码；二维码刷新时扫描最新一张。
3. 按手机提示完成确认。
4. 等待 `login_success` 和随后的 `logged_in` 状态复核。

建议终端宽度至少为 80 列。工具会按终端宽度渲染二维码。

**截至 2026-08-13，“完全新设备 -> SSH 终端显示二维码 -> 手机扫码 -> 登录成功”尚未完成实机验证。** 不得将该场景描述为已验证。现场首次验证时只能保留脱敏后的事件类型和错误信息，不要记录二维码、账号标识或认证凭据。

## Token 安全模型

生产权限必须保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

普通用户通常不能直接读取 Token。脚本仅在读取默认路径失败时调用受控 `sudo`，并在 root 权限下逐项校验：

- `secrets` 必须存在、是普通目录、不是符号链接，且严格为 `root:root 700`。
- `auth-token` 必须存在、是普通文件、不是符号链接、root 可读，且严格为 `root:root 600`。
- 只有默认路径允许 sudo 读取；自定义 `TOKEN_FILE` 必须由当前普通用户自行读取。
- Token 只进入脚本的非导出变量，通过标准输入交给登录辅助程序，并用于构造 Authorization 请求头；不会进入命令行参数、环境变量或日志。
- WebSocket 错误文本会对当前 Token 做脱敏替换。

禁止绕过权限：

- 禁止执行 `chmod 644 auth-token`。
- 禁止为方便普通用户读取而更改所有者。
- 禁止复制到用户目录、临时文件、日志、工单或截图。
- 禁止用符号链接替换 `secrets` 目录或 Token 文件。

## Docker socket 权限降级

`status.sh` 主要依据认证状态 API 判断服务状态。只有需要辅助判断容器状态时才执行 Docker inspect：

1. 先以当前普通用户执行 `docker inspect`。
2. 只有错误同时表现为 Docker socket 访问权限不足时，才回退到 `sudo docker inspect`。
3. 其他 Docker 错误不会被误判为权限问题，也不会无条件提升权限。

无需仅为运行脚本把普通用户加入 `docker` 组。2026-08-13 已实机验证该 sudo inspect fallback。

## Python venv

`login.sh` 仅在需要启动登录流程时准备 Python 环境，默认位置：

```text
~/.local/share/cf-agent-wechat/venv
```

首次运行会以当前普通用户创建 venv，并从 `scripts/requirements.txt` 安装二维码和 WebSocket 依赖。脚本不会用 sudo 安装 Python 包，也不会修改系统 Python；现有 venv 不属于当前用户或不可写时会拒绝继续。

可用 `CF_AGENT_WECHAT_VENV` 覆盖路径。`XDG_DATA_HOME` 已设置时，默认路径以该目录为基础。

## 返回码

### `status.sh`

| 返回码 | 含义 |
| --- | --- |
| `0` | API 返回 `logged_in` |
| `1` | 配置、Python、`curl`、Token、API 请求或响应解析失败 |
| `2` | API 返回 `logged_out`，需要运行 `login.sh` |
| `3` | API 返回 `app_not_running` 或其他未识别状态 |

自动化不能把所有非零返回码都解释为“未登录”；只有 `2` 明确表示 `logged_out`。

### `login.sh`

| 返回码 | 含义 |
| --- | --- |
| `0` | 原本已登录并短路，或登录成功且复核为 `logged_in` |
| `1` | 配置、依赖、Token、API、WebSocket、超时、取消或登录后复核失败 |

Python WebSocket 辅助程序直接收到 `Ctrl+C` 时使用返回码 `130`；当前顶层 `login.sh` 会把辅助程序失败归并为 `1`，不保证透传 `130`。自动化应以顶层脚本的 `0`/`1` 约定为准。

## 常见错误

### Token 文件不存在

```bash
sudo stat -c '%U:%G %a %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
```

确认部署挂载和文件存在，不要自行生成替代 Token，不要放宽权限。恢复正确文件后重新运行 `./scripts/status.sh`。

### 普通用户无法读取 root-only Token

普通用户直接 `cat` 失败是预期安全行为。运行脚本时按 sudo 提示完成受控读取。若仍失败，检查 sudo 权限、严格的 `700`/`600` 权限，以及目录和文件均不是符号链接。不要改成全局可读。

### Docker socket 无权限

API 可访问时，Docker socket 权限不影响正常查询。API 失败时脚本仅在识别到 socket 权限错误后尝试 sudo inspect。若 sudo 也不可用，`Container` 可能显示 `unknown`：

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
```

### `logged_out`

```bash
cd /opt/cf-agent-wechat
./scripts/login.sh
```

不要删除持久化目录、替换 Token 或重建容器来代替正常登录。

### `app_not_running`

```bash
cd /opt/cf-agent-wechat
sudo docker compose -f docker/compose.cfserver.yaml ps
sudo docker compose -f docker/compose.cfserver.yaml logs --tail=200
```

确认微信客户端进程和容器健康状态后再重试。不要在 CFserver 上裸用不带 `-f` 的 `docker compose down`。

### 登录卡在 `phone_confirm`

- 确认手机微信仍显示登录确认页面，并在手机完成确认。
- 保持 SSH 会话运行，不要启动第二个并发登录流程。
- 等待默认登录超时；超时后重新执行 `./scripts/login.sh`。
- 手机已确认但没有 `login_success` 时，检查生产日志中的 WebSocket 和微信客户端错误，只记录脱敏信息。

### 收到 `login_success` 后仍失败

这表示 WebSocket 已报告成功，但认证接口在复核窗口内没有返回 `logged_in`。先运行 `./scripts/status.sh`，再检查生产日志；不要仅凭 WebSocket 事件宣告登录成功。

### venv 创建或依赖安装失败

确认已安装 Python 3、venv 支持和 pip，且当前用户可写 venv 父目录。若 venv 被 root 或其他用户创建，修复其所有权或移走错误目录后，以普通用户重试；不要用 `sudo ./scripts/login.sh`。

## 配置覆盖

| 变量 | 用途 |
| --- | --- |
| `API_URL` | HTTP API 基础地址 |
| `WS_URL` | 登录 WebSocket 完整地址 |
| `TOKEN_FILE` | Token 路径；自定义路径不支持 sudo 读取 |
| `SESSION_ID` | Session 标识 |
| `CONTAINER_NAME` | Docker 容器名 |
| `HTTP_CONNECT_TIMEOUT` | HTTP 建连超时秒数 |
| `HTTP_TIMEOUT` | HTTP 总超时秒数，默认 45 |
| `LOGIN_TIMEOUT_MS` | WebSocket 登录超时毫秒数，默认 300000 |
| `LOGIN_CONFIRM_RETRIES` | 登录后复核次数，默认 5 |
| `LOGIN_CONFIRM_INTERVAL` | 复核间隔秒数，默认 2 |
| `PYTHON_BIN` | 创建 venv 使用的 Python 3 命令 |
| `CF_AGENT_WECHAT_VENV` | 登录工具 venv 路径 |
| `QR_MAX_WIDTH` | 终端二维码最大宽度，最小为 21 |

`API_URL` 和 `WS_URL` 只改变登录脚本的请求目标，不会修改 Docker 端口发布。
不要把 6174 直接暴露到公网，也不要在命令、日志或文档中写入认证凭据。是否将
宿主发布地址收紧到 `127.0.0.1` 应作为独立安全项评审；本次文档修订不假定当前
绑定值，也不修改真实部署。

## 2026-08-13 实机验证矩阵

| 场景 | 状态 | 结果或边界 |
| --- | --- | --- |
| 普通用户直接运行 `status.sh` | 已实现并实机验证 | 可正常查询状态 |
| 识别容器运行状态 | 已实现并实机验证 | 正确识别生产容器运行中 |
| 识别 `logged_out` | 已实现并实机验证 | 返回码为 `2` 并提示登录 |
| 识别 `logged_in` | 已实现并实机验证 | 返回码为 `0` |
| 已登录时运行 `login.sh` | 已实现并实机验证 | 直接短路，不重复触发登录 |
| 未登录时启动登录流程 | 已实现并实机验证 | POST 请求和 WebSocket 监听正常 |
| 已信任设备手机确认 | 已实现并实机验证 | 收到 `phone_confirm`，手机确认后成功 |
| WebSocket 登录事件 | 已实现并实机验证 | 登录成功事件正常接收 |
| 登录成功后状态复核 | 已实现并实机验证 | 最终确认 `logged_in` |
| Docker socket 无权限回退 | 已实现并实机验证 | sudo inspect fallback 正常 |
| root-only Token 受控读取 | 已实现并实机验证 | 保持 `700`/`600` 权限可用 |
| 普通用户创建登录 venv | 已实现并实机验证 | 默认用户数据目录可用 |
| 登录后 90 秒稳定性 | 已实现并实机验证 | 登录状态保持稳定 |
| 健康监控不终止微信进程 | 已实现并实机验证 | 观察期内未杀死微信进程 |
| 完全新设备 SSH 二维码扫码登录 | 已实现但尚未实机验证 | 工具已支持，现场闭环待验证 |
| 无人值守自动完成手机确认 | 规划中 | 当前仍需要手机操作 |

本项目当前可表述为：**微信入口、登录管理、消息接口和 Gateway 网络访问已完成实机验证。** 该结论不包含上层 AI 能力。
