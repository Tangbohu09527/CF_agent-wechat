# V1 验证记录

## 验证基线

| 项目 | 已验证值 |
| --- | --- |
| 虚拟化平台 | VMware Workstation |
| 操作系统 | Debian 13 Trixie |
| Linux kernel | 6.12 |
| Docker | Docker CE / Docker Engine 29.x |
| 容器 | `agent-wechat` |
| 桌面环境 | XFCE |
| 远程桌面 | noVNC/VNC |
| Docker Compose | v2 |
| 镜像 tag | `ghcr.io/thisnick/agent-wechat:0.11.15` |
| 镜像部署方式 | digest 固定：`ghcr.io/thisnick/agent-wechat@sha256:<verified-digest>` |

本记录的结论只适用于上述环境和实际验证过的 digest。完整 digest 属于部署证据，
应保存在受控运维记录中。

## Deployment

| 验证项 | 状态 | 结果 |
| --- | --- | --- |
| Debian 环境部署 | **Verified** | PASS |
| Docker 安装 | **Verified** | PASS |
| Compose 启动 | **Verified** | PASS |
| 镜像 digest 锁定 | **Verified** | PASS |
| auth-token 配置 | **Verified** | PASS |
| 容器健康检查 | **Verified** | PASS |

健康检查入口为 `/health`；API 默认通过宿主机回环地址 `127.0.0.1:6174`
访问。

## Runtime

| 验证项 | 状态 | 结果 |
| --- | --- | --- |
| Docker `restart: unless-stopped` | **Verified** | PASS |
| Debian 重启后容器自动恢复 | **Verified** | PASS |
| agent-wechat 自动启动 | **Verified** | PASS |
| Container health | **Verified** | 正常 |
| VNC 访问恢复 | **Verified** | PASS，依赖额外修复服务 |
| 微信客户端登录 | **Known Issue** | Docker 重启后需要重新登录 |
| agent-server 登录恢复 | **Verified** | 微信重新登录后状态正常 |

### 运行时配置差异

**Known Issue**：仓库当前 `docker/docker-compose.yml` 使用
`restart: "no"`，与验证环境的 `unless-stopped` 不同。仓库基线不能直接复现
上述自动恢复结果。本次纯文档更新未修改 Docker 运行逻辑。

## VNC

**Known Issue**：agent-wechat 默认启动后的 VNC 交互状态不稳定，可能出现页面
可访问但无法正常交互的情况。

验证环境增加了：

- `docker/fix-vnc.sh`：恢复 interactive x11vnc。
- `cf-wechat-vnc-fix.service`：由 systemd 在启动/恢复阶段执行修复。

验收不应只检查端口；还应确认 noVNC 页面可见、鼠标键盘可交互，并检查：

```bash
systemctl status cf-wechat-vnc-fix.service
journalctl -u cf-wechat-vnc-fix.service -n 100 --no-pager
```

**Known Issue**：这两个运维资产当前未包含在仓库中。新环境复现前需从受控部署记录
取得或在后续配置变更中正式纳入仓库。

## 微信初始化流程

微信 GUI 登录 **不等于** agent-wechat 初始化完成。两个状态来自不同状态源。本轮
Docker 重启后微信客户端需要重新登录；重新登录后 agent-server 登录状态恢复正常。

正确流程：

```text
/api/ws/login
    ↓
login flow
    ↓
login_success
    ↓
userId
    ↓
contacts / chats / messages API 可用
```

初始化流程完成后必须直接复核 `GET /api/status/auth` 和业务 API。本轮已验证
`status=logged_in`，`loggedInUser=<wechat-user-id>`。

## Gateway/Hermes V1 Staging

| 验证项 | 状态 | 结果 |
| --- | --- | --- |
| Gateway WeChat Polling | **Verified** | 文本消息进入 Message Store |
| Identity / Permission | **Verified** | 身份解析和权限准入通过 |
| Employee Workspace / AIThread | **Verified** | 线程创建与绑定通过 |
| Hermes dispatch / response | **Verified** | API 调用和响应回传通过 |
| WeChat outbound | **Verified** | `{"chatId":"...","text":"..."}` |
| Self echo guard | **Verified** | 原始 `isSelf` / `RawWechatMessage.is_self=true` 在 normalize/sink 前过滤，checkpoint 推进 |
| End-to-end text reply | **Verified** | 微信收到 Hermes 文本回复 |
| Group context key | **Known Issue** | 当前 whole-room；目标 `bot + group + sender` |

联调环境为 Debian 13 Docker agent-wechat、CF_agent-gateway Worker 和 Windows AI
主机 Hermes API。Gateway 仓库验证结果：`pytest: 393 passed`、`ruff: passed`、
`git diff --check: passed`。

该闭环只覆盖文本。图片理解、附件传递、文件处理、OCR、压缩包解析、企业知识库、
Skill 自动执行和生产自动部署均未验证。

## API 能力

| 能力 | 状态 | 结果 |
| --- | --- | --- |
| 联系人读取 | **Verified** | PASS |
| 聊天读取 | **Verified** | PASS |
| 消息字段：`sender`、`senderName`、`content`、`timestamp`、`isSelf` | **Verified** | PASS |
| 按 `chatId` 文本发送 | **Verified** | `success=true` |
| agent-wechat `txt`、`zip` 文件入口识别 | **Verified** | `type=49`、`localId`、文件名 |
| `txt`、`zip` Base64 获取 | **Verified** | PASS |
| 群消息、发送者和群文件 | **Verified** | `isGroup=true` |
| 文本/文件引用上下文 | **Verified** | `reply.sender`、`reply.content` |
| 合并转发消息 | **Verified** | 外层识别已验证，内部解析待增强 |
| 图片发送 | **Pending** | 未验证 |
| 通过 API 发送文件 | **Pending** | 未验证 |
| WebSocket 实时消息事件 | **Pending Investigation** | 连接成功，未观察到事件 |
| Hermes Gateway 文本集成 | **Verified** | V1 Staging 文本闭环通过 |

完整实测结果见 [05_V1验证结果.md](05_V1验证结果.md)，接口路径和认证边界见
[api.md](api.md)。入口侧文件识别不等于 Gateway 附件传递、系统文件处理或压缩包
解析。

## 回归检查

镜像 digest、Docker/Compose 版本、宿主机系统或 VNC 修复逻辑变化后，至少重跑：

1. Compose 配置解析、容器自动恢复和健康检查。
2. noVNC/VNC 可访问性与交互。
3. 微信客户端重新登录。
4. `/api/status/auth` 返回 `logged_in`。
5. 指定 `chatId` 的文本发送和消息字段读取。
6. `txt`、`zip` 文件消息识别与 Base64 获取。
7. 群消息、发送者、群文件和 `isGroup`。
8. 文本、文件引用的 `reply` 上下文。
9. 合并转发消息的外层标题和发送者；media API 应保持已记录的 `unsupported` 边界。
10. `/api/ws/events` 连接及新消息事件观察；没有事件时保持 Pending。
11. Gateway Polling 文本进入 Message Store 并完成 Identity、Permission 和 AIThread。
12. Hermes 响应使用 `{"chatId":"...","text":"..."}` 返回微信。
13. 自身消息在 normalize/sink 前过滤，不进入 admission 或 Hermes，但 checkpoint
    必须推进。
14. 群聊 whole-room 偏差保持 Known Issue，直至按 `bot + group + sender` 隔离。
