# CF_agent-wechat 文档索引

本页是唯一文档索引。当前事实、可复用 Runbook 与一次性验收记录必须分开使用。

## Start here

| 文档 | 用途 | 权威性 |
| --- | --- | --- |
| [当前生产状态](production-status.md) | 生产在线状态、Git/PR 栈、镜像证据、重启事实与已知限制 | **当前生产事实唯一入口** |
| [CFserver 生产 Runbook](deployment/cfserver-production.md) | Bootstrap、fresh QR、stop、status、重启、升级与回滚 | **详细生产操作唯一入口** |
| [R2 生产验收记录](validation/2026-09-03-forced-qr-r2-production.md) | 2026-09-03 forced-QR R2 实机 Closeout | **当前生产验收唯一详细记录** |

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
| [2026-09-03 R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md) | 当前一次性记录 | forced fresh QR、重启、Gateway Contract 与集成链路证据 |
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
| [R2 实现审计](deployment-audit.md) | PR #2/#3 等实现选择的历史审计，不是操作入口 |
| [Docker 实验室手册](../docker/README.md) | 实验室 Compose 与 VNC/noVNC 资料 |

历史结论只在其日期、Commit 和明确范围内有效。与当前事实冲突时，以
[当前生产状态](production-status.md)为准；执行生产操作时，只使用
[CFserver 生产 Runbook](deployment/cfserver-production.md)。
