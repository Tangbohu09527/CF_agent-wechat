# 当前生产状态

> [!IMPORTANT]
> 状态核对日期：2026-10-11。本页汇总已知事实、历史证据与未验证状态，不是实时监控。
> `production online` 只指 2026-09-03 的历史验收。详细操作只见
> [CFserver 生产 Runbook](deployment/cfserver-production.md)。

## Status

| 字段 | 已知事实及证据范围 |
| --- | --- |
| Production runtime status | **重启后未复验**；不能声明今天在线或 Gate 已关闭 |
| Last historical closeout | 2026-09-03：`production online`，保留历史成功 |
| 2026-10-11 CFserver reboot | 用户报告：Gateway d9 新 plan 通过后已执行；本任务未连接服务器，容器/登录/API/Poll 与 Delivery Gate 均未复验 |
| Current forced-QR decision | 每次 CFserver/Agent 重启、容器重建或人工重新启动均使用 fresh Runtime 和新二维码 |
| Repository branch authority | `main` |
| Repository promotion | **COMPLETED**；2026-09-04 |
| PR #1 promotion merge baseline | `MERGED`；`02583fe76220916019ca961bb37dfa015640384e` |
| PR #4 merge commit | `MERGED`；`92f3f062da564053678cbdd8d2830c82cab0f3fb` |
| PR #5 merge commit | `MERGED`；`ed7d50c414c8b146345bbf188be66a1265c4a560` |
| Promotion baseline CI | Run `33853255941` **SUCCESS**；五项 Job 全部通过 |
| 2026-10-11 远端 main 快照 | `81d21f451adc61df71077ca3035adeddeca4621f`；后续状态须重新查询远端 |
| PR #7 | **MERGED**，2026-09-06；merge 为上述 main SHA，head 为 `67cbbb04ce15703428ce165ac38effac19f4b701` |
| 未合并媒体候选 | `codex/fix-wechat-original-media` @ `9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a`；不属于已核对 main |
| 本次文档分支 / PR base | `codex/docs-wechat-status-20261011` / `codex/fix-wechat-original-media`；从固定候选 SHA 创建，仅改 Markdown |
| R2 repository source of truth | `main` branch |
| Historical production image ID | 2026-09-03 观察值：`sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720`；不是 2026-10-11 现场查询 |
| 制品来源与部署对应关系 | 2026-09-28 锁文件已补历史公开制品的 provenance；今天运行镜像、实际文件及本仓管理脚本 Release Commit 的部署对应关系未复验 |
| 本次生产操作 | **未执行**；本次只核对仓库与文档，不连接服务器、升级镜像、扫码、读聊天/凭据、重派 pending 或调用模型 |
| Production Tag | 未创建，也不得仅因本次 repository promotion 创建 |

Repository promotion 路径：

```text
PR #5 production Closeout docs
  -> PR #4 Runtime/CI hardening       Merge Commit ed7d50c...
       -> PR #1 forced-QR R2          Merge Commit 92f3f06...
            -> main promotion baseline 02583fe...
```

2026-09-03 的生产行为验收早于 2026-09-04 的 repository promotion。仓库合并没有重新
部署 PR #1 promotion merge baseline `02583fe...`。上表 Image ID 只保留当日观察值，
不得写成今天仍保持不变。PR #7 后续合并只证明代码进入 main，不证明现场安装。

## 能力、来源和待验收矩阵

