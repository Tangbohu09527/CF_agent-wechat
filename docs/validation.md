# V1 验证记录

## 验证基线

| 项目 | 已验证值 |
| --- | --- |
| 虚拟化平台 | VMware Workstation |
| 操作系统 | Debian 13 Trixie |
| Linux kernel | 6.12 |
| Docker | Docker CE / Docker Engine 29.x |
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
| VNC 访问恢复 | **Verified** | PASS，依赖额外修复服务 |

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

微信 GUI 登录 **不等于** agent-wechat 初始化完成。两个状态来自不同状态源；
即使 GUI 已登录，`/api/status/auth` 仍可能显示 `logged_out`。

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

只有收到 `login_success`、取得 `userId`，并成功调用业务 API 后，才判定
agent-wechat session 初始化完成。

## API 能力

| 能力 | 状态 | 结果 |
| --- | --- | --- |
| 联系人读取 | **Verified** | PASS |
| 聊天读取 | **Verified** | PASS |
| 消息读取 | **Verified** | PASS |
| 私聊文本发送 | **Verified** | PASS |
| 群聊文本发送 | **Verified** | PASS |
| 图片发送 | **Pending** | 未验证 |
| 文件发送 | **Pending** | 未验证 |
| WebSocket 实时消息事件 | **Pending** | 未验证 |
| Hermes Gateway 集成 | **Pending** | 未验证 |

接口路径和认证边界见 [api.md](api.md)。

## 回归检查

镜像 digest、Docker/Compose 版本、宿主机系统或 VNC 修复逻辑变化后，至少重跑：

1. Compose 配置解析和容器健康检查。
2. auth-token 认证。
3. `/api/ws/login` 完整初始化。
4. 联系人、聊天、消息读取。
5. 私聊与群聊文本发送。
6. 宿主机重启后的容器、agent-wechat 和 VNC 恢复。
