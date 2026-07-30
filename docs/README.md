# CF_agent-wechat 文档

本目录记录 CF_agent-wechat V1 的边界、部署事实、验证结果、接口和运维要求。
状态统一使用以下标记：

- **Verified**：仅在本文记录的镜像与测试环境中实际验证通过。
- **Pending**：已进入计划，但尚未完成验证。
- **Known Issue**：已知限制、环境差异或需要人工处置的风险。

`Verified` 不代表生产可用，也不能外推到其他镜像 digest、操作系统或部署方式。

## 文档索引

| 文档 | 用途 |
| --- | --- |
| [00_项目说明.md](00_项目说明.md) | 项目目标、范围、上游依赖和 V1 状态 |
| [01_架构设计.md](01_架构设计.md) | 分层架构、组件职责和系统边界 |
| [02_部署记录.md](02_部署记录.md) | 已验证环境、部署基线和运行配置差异 |
| [03_V1验证计划.md](03_V1验证计划.md) | V1 验证范围、完成项和后续验收项 |
| [04_二开规划.md](04_二开规划.md) | CF Gateway 与企业扩展路线 |
| [05_V1验证结果.md](05_V1验证结果.md) | 最新 V1 实测结果、能力边界和已知限制 |
| [validation.md](validation.md) | V1 验证矩阵和回归检查命令 |
| [api.md](api.md) | 已验证 REST/WebSocket 接口及初始化流程 |
| [troubleshooting.md](troubleshooting.md) | 已知故障、原因、处理和复核方式 |
| [operations.md](operations.md) | 日常运维、备份恢复、升级与交接清单 |
| [../docker/README.md](../docker/README.md) | Docker 部署操作手册 |

## 维护规则

1. 镜像升级必须记录 tag、digest、验证环境和回退基线。
2. 新能力只有完成实际测试后才能从 `Pending` 改为 `Verified`。
3. API 行为变化时同步更新 `api.md`、验证记录和调用方契约。
4. 部署逻辑与验证环境不一致时必须记录为 `Known Issue`，不能只记录成功结论。
5. 文档不得包含 auth-token、聊天内容、联系人数据、二维码或私有主机信息。

文档基线更新日期：2026-07-30。
