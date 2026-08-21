# Deployment Audit

本文记录 CF_agent-wechat V1 Beta 生产部署加固的审计结论。权威操作入口仍是
[Deployment Guide](deployment-guide.md)、[Recovery Guide](recovery-guide.md)、
[QR Login Guide](qr-login-guide.md) 和 [Troubleshooting](troubleshooting.md)。

## 审计范围

审计覆盖生产 Compose、bootstrap、宿主管理脚本、runtime 与 Token、微信 session、
fresh QR 登录、自动化测试和部署文档。历史实验 Compose、Gateway 内部实现、备份平台和
微信上游客户端本身不在本仓自动控制范围内。

## 主要结论

| 范围 | 原风险 | 加固结果 | 验证入口 |
| --- | --- | --- | --- |
| 生产入口 | 历史 Compose 与手工变量可造成不同部署结果 | 固定生产 Compose、env、项目名、服务名和网络；拒绝危险覆盖 | deployment suite、Compose JSON validator |
| 新机初始化 | 目录、网络、Token、Compose 和启动需要分散人工操作 | bootstrap 一次执行检查 Docker/Compose、创建或校验 runtime、启动并验证服务 | `tests/deployment/bootstrap_cfserver.sh` |
| 配置权威 | stale shell 变量或 source env 可切换端口、容器或持久根 | 安全解析固定 `docker/.env`；显式值必须一致；不执行文件内容 | `tests/integration/management_environment.sh` |
| runtime 恢复 | 空路径、部分恢复或新 Token 可掩盖数据丢失 | `data`、`wechat-home`、原 Token 和权限设置按同一单元校验，部分状态 fail closed | deployment suite |
| 容器恢复 | 进程退出或主机重启后需要人工发现和启动 | `restart: unless-stopped`，检查 Docker 开机恢复状态并提供有界状态等待 | deployment suite、session recovery |
| session 恢复 | 每次重启都扫码会破坏可恢复会话 | `logged_in` 直接复用；只有明确需要登录才进入 QR | session recovery |
| fresh QR | 旧 QR、无 QR success、窄终端或非 TTY 可误报 | 只接受本次 `newAccount=true` WebSocket 实际渲染的新 QR，并复核最终 auth | QR unit tests |
| Token 边界 | 不安全文件、控制字符或远端 API 可泄露 Token | 固定 owner/mode/type/长度/单行门禁，管理 API 仅允许权威 loopback | management and permission suites |
| 容器权限 | 微信镜像需要扩大 seccomp/capability | 风险显式记录；镜像必须 digest-pinned，禁止增加敏感宿主挂载 | Compose validator、现场审核 |

完整自动化与现场证据边界见 [验证总览](validation.md)。

## 仍需人工或外部系统完成

- 安装并维护 Debian、Docker Engine 和 Docker Compose v2；bootstrap 负责验证，不静默安装。
- 检出批准 Commit，提供并审批固定到 digest 的 `agent-wechat` 镜像。
- 保证容器仓库以及首次登录所需的批准 Python 包源可达，或预置已验证的离线登录 venv。
- 在交互式终端使用真实手机扫描 fresh QR；该动作不能自动化。
- 配置外部一致备份、加密、访问控制、保留期和恢复审批。
- 在目标主机执行 Docker daemon 重启、Debian 重启和真实微信 session 的现场验收。
- 由 Gateway 责任域验证调用方接入 `cf-internal`；本仓不启动或修改 Gateway。

## 恢复边界

以下情况可由脚本检测并引导恢复：容器进程退出、Docker/主机重启、API 启动延迟、有效
session 复用，以及 session 失效后的 fresh QR 登录。

以下情况不能由脚本凭空修复：原 Token 丢失、`data` 或 `wechat-home` 损坏、三者来自
不同备份时点、权威 `docker/.env` 丢失且配置无法确认、持久盘损坏，以及没有一致备份。
这些场景必须停止写入并按 Recovery Guide 从完整受控备份恢复，不能生成新 Token、创建空
runtime 或删除数据库来绕过门禁。
