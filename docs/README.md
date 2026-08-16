# CF_agent-wechat 文档索引

本目录按“当前权威资料、生产验证记录、历史实验快照”分层。部署与登录生产基线日期为
2026-08-13，最新消息与媒体生产证据日期为 2026-08-14；状态区分“已实现并
实机验证”“已实现但尚未实机验证”“规划中”。证据不足以判断实现状态时，只写
“尚未完成生产实机验证”，不强行归类。

## 当前权威资料

| 入口 | 用途 |
| --- | --- |
| [项目说明](00_项目说明.md) | 项目职责、边界、当前状态与安全口径 |
| [架构设计](01_架构设计.md) | 容器内 Xvfb 链路、组件职责与 Gateway 调用关系 |
| [CFserver 正式部署](deployment/cfserver-production.md) | 正式 Compose、目录、权限、启停、重建、重启检查和回滚 |
| [微信登录管理](login-management.md) | `status.sh`、`login.sh`、返回码、权限模型和登录验证矩阵 |
| [API 边界](api.md) | agent-server 当前生产端点、登录接口和历史能力边界 |
| [生产运维](operations.md) | 日常检查、启停、备份恢复、升级与交接 |
| [故障排查](troubleshooting.md) | 容器、健康、Token、登录、进程与项目边界排查 |

> **生产警告：不得在 CFserver 上执行不带 `-f` 的
> `docker compose down`。** 正式命令必须显式指定
> `docker/compose.cfserver.yaml`。

## 验证记录

| 入口 | 用途 |
| --- | --- |
| [验证总览](validation.md) | 当前状态矩阵、准确表述和回归要求 |
| [2026-08-13 CFserver 生产验证](validation/2026-08-13-cfserver-production.md) | 部署、登录和基础接口的脱敏实机记录 |
| [2026-08-14 消息与媒体生产验证](validation/2026-08-14-message-media-production.md) | 文本发送、群消息字段、引用和图片 media 的脱敏实机记录 |

## 历史实验记录

以下文件已封存。它们可能包含 VNC/noVNC、x11vnc、XFCE、宿主桌面或旧 Compose
步骤，均属于历史实验、已废弃、非当前生产方案：

| 入口 | 历史用途 |
| --- | --- |
| [02 部署记录](02_部署记录.md) | 早期实验部署与桌面调试记录 |
| [03 V1 验证计划](03_V1验证计划.md) | 当时的 V1 验证计划 |
| [04 二开规划](04_二开规划.md) | 当时的扩展规划快照 |
| [05 V1 验证结果](05_V1验证结果.md) | 早期固定环境的能力验证结果 |
| [Docker 实验室手册](../docker/README.md) | `docker/docker-compose.yml` 的实验室资料 |

历史记录不得作为 CFserver 生产 runbook。当前事实发生冲突时，以
[验证总览](validation.md)、对应日期的生产验证记录和
[CFserver 正式部署](deployment/cfserver-production.md) 为准。

## 维护规则

1. 新验证结论必须记录日期、Commit、环境、动作、结果和未验证范围。
2. 只有实机通过后，状态才能改为“已实现并实机验证”。
3. 当前部署命令只维护在生产部署与运维文档，其他页面链接到权威入口。
4. Gateway 只描述调用关系，不在本仓库展开其内部权限或 Hermes 实现。
5. 文档不得包含真实账号、联系人、聊天标识、服务器 IP、二维码、Token、指纹、
   API Key、密码或本地 Windows 绝对路径。
