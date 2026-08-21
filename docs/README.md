# CF_agent-wechat 文档索引

以下四份文档是 V1 Beta 生产部署和恢复的权威入口：

1. [Deployment Guide](deployment-guide.md)：新 Debian 主机初始化、变量、目录、启动和验收。
2. [Recovery Guide](recovery-guide.md)：容器/主机重启、会话恢复、备份与运行态恢复。
3. [QR Login Guide](qr-login-guide.md)：首次登录、会话失效后的重新登录和状态判读。
4. [Troubleshooting](troubleshooting.md)：按容器、health、API、auth 四层定位故障。

生产基线保留 `data/`、`wechat-home/` 和 `auth-token`，重启后优先恢复原会话。
`logged_out` 才触发新的二维码登录。任何要求每次启动清空 runtime、归档旧会话或调用
`start-qr-login.sh` 的旧说明均不适用于当前代码。

## 参考资料

| 文档 | 内容 |
| --- | --- |
| [项目说明](00_项目说明.md) | 项目职责和边界 |
| [架构设计](01_架构设计.md) | 容器、网络、持久化和恢复模型 |
| [API 边界](api.md) | agent-server API |
| [验证总览](validation.md) | 自动化与现场验证记录 |
| [部署审计](deployment-audit.md) | 手工步骤、外部依赖、已修复风险和不可自动恢复边界 |
| [历史生产验证：2026-08-13](validation/2026-08-13-cfserver-production.md) | 旧版本现场证据 |
| [历史消息与媒体验证：2026-08-14](validation/2026-08-14-message-media-production.md) | 旧版本现场证据 |

以下旧路径保留用于外部链接兼容，内容会转向上面的权威指南：

- [新设备部署引导](deployment/new-device-bootstrap.md)
- [CFserver 正式部署](deployment/cfserver-production.md)
- [生产运维](operations.md)
- [微信登录管理](login-management.md)

`02_部署记录.md`、`03_V1验证计划.md`、`04_二开规划.md`、`05_V1验证结果.md` 和
`../docker/README.md` 是历史实验资料，不能作为当前生产 runbook。

## 文档安全规则

- 不记录 Token、二维码、真实账号、联系人、聊天 ID、消息正文或服务器地址。
- “自动化测试通过”不能替代 Debian 主机、Docker 重启和真实手机扫码验证。
- 镜像引用必须记录 digest；不得在生产说明中使用 `latest`。
- Gateway 是调用方。本仓只检查其可选目录，不启动、停止或修改 Gateway。
