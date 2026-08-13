# 2026-08-13 CFserver 生产验证记录

## 记录边界

本文记录 `CF_agent-wechat` 在 CFserver 上的脱敏实机验证结果。基线 Commit：
`fe3c963`。本文不记录真实微信账号、联系人、群聊标识、服务器 IP、Token、Token
指纹、密钥或二维码。

状态定义：

- **已实现并实机验证**：本次在 CFserver 上实际执行并观察到预期结果。
- **已实现但尚未实机验证**：实现入口存在，但目标现场场景未完成闭环。
- **规划中**：尚未形成可执行、可验收的当前生产能力。

## 部署基线

| 验证项 | 结果 | 状态 |
| --- | --- | --- |
| 正式 Compose | `docker/compose.cfserver.yaml` 配置校验通过 | 已实现并实机验证 |
| 正式容器 | `cf-agent-wechat` 运行 | 已实现并实机验证 |
| 容器健康 | 健康检查通过 | 已实现并实机验证 |
| VNC 开关 | `ENABLE_VNC=0` | 已实现并实机验证 |
| 显示环境 | `DISPLAY=:99` | 已实现并实机验证 |
| Xvfb | `1280x800x24` | 已实现并实机验证 |
| Docker 网络 | `cf-internal` 已接入 | 已实现并实机验证 |

正式配置使用容器内 Xvfb，不挂载宿主 X11，不依赖宿主 XFCE 或 RDP；未配置自定义
entrypoint 覆盖，使用镜像默认启动流程。`docker/docker-compose.yml` 是实验室或
验证配置，不是本次生产验证使用的配置。

## 容器内运行链路

| 验证项 | 结果 | 状态 |
| --- | --- | --- |
| Xvfb | 进程正常 | 已实现并实机验证 |
| fluxbox | 进程正常 | 已实现并实机验证 |
| dunst | 进程正常 | 已实现并实机验证 |
| WeChat Linux 客户端 | 进程正常 | 已实现并实机验证 |
| agent-server | 进程与健康接口正常 | 已实现并实机验证 |
| x11vnc | 进程不存在 | 已实现并实机验证 |
| websockify | 进程不存在 | 已实现并实机验证 |

因此，VNC、noVNC、x11vnc 和 websockify 不在当前生产链路中。

## 登录管理验证

| 场景 | 结果 | 状态 |
| --- | --- | --- |
| 普通用户直接运行 `status.sh` | 可执行并返回明确状态 | 已实现并实机验证 |
| 容器运行状态识别 | 正确识别正式容器 | 已实现并实机验证 |
| `logged_out` 识别 | 正确识别并提示执行登录 | 已实现并实机验证 |
| `logged_in` 识别 | 正确识别登录完成 | 已实现并实机验证 |
| 已登录时运行 `login.sh` | 短路成功，不重复登录 | 已实现并实机验证 |
| 未登录时运行 `login.sh` | 成功启动登录流程 | 已实现并实机验证 |
| 手机操作 | 已信任设备收到并完成手机确认 | 已实现并实机验证 |
| WebSocket 登录事件 | 正常接收 `phone_confirm` 与成功事件 | 已实现并实机验证 |
| 登录成功后复核 | 认证状态最终为 `logged_in` | 已实现并实机验证 |
| Docker socket 无权限 | `sudo docker inspect` fallback 正常 | 已实现并实机验证 |
| root-only Token | 受控 sudo 读取正常 | 已实现并实机验证 |
| 普通用户 venv | 创建和使用正常 | 已实现并实机验证 |

登录工具默认 venv 为 `~/.local/share/cf-agent-wechat/venv`。Token 权限在验证期间
保持：

```text
/srv/storage/cf-agent-wechat/secrets             root:root 700
/srv/storage/cf-agent-wechat/secrets/auth-token  root:root 600
```

未通过放宽权限实现登录，且不得建议 `chmod 644 auth-token`。

## 稳定性验证

登录成功后持续观察 90 秒：

- 登录状态保持为 `logged_in`。
- WeChat 进程保持运行。
- 健康监控未终止 WeChat 进程。

该结果只覆盖本次 90 秒观察窗口，不等同于长期稳定性验证。

## Gateway 网络访问

`cf-agent-wechat` 已接入统一 Docker 网络 `cf-internal`。Gateway 使用
`http://cf-agent-wechat:6174` 访问本服务，以下端点已完成调用验证：

| 端点 | 结果 | 状态 |
| --- | --- | --- |
| `/health` | 可访问 | 已实现并实机验证 |
| `/api/status/auth` | 可访问并返回认证状态 | 已实现并实机验证 |
| `/api/chats` | 可访问 | 已实现并实机验证 |
| `/api/messages/{chat_id}` | 可访问 | 已实现并实机验证 |

本记录只确认网络与本项目接口调用。Gateway 内部权限、Hermes 和业务编排不属于
本项目验证边界。

## 尚未完成的实机验证

以下流程已经由登录工具实现，但本次没有在完全新设备上完成实机闭环：

```text
完全新设备
  -> SSH 终端显示二维码
  -> 手机扫码
  -> 手机确认
  -> 登录成功
```

当前实际通过的是：

```text
已信任设备
  -> 手机确认
  -> 登录成功
```

因此，新设备二维码场景的状态是 **已实现但尚未实机验证**，不得写成已经验证。

## 结论

本次验证支持以下准确表述：

> 微信入口、登录管理、消息接口和 Gateway 网络访问已完成实机验证。

该结论不表示上层 AI 链路已经完成，也不外推到其他镜像、部署文件、设备信任状态
或长期运行周期。

当前生产运维见 [CFserver 正式部署](../deployment/cfserver-production.md)，登录细节见
[微信登录管理](../login-management.md)，总览见 [验证总览](../validation.md)。
