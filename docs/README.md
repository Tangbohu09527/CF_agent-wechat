# CF_agent-wechat 文档索引

本目录提供本项目独立部署和维护所需的全部说明，不依赖其他仓库文档。文档只描述
Gateway 的调用与 `wechat-worker` 控制契约，不展开其内部实现。

> [!WARNING]
> forced-QR 目标流程要求代码中存在 `start-qr-login.sh`、`stop-qr-runtime.sh`、
> `qr-runtime-common.sh` 以及 runtime 版生产 Compose。2026-08-20 审计时，这些实现仅在
> 本仓库 `feat/forced-qr-login@9cb7163`，未合入当时的 `main` 代码基线 `96264e2`。执行目标流程前必须
> 先通过新设备部署文档中的代码能力门禁。

## 新开发者阅读顺序

1. [项目说明](00_项目说明.md)：职责、非职责和状态口径。
2. [架构设计](01_架构设计.md)：容器、runtime/archive、登录和 worker 闸门。
3. [新设备部署引导](deployment/new-device-bootstrap.md)：从空白 Debian 主机开始部署。
4. [CFserver 正式部署](deployment/cfserver-production.md)：目标生产配置与生命周期契约。
5. [微信登录管理](login-management.md)：forced-QR、扫码和登录失败恢复。
6. [生产运维](operations.md)：日常检查、停止、升级、归档和回滚。
7. [验证总览](validation.md)：自动化、历史实机、未验证和后续规划。
8. [故障排查与常见问题](troubleshooting.md)：按症状恢复并确认项目边界。

## 当前权威资料

| 文档 | 负责内容 |
| --- | --- |
| [项目说明](00_项目说明.md) | 项目定位、状态、边界和安全口径 |
| [架构设计](01_架构设计.md) | 数据流、生命周期、runtime/archive 与可用判定 |
| [新设备部署引导](deployment/new-device-bootstrap.md) | 主机、Docker、代码门禁、存储、Token、环境和首次启动 |
| [CFserver 正式部署](deployment/cfserver-production.md) | forced-QR 目标 Compose 与 start/stop 契约 |
| [微信登录管理](login-management.md) | forced-QR 协议、状态、返回语义与失败恢复 |
| [API 边界](api.md) | agent-server 的认证、聊天、消息和 media 边界 |
| [生产运维](operations.md) | 日常检查、升级、归档、容量、回滚和交接 |
| [故障排查与常见问题](troubleshooting.md) | 配置、锁、归档、进程、QR、API、worker 与 FAQ |

## 验证资料

| 文档 | 证据边界 |
| --- | --- |
| [验证总览](validation.md) | 新实现的自动化证据、旧实机证据、未验证项和现场清单 |
| [2026-08-13 CFserver 生产验证](validation/2026-08-13-cfserver-production.md) | 旧基线的部署、已信任设备登录和基础接口证据 |
| [2026-08-14 消息与媒体生产验证](validation/2026-08-14-message-media-production.md) | 旧基线的消息、引用和图片 media 证据 |

两份日期记录是历史事实，不得改写成 forced-QR 新流程已经实机通过。

## 历史实验资料

以下页面可能包含 VNC/noVNC、旧 Compose、旧持久化布局或桌面调试步骤，只用于追溯，
不得作为当前生产 runbook：

- [02 部署记录](02_部署记录.md)
- [03 V1 验证计划](03_V1验证计划.md)
- [04 二开规划](04_二开规划.md)
- [05 V1 验证结果](05_V1验证结果.md)
- [Docker 实验室手册](../docker/README.md)

## 文档维护规则

1. “已完成”只说明实现存在；“已验证”必须注明自动化或带日期的 CFserver 实机证据。
2. 新实机结论必须记录日期、代码 Commit、镜像 digest、环境、动作、结果和未验证范围。
3. 正常流程只在部署、登录和运维权威页维护；其他页面链接到权威入口。
4. 不从旧基线外推新 runtime、forced-QR、worker 闸门或长期稳定性结论。
5. 不记录 Token、二维码、真实账号、联系人、聊天 ID、正文、服务器地址、API Key、
   密码或数据库内容。
6. 不在本仓库复制或维护 Gateway、Hermes 或其他项目的内部部署说明。
