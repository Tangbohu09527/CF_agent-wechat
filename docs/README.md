# CF_agent-wechat 文档索引

本页是唯一文档索引。当前事实、可复用 Runbook 与一次性验收记录必须分开使用。

## Start here

| 文档 | 用途 | 权威性 |
| --- | --- | --- |
| [当前生产状态](production-status.md) | 生产在线状态、repository promotion、镜像证据、重启事实与已知限制 | **当前生产事实唯一入口** |
| [CFserver 生产 Runbook](deployment/cfserver-production.md) | Bootstrap、fresh QR、stop、status、重启、升级与回滚 | **详细生产操作唯一入口** |
| [R2 生产验收记录](validation/2026-09-03-forced-qr-r2-production.md) | 2026-09-03 forced-QR R2 实机 Closeout | **当前生产验收唯一详细记录** |

## 新开发者阅读顺序

1. [项目说明](00_项目说明.md)：职责、状态口径和安全边界。
2. [架构设计](01_架构设计.md)：Runtime、Archive、Controller 与三层 readiness。
3. [当前生产状态](production-status.md)：当前事实、PR 提升和证据限制。
4. [新设备 Bootstrap](deployment/new-device-bootstrap.md)：空白 Host 的准备门禁。
5. [CFserver 生产 Runbook](deployment/cfserver-production.md)：唯一详细生产操作。
6. [登录生命周期](login-management.md)：fresh QR、锁、权限和失败隔离。
7. [生产运维](operations.md)与[故障排查](troubleshooting.md)。
8. [验证总览](validation.md)：当前验收、历史证据和未来回归。
## Current production

| 文档 | 用途 |
| --- | --- |
| [项目说明](00_项目说明.md) | 项目职责、外部边界和当前限制摘要 |
| [验证总览](validation.md) | 已完成 R2 验收、未来 Release 清单、历史记录与剩余限制 |
| [生产运维](operations.md) | 日常状态、维护、重启边界、归档盘点和交接 |

## Architecture and boundaries

| 文档 | 用途 |
| --- | --- |
| [架构设计](01_架构设计.md) | Host/Docker、Xvfb、WeChat、agent-server、Gateway 的层级与职责 |
| [API 边界](api.md) | 当前脚本实际使用的 API、上游观察行为、认证与超时边界 |

## Deployment

| 文档 | 用途 |
| --- | --- |
| [部署导航](deployment-guide.md) | 区分 Bootstrap、start、stop、status 与 recovery |
| [新设备 Bootstrap](deployment/new-device-bootstrap.md) | 只准备部署输入，不创建 Session 或启动服务 |

## Login lifecycle

| 文档 | 用途 |
| --- | --- |
| [登录生命周期](login-management.md) | 状态机、脚本职责、权限、锁、退出码与 fail-closed 原则 |
| [QR 操作指南](qr-login-guide.md) | Operator 在 SSH TTY 中扫码和判断成功/失败 |

## Operations and recovery

| 文档 | 用途 |
| --- | --- |
| [恢复指南](recovery-guide.md) | 按“检查 -> 判断 -> 操作 -> 验证 -> 失败回退”处理故障 |
| [故障排查](troubleshooting.md) | 按症状定位只读检查、安全动作和禁止操作 |

## Validation evidence

| 文档 | 分类 | 用途 |
| --- | --- | --- |
| [2026-09-03 R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md) | 带日期生产证据 | forced fresh QR、重启、Gateway Contract 与集成链路证据 |
| [2026-08-13 CFserver 记录](validation/2026-08-13-cfserver-production.md) | 历史快照 | 旧可信设备登录与基础 API 证据，不能证明 forced QR |
| [2026-08-14 消息/媒体记录](validation/2026-08-14-message-media-production.md) | 历史快照 | 当时消息与图片 media 观察，不能替代当前 Runbook |

## Historical documents

以下材料保留原路径以维持链接，但都不是当前 CFserver Runbook：

| 文档 | 历史范围 |
| --- | --- |
| [部署记录](02_部署记录.md) | 早期 V1、VNC/noVNC、自动恢复实验 |
| [V1 验证计划](03_V1验证计划.md) | 早期验收计划快照 |
| [二开规划](04_二开规划.md) | 早期扩展设想 |
| [V1 验证结果](05_V1验证结果.md) | 固定实验环境能力记录 |
| [R2 实现审计](deployment-audit.md) | PR #2 等实现选择的历史审计，不是操作入口 |
| [Docker 实验室手册](../docker/README.md) | 实验室 Compose 与 VNC/noVNC 资料 |

历史结论只在其日期、Commit 和明确范围内有效。与当前事实冲突时，以
[当前生产状态](production-status.md)为准；执行生产操作时，只使用
[CFserver 生产 Runbook](deployment/cfserver-production.md)。

Repository promotion 已于 2026-09-04 完成，branch authority 为 `main`；live tip
通过 GitHub 或 `git rev-parse origin/main` 动态查询。该仓库事件不改写
2026-09-03 及更早验证记录，也不证明任何选定 Release Commit 已重新构建或部署到
CFserver。

## 文档维护规则

1. 当前事实、可复用 Runbook、一次性验收记录和 Historical 文档必须分开。
2. “已验证”必须注明自动化或带日期的 CFserver 行为证据，二者不能互相替代。
3. 新现场结论记录日期、源码 SHA、镜像证据、环境、动作、结果和未证明范围。
4. 不从历史可信设备、VNC/noVNC 或旧 Gateway 架构外推当前 forced-QR 能力。
5. 不记录 Token、二维码、账号、联系人、Chat ID、正文、服务器地址或数据库凭据。
6. Gateway、Hermes 与其他仓库的内部部署说明留在各自项目。
