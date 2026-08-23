# Deployment Audit

本文记录 forced fresh QR 生产部署的设计审计。它是代码与文档契约，不是 CFserver
实机验收记录。

## 审计结论

生产生命周期采用：

```text
Bootstrap 只准备
  -> Agent/Worker 保持停止
  -> 人工 start-qr-login.sh
  -> 归档旧 runtime
  -> 全新 data/wechat-home
  -> 全新二维码
  -> auth/chats/messages
  -> Worker 放行
```

生产 Compose 必须为 `restart: "no"`。容器 crash、Docker daemon 重启、Host 重启、
recreate、升级和回滚均不得自动恢复旧微信 session。

## PR #2 选择性移植

PR #2 的 CI 曾通过，但其生产生命周期采用 `unless-stopped`、自动 session reuse 和
`logged_in` short-circuit。这些行为与批准的 forced fresh QR 模型冲突，因此不能整体
merge、rebase 或 cherry-pick。

| 分类 | 处理 |
| --- | --- |
| PORT | 路径、owner/mode、symlink/hardlink、rootful local Docker、Token、超时、错误脱敏、CI 和测试加固 |
| REDESIGN | Bootstrap、Compose lifecycle、`restart=no` Docker policy fixture、登录管理和恢复文档 |
| REJECT | `unless-stopped`、crash/daemon/host 自动恢复、旧 session reuse、`logged_in` 跳过扫码 |

选择性移植必须保留 forced-QR 基线的原子归档、新 runtime、Worker gating 和唯一生产入口。

## 控制矩阵

| 控制 | 生产要求 | 证据类型 |
| --- | --- | --- |
| Bootstrap | 只准备，不登录，不启动 Agent/Worker；真实 venv/ensurepip probe | Fake Docker、分阶段重试与依赖测试 |
| 管理环境 | 固定路径与 `docker/.env`；拒绝 API/WS/Token/Compose/Proxy/Runtime/Gateway 覆盖 | management environment 攻击测试 |
| Docker | 固定工具、真实 socket、本机 rootful/default endpoint、`live-restore=false`；每次扫码复核 systemd/unit | environment 与 lifecycle 测试 |
| Compose | clean environment；批准 image/project/container/port/mount/alias/env 与 `restart=no` 精确 attestation | 静态合同、真实 render、fake Docker inspect |
| Restart | crash/daemon/host 均不恢复 | Alpine/Nginx policy fixture 只覆盖 Docker policy；实际 Agent、QR 和 Host 待实机 |
| Runtime 权限 | 现有/legacy 与新 Runtime 精确匹配批准非 root UID/GID/mode，不继承漂移 | permissions 与 lifecycle |
| Runtime 树 | no-follow、no-cross-filesystem；拒绝 link/特殊文件，限制文件数/字节/时间；Token 不命中 | scanner unit/integration |
| Archive | 固定生产 storage/runtime/archive/Token 路径；原子归档；schema v2 restricted 分类；有 hard timeout 的 bytes/percent/inode、inventory、默认 dry-run retention | archive unit/lifecycle |
| 依赖 | GIL-enabled CPython 3.10-3.14、stamp schema v3、Pillow 12.3.0、Hash-locked binary-only requirements、clean pip、hard timeout；仅结构安全的漂移事务重建 | dependency integrity；Linux CI 不替代 CFserver |
| Proxy | 仅无凭证 `scheme://host:port`，无 userinfo/path/query/fragment/control | environment/Compose tests |
| 管理锁 | 批准 owner/management GID、`0640`、单 hardlink、非 symlink；非管理用户不可持锁 | permissions/concurrency |
| QR | 当前 TTY 显示可审计文本 fresh QR 后才接受成功；拒绝 PNG-only | QR unit/integration；真机待验证 |
| API | loopback 派生 endpoint；process/auth/chats/messages 全通过，调用有 hard timeout | lifecycle/API timeout |
| Token | 唯一 root-only 文件；Gateway 使用固定 file pointer 与只读 bind；不进 argv/env/inspect/config/archive/log/error/CI | security/contract/attestation tests |
| Worker contract | v1 精确文件与 Agent-side commit/producer repo/tracked blob/checker SHA-256 provenance；fresh QR 后 checker 验证实例/health/heartbeat/Poll/auth | consumer 机制已实现、pins 未发布；producer BLOCKED |
| 错误 | 超时、有界长度、去控制字符、外部错误脱敏 | unit/integration |
| 文档 | 两阶段流程、UTC/时区和 CI 证据边界一致 | link/UTF-8/lifecycle scan |

## Compose 与健康边界

正式 Compose 必须包含：

- digest-pinned image；
- `restart: "no"`；
- fresh runtime 的 data/wechat-home bind；
- root-only Token read-only bind；
- loopback 6174；
- 外部 `cf-internal` 和固定 alias `cf-agent-wechat`；
- healthcheck、日志轮转、`ENABLE_VNC=0`；
- 当前上游所需 `seccomp=unconfined` 和 `SYS_PTRACE`。

Healthcheck 只证明容器和 Agent API 健康，不能证明微信登录、chats/messages 或 Gateway
链路。上游权限必须随每次镜像升级持续安全审查。

