# 微信登录管理

## 适用范围

本管理层只调用 agent-wechat 已有的 HTTP API 和登录 WebSocket，不修改上游镜像、
Rust agent-server、微信启动逻辑或 Docker 运行方式，也不依赖 VNC/noVNC。所有操作
都应在部署主机的 SSH 终端中执行。

默认配置：

| 配置 | 默认值 |
| --- | --- |
| API | `http://127.0.0.1:6174` |
| 登录 WebSocket | `ws://127.0.0.1:6174/api/ws/login` |
| auth-token | `/srv/storage/cf-agent-wechat/secrets/auth-token` |
| session | `default` |
| 容器名 | `cf-agent-wechat-lab` |

脚本只从 token 文件读取密钥，不会把 token 写入仓库或输出到终端。token 文件不得是
符号链接。若实际部署目录不同，应显式设置 `TOKEN_FILE`，不要复制或重新生成 token：

```bash
TOKEN_FILE=/actual/deployment/secrets/auth-token ./scripts/status.sh
```

## 首次部署与登录

在仓库根目录执行：

```bash
chmod 755 scripts/common.sh scripts/status.sh scripts/login.sh scripts/qr_login.py
./scripts/status.sh
./scripts/login.sh
```

`login.sh` 首次运行时会在当前用户的数据目录创建独立 Python venv，并从
`scripts/requirements.txt` 安装 `Pillow`、`qrcode` 和 `websocket-client`。它不会
修改系统 Python。默认 venv 位于
`${XDG_DATA_HOME:-$HOME/.local/share}/cf-agent-wechat/venv`；受控环境可通过
`CF_AGENT_WECHAT_VENV` 指定其他位置。

登录流程如下：

1. 查询 `GET /api/status/auth`。已经是 `logged_in` 时直接退出。
2. 未登录时调用 `POST /api/status/login`。
3. 使用 Bearer token 连接 `/api/ws/login`，等待 agent-wechat 启动登录流程。
4. 在 SSH 终端显示二维码；使用手机微信扫码。
5. 手机出现确认提示时，在手机微信确认登录。
6. 收到 `login_success` 后再次查询认证状态，只有接口返回 `logged_in` 才视为完成。

二维码可能在登录过程中刷新。每次显示新二维码时，应扫描终端中最后出现的一张。
终端宽度建议至少 80 列，浅色和深色终端均可使用。

## 日常状态检查

```bash
./scripts/status.sh
```

已登录时示例：

```text
================================
CF Agent WeChat Status
================================

Container:
  running

WeChat:
  logged_in

Account:
  wxid_xxxxx

================================
```

`status.sh` 以认证 API 可达作为服务正在运行的直接证据；Docker CLI 可用时，也会在
接口失败场景中辅助判断容器是 `running` 还是 `stopped`。接口不可达、鉴权失败或
响应无法解析时脚本返回非零，不会把故障误报为 `logged_out`。

## 自动恢复与登录失效

持久化数据和微信客户端状态可用时，脚本不会重复触发登录：`login.sh` 检测到
`logged_in` 会输出“微信已经登录。”并退出。

若 `status.sh` 显示 `logged_out`，重新执行：

```bash
./scripts/login.sh
```

若状态是 `app_not_running`、`unknown` 或 `unavailable`，先检查容器健康状态和日志，
不要删除 `data/`、`wechat-home/`，也不要替换 auth-token。登录超时、服务端错误或
WebSocket 在成功事件前断开时，脚本会返回非零；处理提示的运行故障后再重试。

## 配置覆盖

以下变量可在命令前显式设置：

| 变量 | 用途 |
| --- | --- |
| `API_URL` | HTTP API 基础地址 |
| `WS_URL` | 登录 WebSocket 完整地址 |
| `TOKEN_FILE` | auth-token 文件路径 |
| `SESSION_ID` | session 标识，当前基线使用 `default` |
| `CONTAINER_NAME` | Docker 容器名 |
| `HTTP_CONNECT_TIMEOUT` | HTTP 建连超时秒数 |
| `HTTP_TIMEOUT` | HTTP 总超时秒数，默认 45 秒 |
| `LOGIN_TIMEOUT_MS` | WebSocket 登录超时毫秒数，默认 300000 |
| `PYTHON_BIN` | 创建 venv 所用的 Python 3 命令 |
| `CF_AGENT_WECHAT_VENV` | 隔离 venv 路径 |

服务没有 TLS，默认只应通过宿主机回环地址访问。远程运维时登录 SSH 主机后运行脚本，
不要将 6174 暴露到公网，也不要把 token 或二维码写入日志、工单和截图。
