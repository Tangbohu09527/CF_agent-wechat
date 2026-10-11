# Deployment Guide

本文只做部署导航。所有可执行生产命令以
[CFserver 生产 Runbook](deployment/cfserver-production.md)为准。

2026-10-11 证据边界：2026-09-03 的 `production online` 是历史验收；用户报告在
Gateway d9 新 plan 通过后执行了 CFserver reboot，之后的微信容器、登录、API 和
收发 Gate 未复验。本文是操作指南，不是实时在线声明，也不授权本轮执行部署。

## Five distinct actions

| 动作 | 入口 | 负责什么 | 不负责什么 |
| --- | --- | --- | --- |
| Bootstrap | `./scripts/bootstrap-cfserver.sh`（普通管理用户，脚本内授权 sudo） | 主机、Docker、目录、Token、网络、Compose、Gateway Contract 前置准备 | 不创建 Session，不启动 Agent/Worker，不显示 QR |
| Fresh QR start | `./scripts/start-qr-login.sh` | 关闭 Gate、轮换 Runtime、显示 QR、验证 Agent/API、放行 Worker | 不恢复 Archive，不绕过 Controller |
| Stop | `./scripts/stop-qr-runtime.sh` | 停止 Poll/Delivery Worker 和 Agent | 不删除 Runtime、Token 或 Archive |
| Status | `./scripts/status.sh` | 只读输出 11 个状态项并给出退出码 | 不修改任何运行状态 |
| Recovery | 场景化执行 Runbook | 判断 Host/Agent/Gateway/Hermes 哪一层变化 | 不把 `logged_in` 或 Docker health 单独当成功 |

`Bootstrap != fresh QR start != status != stop != recovery`

## First deployment

干净设备从 [Debian 13 安装入口](deployment/clean-device.md) 开始；PR #7 已合并，
其 A/B/C 执行范围见 [2026-09-06 记录](validation/2026-09-06-controller-precheck-clean-deploy.md)。
Gateway 旧版本缺口和后续正式安装资产见 [版本对照](deployment/gateway-clean-install-gaps.md)，
不要将旧审计版本的缺口写成所有版本的现状。

~~~text
准备受控 docker/.env 与不可变镜像 digest
  -> Bootstrap
  -> 交互式 SSH TTY 执行 fresh QR start
  -> status 全部通过
~~~

Bootstrap 成功只表示部署输入已准备，不能写成“生产入口在线”。

## Existing deployment change

~~~text
stop under old approved inputs
  -> change approved code/config/image inputs
  -> Bootstrap
  -> fresh QR start
  -> status
~~~

不要在 Agent 在线时直接替换 Compose、环境文件或镜像后执行裸 `docker compose up`。

## Restart boundaries

- **CFserver/Agent restart**：必须 fresh QR；Host reboot 后先显式关闭并确认 Gateway
  Gate。Automatic boot stop gate 尚未证明。
- **Gateway-only deployment**：只要未重启或删除 `cf-agent-wechat`，Session 可以保持；
  先检查本仓库状态，不要主动轮换 Agent。
- **AI/Hermes host restart**：CFserver 与 Agent 未重启时无需 fresh QR；下游连通性由
  Gateway/Hermes 运维恢复。

## Production invariants

- `restart: "no"`
- Agent port 6174 仅 Host loopback
- external `cf-internal` 与 alias `cf-agent-wechat`
- `ENABLE_VNC=0`
- Token 独立只读挂载，不在 `.env`、Runtime 或 Archive
- Archive 只保留，不恢复为 active Session
- Gateway Runtime Contract version 1
- Agent 日志 `json-file`，`20m × 3`

日期化证据与待验收项目见 [生产状态](production-status.md)，Operator 扫码步骤见
[QR Login Guide](qr-login-guide.md)。

`main@81d21f4…` 的生命周期/安装能力与未合并媒体候选分开记录。固定上游制品见
[来源锁](../upstream/media-retrieval.lock.json)，取件边界见
[2026-09-28 媒体候选](validation/2026-09-28-media-retrieval-candidate.md)：候选和隔离
测试不能证明现场已升级或真实微信取件通过。Gateway plan 通过也不代替入站 PDF、
图片层级、转码及发送前文件逐字节一致的验收。