| 能力/阶段 | 已有来源与结果 | 仍需验收的边界 |
| --- | --- | --- |
| forced fresh QR、Runtime/Archive、Token、Contract v1 | main 已有；[2026-09-03 记录](validation/2026-09-03-forced-qr-r2-production.md)有真实生产成功 | 2026-10-11 reboot 后容器、进程、登录、API 与 Gate；automatic boot stop gate 未证明 |
| Controller 授权预检查、服务 UID/GID/MODE、分阶段安装 | [PR #7](https://github.com/Tangbohu09527/CF_agent-wechat/pull/7)已合并；[A/B/C 记录](validation/2026-09-06-controller-precheck-clean-deploy.md)区分自动化与干净 Debian 容器准备 | booted 主机/systemd/reboot、真实 Gateway/PostgreSQL 全栈和扫码/Hermes C 项未由这些 CI 证明 |
| 私聊/群聊文本收发 | 2026-09-03 集成链路成功 | reboot 后真实收发未复验；Gateway plan 通过不等于微信链路通过 |
| 附件消息和元数据 | [媒体候选记录](validation/2026-09-28-media-retrieval-candidate.md)引用 Gateway Issue #13：PDF/图片已入站并分别派发 | 消息入站、文件名、声明长度/摘要不等于已取得字节 |
| 文件下载触发与缓存读取 | 历史固定上游 GET 只查缓存；候选加入 native 下载调度，隔离校验已建立 | native 提交、拒绝、落盘与 GET 返回须分别记录；`pending` 不等于正在下载 |
| PDF/Office/普通文件完整字节 | 历史 PDF 两次间隔约 10 分钟均 HTTP 200、pending、无 data/url；失败保留 | 候选真实登录取件未通过；需解码字节、长度及 SHA-256 与发送前文件核对 |
| 图片展示/原图 | 2026-08-14 曾得到 JPEG；后续样本与源文件大小/摘要不同，不能称原图 | 分别确认 full/standard/thumbnail、请求与返回层级、转码及发送前逐字节一致性；best 可降级 |
| 文件理解/分类、正式存储、Gateway 队列 | 属于下游组件，本仓负责微信通道与上游适配 | 内容解析、分类、入库和实际交付各自验收，不能用 HTTP 200 或取件成功替代 |

### 固定上游制品

完整来源以 [锁文件](../upstream/media-retrieval.lock.json)为准。下表是锁定制品身份，
不表示“当前最新”或“生产现用”；锁文件未被生产 Compose/安装入口读取。

| 对象 | 固定上游源码 | 不可变制品（OCI index） | 证据范围 |
| --- | --- | --- | --- |
| 历史制品 | `3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616` | `sha256:31a4e351c191bcbfc75e5c10be51e207d22a3eedd97f3ff56ad579fcce717b24` | 锁文件 historical、公开 provenance/config；不代表今天运行实例 |
| `0.15.1` 媒体候选 | `96c2e90c497d999bf5189a134a9b3b293731f42e` | `sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43` | 仅 linux/amd64 静态制品、helper 与隔离测试；未证明已登录微信 native 取件 |

本仓 Git SHA 标识管理脚本/文档，上游源码 SHA 标识 agent-wechat 构建输入，OCI index、
amd64 manifest 和 config/Image ID 是不同对象，不互相替代。隔离 fixture 的完整缓存字节
成功不能证明真实微信下载、PDF 理解或原图与发送前文件一致。

### CI 核对快照（2026-10-11）

以下为 GitHub 只读查询的既有 run，均 attempt 1；本次没有重跑功能测试。每项结论
只适用于所列 SHA 和运行范围，不将历史 CI 写成今天现场在线，也不使用笼统“全绿”。

| 对象 / SHA | GitHub Actions run | 已核对结论 |
| --- | --- | --- |
| main `81d21f451adc61df71077ca3035adeddeca4621f` | [forced-QR 34020705968](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34020705968)、[clean-host 34020705965](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34020705965) | push，均 completed/success |
| PR #7 head `67cbbb04ce15703428ce165ac38effac19f4b701` | [forced-QR push 34018788844](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018788844)、[PR 34018790269](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018790269)；[clean-host push 34018788784](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018788784)、[PR 34018790091](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018790091) | 四项 completed/success；PR 的 API head_sha 不等于实际 merge checkout |
| 媒体候选 `9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a` | [forced-QR 36403240630](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36403240630)、[clean-host 36403240644](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36403240644)、[media 36403240631](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36403240631) | 三项 push completed/success；media job `108865816205` 仅隔离制品/helper/合成缓存检查 |
| 历史上游 `3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616` | [Release 23874698754](https://github.com/thisnick/agent-wechat/actions/runs/23874698754) | push completed/success，与锁文件 historical builder 对应 |
| 候选上游 `96c2e90c497d999bf5189a134a9b3b293731f42e` | [Release 36276886277](https://github.com/thisnick/agent-wechat/actions/runs/36276886277) | push completed/success，与锁文件 candidate builder 对应 |

PR run `34018790269` 的日志实际 checkout 为合成 merge
`a75362bac86a68d3111e55b8f1aa0767e1db67af`（head `67cbbb04…` into base
`69f07702b6ee16d8e9700b3a53d5ebbb8ee875f8`），不是最终 main merge `81d21f4…`。
候选分支本次未找到对应 PR；另有 Railway suite `98565956151` 查询时为
`queued` / conclusion null，不将它算作通过，也不将其解释成微信服务运行中。

历史失败/取消保留：[run 34018072888](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018072888)
（`7caf040c4ab7c47e9a916f3a68df8a0778824c64`）整轮 failure，单项真权限 job 成功不能
覆盖它；[clean-host 36402990852](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36402990852)
（`b7c01ec30e389b361440f413090c4fe6b3b899bb`）为 cancelled，不计通过。
这些均不能与历史 PDF pending、图片摘要不一致的现场失败互相抵消。

## Production deployment

以下为仓库部署契约与历史配置记录，2026-10-11 未读取现场配置。

| 项目 | 契约/历史记录 |
| --- | --- |
| 项目根 | `/opt/cf-agent-wechat` |
| Compose | `/opt/cf-agent-wechat/docker/compose.cfserver.yaml` |
| 环境文件 | `/opt/cf-agent-wechat/docker/.env` |
| Compose project | `cf-agent-wechat` |
| service | `agent-wechat` |
| container | `cf-agent-wechat` |
| restart policy | `restart: "no"` |
| Agent API | container port `6174`；Host 仅 `127.0.0.1` |
| Docker network | external `cf-internal`；alias `cf-agent-wechat` |
| VNC | `ENABLE_VNC=0`；无 x11vnc、websockify、noVNC 或 Host X11 依赖 |
| security | `seccomp=unconfined`、`SYS_PTRACE`，为当前上游镜像要求 |
| stop grace | `30s` |
| agent-wechat logging | `json-file`，`20m × 3` |

Gateway 的 `64m × 10` 日志策略属于另一个项目，不是 `agent-wechat` 的日志配置。
正式 `docker/.env` 必须使用不可变 `AGENT_WECHAT_IMAGE` digest；本文不猜测现场上游
镜像 digest。

## Storage and Token

| 用途 | 路径 |
| --- | --- |
| storage root | `/srv/storage/cf-agent-wechat` |
| active Runtime | `/srv/storage/cf-agent-wechat/runtime` |
| Runtime data | `/srv/storage/cf-agent-wechat/runtime/data` |
| WeChat HOME | `/srv/storage/cf-agent-wechat/runtime/wechat-home` |
| Archive | `/srv/storage/cf-agent-wechat/session-archive/<UTC timestamp>` |
| Token | `/srv/storage/cf-agent-wechat/secrets/auth-token` |

2026-09-03 Token 历史验收为：普通文件、非 symlink、hard-link count `1`、owner `10001:10001`、
mode `0600`、恰好 64 个小写十六进制字符、无尾随 LF；父目录为 `root:root 0700`；
容器内只读挂载到 `/data/auth-token`。Token 不在 `.env`、Runtime、Archive、manifest、
日志、命令或状态输出中。Token 的 `10001:10001` 仍是脚本契约，与服务 UID 分开。
PR #7 已将 Runtime 服务 UID/GID/MODE 放入受保护配置，
安装时须按批准镜像核对，不能把历史 `10001:10001` 当作所有版本的服务身份。
2026-09-06 干净设备记录对其固定旧镜像实际核对为 `1000:1000`；今天现场元数据未复验。

Archive 由旧 Runtime 原子移动产生，不覆盖、不自动删除，也不恢复为 active Session。
manifest 只保存脱敏生命周期和清理结果；payload 可能包含 Session、账号/Chat 标识、
消息 metadata、cache 与数据库内容，因此属于受限敏感资产。

## Lifecycle status

- Bootstrap：普通管理用户运行 `./scripts/bootstrap-cfserver.sh`，按提示授权 sudo；
  只检查和准备部署输入，不创建或恢复
  Session，不启动 Agent，不显示二维码，不启动 Gateway Worker，也不宣称入口在线。
- Fresh QR：`./scripts/start-qr-login.sh`，是唯一生产启动入口。
- Stop：`./scripts/stop-qr-runtime.sh`，停止 Poll/Delivery Worker 和 Agent，保留 Runtime、
  Token 与 Archive。
- Status：`./scripts/status.sh`，只读检查 11 个状态项；完整通过只证明当次入口就绪，
  不包含媒体原件或下游业务验收。本次文档任务没有执行现场 status。
- Compatibility：`./scripts/login.sh` 只转入 `start-qr-login.sh`。

## Production acceptance

2026-09-03 Closeout 汇总：

- 多次在真实 SSH TTY 显示 fresh QR，并由手机扫码确认。
- `cf-agent-wechat` running，Docker health healthy，Agent Server reachable。
- `/usr/bin/wechat` 真实进程存在且同一 `PID:start_time` 身份稳定。
- Auth 为 `logged_in`，chats 可读且非空，并成功读取其中一个聊天的 messages。
- Gateway Runtime `ready=true`、`token_contract_valid=true`、Poll/Delivery 均 healthy。
- 私聊与群聊的 inbound/outbound 集成链路成功，未观察到重复回复。
- Gateway-only 受控切换期间 agent-wechat Session 保持。
- Token 未进入 Archive；状态输出未暴露账号或 Chat ID。

详细一次性证据见
[2026-09-03 forced-QR R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md)。

## Reboot and deployment boundaries

### CFserver reboot

2026-10-11 用户报告在 Gateway d9 新 plan 通过后执行了 CFserver reboot。该信息的
来源是本次用户说明，不是服务器检查；微信容器是否停止、登录、API 及 Poll/Delivery
Gate 均未复验，不能从 `restart: "no"` 推定本次现场结果，也不能从 plan 推定收发 Gate。

2026-09-01 真实重启中，Docker、存储及 Gateway/PostgreSQL 核心服务恢复；
`cf-agent-wechat` 因 `restart: "no"` 保持停止，旧 Session 未自动恢复。Gateway
Poll/Delivery Worker 当时被观察为 running/healthy，Operator 随后显式关闭 Gate，
运行 fresh QR，最终状态全部通过。

因此 automatic Gateway boot stop gate **未被证明**。Host reboot 后必须先通过正式
Controller 执行并确认 `stop`，再运行 `start-qr-login.sh`；不能只依赖启动脚本稍后
执行 stop。

### AI/Hermes host reboot

只要 CFserver 和 `cf-agent-wechat` 未重启，微信 Session 保持，不需要 fresh QR。
Hermes 连通性恢复属于 Gateway/Hermes 边界；本仓库只确认 agent-wechat 是否仍在线。

### Gateway-only deployment

若没有重启或删除 `cf-agent-wechat`，微信 Session 可以保持，且已在多次受控切换中
观察到。该结论不能外推为 Agent 容器重启后可复用 Session。

## Gateway Runtime Contract

- 通用依赖：Runtime Contract version 1。
- Controller：`/opt/cf-agent-gateway/deploy/wechat-runtime-control`。
- `contract` 动态验证服务名和 Token container path；`stop/start/status` 是受控 Worker
  的唯一生命周期入口。
- R2 实机验收时验证的 Controller implementation commit：
  `e6a8645ff3a97830dc19c5bf57390f94a4840457`。
- 一次性环境快照：Gateway `main`
  `b488cf452584e73bc9b752564bf90ea153aa8d18`；production-validated code
  `f36c798294368263433f6132366ac9a864d9482b`。

这些 SHA 只用于 2026-09-03 历史环境记录。通用 Runbook 以 Contract version 与 Controller
输出为准，不固定旧分支、旧 PR 或旧 SHA。本仓库不拥有 Controller，也不负责 Gateway
的 Message、Admission、Checkpoint、Dispatch、Response 或 Delivery 数据模型。

2026-09-06 的 Gateway 配套缺口针对固定 `4f13039b86c60bc94340edb5468f0102d62d2dff`；
2026-10-11 只读核对 Gateway main `7963bc0db5a01e38099e021959feabf648db7ede` 已有正式
安装、配置/构建、PostgreSQL 准备和 external `cf-internal` 资产。新版 core unit 的
Controller stop 不能证明 Docker 启动调度窗口内 Worker 从未运行，亦未证明本次现场
boot stop gate。不能将旧版缺口写成永久当前状态，固定文件来源与边界见
[Gateway 版本审计](deployment/gateway-clean-install-gaps.md)。用户报告的 d9 新 plan
通过不能替代 WeChat 入站 PDF/原图验收，也不能证明本仓已部署媒体候选。

## Known limitations

1. CFserver reboot 后必须人工 fresh QR。
2. `agent-wechat` 为 `restart: "no"`，不自动恢复 Session。
3. Gateway automatic boot stop gate 未证明；必须显式关闭并确认 Gate。
4. 离线/重启窗口内消息可能无法由本地微信客户端补拉。
5. Archive 不得自动恢复为 active Session。
6. 上游 `agent-wechat` 不是本仓库实现，API/schema 可能变化。
7. `seccomp=unconfined` 与 `SYS_PTRACE` 是持续风险项。
8. 6174 不是公网 API；VNC/noVNC 不在生产链路。
9. 本仓库不保证 Gateway、Hermes、数据库或业务自动化恢复。
10. 公开上游制品 provenance 已有锁定证据；2026-10-11 现场身份与管理脚本部署对应关系未复验。
11. PR #1 promotion merge baseline `02583fe...` 未被证明已经重新部署到生产。
12. Archive 保留、容量、备份与安全销毁由外部运维策略决定。

## Remaining repository work

1. 建立选定 Release Commit、构建输入和未来不可变生产镜像之间的可证明映射。
2. 若未来部署选定 Release Commit，建立 immutable image、fresh QR、回滚和验收证据。
3. 在 Gateway 所属项目核对/补齐 automatic boot stop gate，并完成独立实机复验；本仓不承诺它已关闭。
4. 建立 Archive 保留与销毁策略。
5. 在上游 API/schema 升级后重新验证。
6. 持续审查 `seccomp=unconfined` / `SYS_PTRACE` 风险。
7. 另行验收 reboot 后微信状态、固定媒体候选的已登录 native 下载、PDF 字节完整性和图片质量/转码/一致性；保留历史失败，不重派 pending。