Bootstrap 必须使用固定系统 Docker/systemctl/OpenSSL/timeout 工具并校验真实非符号链接
`/var/run/docker.sock`。每次生产扫码都重新验证 systemd/docker.service、本机
rootful/default endpoint、`live-restore=false`、Agent auto-start unit 和 Compose；
实际容器还必须精确满足批准 image/RestartPolicy/mount/port/alias。Docker、Compose 和
API 调用均受 hard timeout。forced production 只接受渲染前可检查 Token 的文本 QR；
PNG-only `qrDataUrl` 在输出前 fail closed。

## Gateway 边界

允许本仓库：

- 校验固定 Gateway Compose/env/project/profile/service 和 versioned contract；
- 在 fresh QR 前停止并确认 `worker` service（角色名 WeChat worker）；
- 完整验证后启动 `worker`，再按发布合同调用 checker。

Gateway contract v1 固定 producer repository、checker SHA-256、alias/port、Token
authority、Worker file credential、service/project、checker interface、30 秒 freshness
与全部 required flags。Compatible commit 只由 Agent 侧 pin 固定，不写入它自身跟踪的
contract blob。Contract/checker 必须是该 commit 中受跟踪的 blob；root-owned 手工文件
不构成发布来源证明。Rendered Compose 与实际 Worker inspect 还必须证明固定 file
pointer、唯一只读 bind 且没有 Token bytes。checker 由管理用户无参数执行，10 秒
内 stdout/stderr 为空，并同时确认当前实例、Docker health、heartbeat 新鲜、最新 Poll
Cycle 成功与 auth=`logged_in`。任一失败、stale、超时或输出都撤销 Worker 放行。本仓库
不得创建 fake checker、猜数据库或静默同步 Token。

截至 2026-08-24 审计的 Gateway PR #4 commit
`0c4f449fe42fdc28619ef64004de7be33d5a7508` 尚无兼容 contract/checker 或 file-based
credential；本仓消费者的 provenance/credential attestation 机制已经实现，但 compatible
commit 与 checker digest pins 尚未发布，所以生产路径主动 fail closed，结论为
**BLOCKED BY GATEWAY CONTRACT**。Gateway 当前 environment-based Token 即使与权威文件
常量时间一致，也仍会违反 Token 不进入 process environment/Docker inspect/Compose
config 的最终合同，不能被描述为生产兼容。详见
[Gateway-WeChat Runtime Contract v1](contracts/gateway-wechat-runtime-contract.md)。

禁止本仓库：

- 修改 Gateway 源码、配置数据库、PostgreSQL 或 Checkpoint；
- 启停 `dispatch-worker` 或 `delivery-worker` 作为 QR 步骤；
- 使用 SQL、`bootstrap_mode=latest` 或 localId 回退解决 Runtime 恢复；
- 修改其他仓库。

Gateway boot stop gate、Worker healthy/heartbeat 和真实重启窗口必须在 CFserver 实机
验证，不能由本仓库 CI 代替。

## 敏感信息

Token、二维码、微信账号、联系人、聊天 ID、消息正文、服务器地址、API Key 和密码不得
进入 Git、manifest、日志、错误、CI 输出或 artifact。Token 还不得进入 argv、process
environment、Docker inspect、Compose config、Runtime 或 Archive。

Archive payload 可能包含完整旧 session、账号/聊天标识、消息元数据和内容，整体为
`restricted`。Manifest schema v2 的 `manifestData` 只描述 manifest 自身不含实际值；
`archivePayloadClassification` 明确 payload 风险并禁止生产 session recovery。
生产 Archive root/top-level 精确为 root:root `0700`，manifest 为 root:root `0600`。
Archive 不自动上传/删除，retention 默认 dry-run；完整合同见
[Archive Management Contract](archive-management.md)。

归档以 root-protected `.incomplete-*` staging、parent/manifest/root fsync 和 atomic
rename 发布。任何 `.incomplete-*`、合法 UTC 目录中的 v2 `in_progress`、
缺失/malformed manifest 或临时残留都阻断 inventory 与下一次启动，不自动修复、改名、
删除、上传或复用 session。仅结构完整且 terminal 的 v1 可作为 restricted 历史证据。
Linux SIGTERM/SIGKILL/timeout fixture 不是掉电证明；真实 CFserver/VM fault-injection
仍待验证。

## 时间模型

- Host：`Asia/Shanghai`。
- Container：UTC。
- Logs：UTC。
- Archive manifest 与原始审计证据：UTC。
- 人工展示：可以转换为 `Asia/Shanghai`，必须标明时区。

## 仍需实机验证

- 真实 CFserver 上 Bootstrap fail-closed 和安全重试。
- 真实手机扫描当前 TTY 显示的全新二维码。
- WeChat process 稳定及 auth/chats/messages 完整验证。
- Gateway boot stop gate。
- `wechat-worker` running/healthy/heartbeat。
- 真实 Debian/Host restart 后 Agent 不自动恢复，且 Worker boot stop gate 持续有效。
- 真实 Archive 容量/inode、inventory、schema v2、精确 Runtime/锁权限和脱敏记录。
- CFserver/VM 掉电和存储故障注入下的 Archive 两阶段发布与 fsync durability。
- 实际 Agent 镜像的 container attestation、Proxy/Token 未进入 inspect、QR venv Hash 合同。
- 兼容 Gateway commit 的 file-based Token、producer/tracked-blob/digest provenance、
  versioned checker 与 failure/stale/timeout 撤销；环境副本一致性不能替代该项。

实机记录不得包含任何敏感值。当前验证状态见[验证总览](validation.md)。
