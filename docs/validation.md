# 验证总览

本页区分历史生产证据、本次自动化验证和仍待完成的 CFserver 实机验证。旧记录不能外推
为“强制全新二维码运行模式已经现场通过”。

## 状态定义

- **已实现并自动化验证**：代码路径存在，并由不连接 CFserver、不使用真实微信账号的
  测试覆盖。
- **已实现但尚未实机验证**：实现和本地测试完成，但尚未在 CFserver 使用真实手机扫码
  完成闭环。
- **已实现并实机验证**：在带日期的 CFserver 记录中实际执行并观察到预期结果。
- **历史基线证据**：只证明当时版本和运行方式，不代表当前生产流程已经验证。

## 当前产品决策

生产环境不再恢复旧微信登录会话。每次 Debian 重启、容器重建或人工重新启动微信入口，
唯一流程为：

```text
Debian 启动
  -> agent-wechat 保持停止
  -> wechat-worker 由 Gateway boot stop gate 保持停止
  -> SSH
  -> 首次部署，或受控停止后的配置变化，Bootstrap（只准备，不登录、不启动）
  -> ./scripts/start-qr-login.sh
  -> 固定管理环境 + Host/Compose/Gateway/权限/树扫描重新核验
  -> 停止 Gateway worker
  -> Archive 容量/inode/inventory + Hash 锁定 QR venv
  -> 归档旧 runtime，按批准权限创建全新 data/wechat-home
  -> 精确 attest restart=no 实际容器
  -> 显示全新二维码
  -> 手机扫码
  -> auth/chats/messages 自动验证
  -> Gateway wechat-worker 启动
```

旧 runtime 只归档，不恢复为活跃会话，也不自动删除。Gateway 和 Hermes 上下文仍由
各自数据库持久化。生产 Compose 必须为 `restart: "no"`，Docker daemon 必须为
`live-restore=false`；容器 crash、Docker daemon 重启和 Debian 重启均不得自动恢复
`agent-wechat`。

本仓库未修改 Gateway，不能保证 Debian 启动至人工执行脚本前 `wechat-worker` 已停止；
该 boot/restart stop gate 必须在 CFserver 实机单独验证。

## 本次实现验证

| 范围 | 状态 | 验收结论 |
| --- | --- | --- |
| 生产 Compose | 已实现并自动化验证 | `restart: "no"`，runtime 可轮换，Token 独立只读挂载 |
| Docker Host | 已实现并自动化验证 | 固定系统工具、真实 socket、本机 rootful/default endpoint、`live-restore=false` |
| Bootstrap | 已实现并纳入自动化门禁 | 只准备部署；真实 venv/ensurepip probe；不创建 session 或启动 Agent/Worker |
| 管理环境隔离 | 已实现并纳入自动化门禁 | 拒绝 API/WS/Token/Compose/Proxy/Runtime/Gateway 覆盖；Compose 使用 clean environment |
| Compose 精确身份 | 已实现并纳入自动化门禁 | 批准 image/project/container/port/mount/alias/env 与 `restart=no` 精确 attestation |
| Runtime 权限/树 | 已实现并纳入自动化门禁 | 精确非 root UID/GID/mode；no-follow/no-cross-filesystem 有界扫描 |
| QR Python 依赖 | 已实现并纳入自动化门禁，待 CFserver 实机验证 | GIL-enabled CPython 3.10-3.14、stamp schema v3、Pillow 12.3.0、Hash-locked binary-only requirements、hard timeout；只自动重建结构安全的漂移 venv |
| Gateway contract consumer | 机制已实现，pins/producer 阻断 | v1 file credential、Compose/inspect attestation 与 Agent-side commit/tracked blob/checker SHA-256 证明已实现；兼容 pins 未发布，Gateway PR #4 尚不兼容 |
| 唯一启动入口 | 已实现并自动化验证 | `start-qr-login.sh` 编排 preflight、归档、登录、验证和 worker 放行 |
| 停止入口 | 已实现并自动化验证 | `stop-qr-runtime.sh` 停止 worker 与容器，不删除数据 |
| 强制二维码 | 已实现并自动化验证 | `newAccount=true`；未渲染 QR 或收到 PNG-only `qrDataUrl` 时拒绝成功 |
| 状态判定 | 已实现并自动化验证 | 进程、auth、chats 缺一不可，不输出账号 ID |
| Archive | 已实现并纳入自动化门禁 | 原子归档、schema v2 restricted 分类、容量/inode、inventory、默认 dry-run retention |
| 有界就绪等待 | 已实现并自动化验证 | 登录后按 `POST_LOGIN_READY_TIMEOUT` 等待 auth/chats/messages |
| 失败隔离 | 已实现并自动化验证 | agent 轮换后的失败尝试停止 worker 并 stop/remove agent；结果单独确认 |
| `restart=no` Docker policy fixture | 已实现并纳入自动化门禁 | Alpine/Nginx fixture 在真实 Docker daemon 上验证正常/异常退出及 daemon restart 后不自动恢复；不代表实际 Agent、WeChat、QR 或 Host reboot |
| Gateway boot stop gate | 尚待 CFserver 实机验证 | 本仓未修改 Gateway，不能保证脚本运行前的开机窗口 |
| 完全新设备 SSH 扫码 | 已实现但尚未实机验证 | 仍需 CFserver 真实手机扫码闭环 |

Compose healthcheck 只证明容器和 Agent API 健康，不证明微信登录、chats/messages
可读、Gateway 链路或 Worker heartbeat。

依赖单元测试可证明 lock/parser/GIL/rebuild 分支和不安全树原位保留；Linux CI 可证明目标平台上的 venv/pip
执行。两者都不证明 CFserver 已使用实际系统 Python、网络边界和已部署 venv 完成登录。
`restart=no Docker policy fixture` 的 Alpine/Nginx 容器同样只证明 Docker policy，
Workflow 名称或绿色结果不得表述为实际 Agent Runtime E2E。

### 自动化场景

测试不连接真实 CFserver，不要求真实微信账号，也不读取数据库内容。至少覆盖：

1. start/stop 的 `--dry-run` 不修改目录、容器或 worker，也不创建
   `/run/lock/cf-agent-wechat-qr-runtime.lock`。
2. 当前 runtime 被原子归档。
3. 新 `runtime/data` 和 `runtime/wechat-home` 权限正确。
4. Token 不进入 runtime、归档或 manifest。
5. agent-server、WeChat、登录、chats/messages 或 worker 启动失败时执行统一
   cleanup；成功场景确认 worker stopped、agent absent，注入失败场景确认结果被记录。
6. `/usr/bin/wechat` 为符号链接时解析 canonical executable；目标进程缺失，或同名
   进程、命令行含 `wechat` 但 executable 不匹配时启动失败。
7. auth 为 `logged_in` 但 chats API 不可读时启动失败。
8. chats 非空且 messages API 正常时才启动 worker。
9. 重复执行创建不同归档，不覆盖历史目录。
10. 并发执行只有一个流程获得锁。
11. `start-qr-login.sh` 自身使用 `newAccount=true` 请求和监听 fresh QR；
    `login.sh` 兼容包装无条件进入同一生命周期，不能短路。
12. `status.sh` 不把假 `logged_in` 判定为成功。
13. `stop-qr-runtime.sh` 不删除 runtime、Token 或归档。
14. 日志和输出不含 Token、账号、聊天 ID、二维码或消息正文。
15. 首次上线把 legacy `${STORAGE_ROOT}/data` 与 `wechat-home` 迁入同一个归档。
16. runtime 与任一 legacy 目录并存时，在任何状态变更前 fail-fast。
17. forced login 未在 SSH 实际渲染至少一个 QR 时拒绝 `login_success`。
18. 登录后 auth/chats/messages 在有界窗口内轮询，并跟踪同一 `PID:start_time`；
    超时、`PID:start_time` 身份变化或 canonical executable 不再匹配时失败。
19. start/stop 共用指定 `flock`；并发只有一个流程获得锁。
20. 失败 cleanup 不主动删除已有 runtime、归档、其中已落盘的持久文件或 volume；
    failed manifest 更新成功时记录 stop/remove 结果，cleanup 错误不覆盖原失败阶段。
21. 模拟 Docker daemon 重启时，remove 成功的失败流程没有残留 agent 容器可恢复；
    remove 失败场景保留 stopped 容器并明确要求人工处置；成功流程仍保留运行中容器。
22. 普通 Docker 与 ordinary-user sudo Docker fallback 都执行相同的 stop/remove
    cleanup，且输出、trace、audit、runtime 和归档不泄露 fixture 敏感值。
23. 生产 Compose 静态契约和 render 精确为 `restart: "no"`；`restart=no Docker
    policy fixture` 使用 Alpine/Nginx 容器在真实 Docker daemon 上覆盖正常退出、
    异常退出和 daemon restart 后不自动恢复。该 fixture 不运行实际 agent-wechat
    镜像、WeChat 进程或 QR，也不等同于真实 Host reboot。
24. 已有 `logged_in` 不能让生产启动短路；未显示二维码前的成功事件无效。
25. WebSocket connect/recv/early-close、invalid JSON、non-UTF8、timeout 和外部错误
    均 fail closed，错误中不含 Token 或控制字符。
26. Bootstrap 分阶段失败可重试，且任何阶段都不创建或复用微信 session。
27. Bootstrap 固定系统 Docker/systemctl/OpenSSL/timeout 工具并校验真实非符号链接
    socket；default endpoint、本机 rootful daemon、`live-restore=false` 和
    Docker/Compose/API hard timeout 均 fail closed。
28. 固定 heartbeat checker 由管理用户从 digest-bound sealed snapshot 在 hard
    timeout 内执行，禁止 `sudo` 和按原路径二次执行；stdout/stderr 经匿名有界管道
    检测，任意输出都拒绝且不落盘、不打印。
29. PNG-only `qrDataUrl` 在任何二维码输出前 fail closed。
30. 恶意 `API_URL=https://attacker.example`、`WS_URL=wss://attacker.example` 和其他生产
    管理覆盖在任何网络请求前拒绝；Token 不进入 shell trace、错误或 Docker argv。
31. 宿主恶意 image/project/container/PROXY/RUST_LOG 不能覆盖 `docker/.env`；渲染和
    actual container 都精确匹配批准合同。
32. Gateway Token 相同才继续；mismatch、contract/checker 缺失/不兼容、stale、失败、
    timeout 或 checker 输出都会停止/撤销 Worker。
33. Runtime/legacy 仅批准 `1000:1000/700`（或已批准非 root 值）；root owner、755、
    group/other writable、symlink/hardlink 拒绝，新目录精确创建。
34. Archive bytes/percent/inode 充足/不足、inventory、schema v2、路径逃逸、symlink 和
    retention dry-run/当前 Runtime 保护均覆盖。
35. PROXY userinfo、query、fragment、path、控制字符拒绝，无凭证 host:port 通过。
36. GIL-enabled CPython 3.10-3.14 的 schema v3 依赖合同固定 Pillow 12.3.0，并覆盖
    free-threaded/Python venv/ensurepip 拒绝、pip hard timeout、Hash mismatch、正确 venv
    快速复用、结构安全的错误 venv 事务重建，以及结构不安全的 venv 原位保留；安装只接受
    Hash-locked binary wheels。
37. Runtime scanner 覆盖树外 symlink/loop、FIFO/socket/device、大文件/timeout、二进制
    数据库、Token hit/miss，不跟随链接或跨文件系统。
38. 管理锁精确 owner/management GID/0640/单 link，普通非管理用户不能持锁。
39. Bootstrap 后 systemd unit、Compose restart、实际 RestartPolicy 或 image 漂移会在
    QR 前 fail closed，并清理本次不合规容器。

### 静态质量检查

变更完成时执行并记录：

- Bash 语法检查；
- ShellCheck；
- 所有新增脚本测试；
- `git diff --check`；
- Compose `config --quiet` 静态验证；
- Markdown 链接和围栏检查；
- UTF-8 检查；
- Secret 与控制字符扫描；
- repository hygiene、Markdown link/fence 和 UTF-8；
- `git log --check`；
- 修改范围检查，确认未修改其他仓库。

自动化和静态检查通过仍不能替代真实二维码、真实 WeChat 进程和真实 API 的现场证据。

## CFserver 实机验证清单

本任务完成后仍需在 CFserver 执行以下脱敏验证：

### 启动前

- [ ] 确认当前 Commit 和批准的镜像 digest。
- [ ] 首次部署时运行 `sudo ./scripts/bootstrap-cfserver.sh`；已运行环境的输入变化时，
  先用 `stop-qr-runtime.sh` 确认 Agent/Worker 均已停止。确认 Bootstrap 只完成基础准备，
  Agent 和 Worker 均未由 Bootstrap 启动。
- [ ] 确认生产 Compose render 为 `restart: "no"`，6174 仅 loopback，
  `cf-internal` 固定 alias 为 `cf-agent-wechat`。
- [ ] 确认 Bootstrap 使用固定系统 Docker/systemctl/OpenSSL/timeout 工具并校验真实
  非符号链接 `/var/run/docker.sock`；生产启动重新校验 default endpoint、本机
  rootful daemon、`live-restore=false` 和各类 hard timeout。
- [ ] 确认生产管理 shell 无 API/WS、Token/session、Agent/Compose/Proxy、Python、
  Runtime/Archive 或 Gateway 覆盖；恶意远端 URL 在网络请求前被拒绝。
- [ ] 确认 Gateway `worker` 可由脚本停止和启动。
- [ ] 兼容 Gateway commit 已部署 contract v1/checker，producer repository、完整 commit、
  tracked blob 和 checker SHA-256 均自动证明；checker 10 秒内无输出并覆盖
  instance/health/heartbeat/Poll/auth。消费者机制已实现，但 compatible commit/digest
  pins 未发布且 PR #4 未兼容，因此本项现为 **BLOCKED BY GATEWAY CONTRACT**。
- [ ] 确认 Gateway 使用固定 file pointer 与 host-authority 到 Worker path 的唯一只读
  bind；rendered Compose/实际 inspect 无 Token bytes。明文副本即使常量时间相同也不能
  通过本项。
- [ ] 确认 GIL-enabled CPython 3.10-3.14、stamp schema v3、Pillow 12.3.0 的 QR venv
  Hash contract、安全重建边界、无凭证 PROXY 和 Runtime scanner 上限。
- [ ] 实机检查 Gateway restart policy、Compose/systemd 启动方式，并通过 Debian
  重启确认 worker 从开机到人工执行脚本前持续停止。
- [ ] 确认 secrets/Token 只检查元数据，不读取内容。
- [ ] 运行 `./scripts/start-qr-login.sh --dry-run`，确认没有状态变化。

### 全新二维码登录

- [ ] 运行 `./scripts/start-qr-login.sh`。
- [ ] 确认旧容器停止并删除，但未执行 Compose `down`。
- [ ] 确认 Worker 已先停止，再确认 bytes/percent/inode 门禁和脱敏 inventory 通过；
  门禁失败时 Worker 保持停止，Archive/QR 不变更。
- [ ] 确认旧 Runtime 移入新的 UTC Archive 且未覆盖历史 Archive。
- [ ] 首次迁移场景确认 legacy `data` 与 `wechat-home` 进入同一个时间戳归档。
- [ ] mixed 新旧布局场景确认在停止 worker/容器或移动目录前 fail-fast。
- [ ] 确认 manifest schema v2 的 `manifestData` 不含实际标识，payload classification
  如实标记可能含 session、账号/聊天标识和消息数据；schema v1 按 restricted 处理。
- [ ] 确认 Token 未进入 Archive；Archive root/顶层目录 root-protected，不挂回生产。
- [ ] 确认 retention 默认 dry-run，实际删除需明确 Archive、TTY 二次确认和审计。
- [ ] 确认现有/legacy 与新 data/wechat-home 精确符合批准非 root UID/GID/mode，
  不继承 root:root 或 755 等漂移权限。
- [ ] 确认实际容器 RestartPolicy/image/name/project/mount/loopback/alias/env 精确合规。
- [ ] 确认 agent-server 可访问。
- [ ] 确认 launcher 的 canonical executable 精确匹配，且同一 `PID:start_time`
  身份稳定。
- [ ] 确认 SSH 终端实际渲染至少一个全新 QR，并用手机扫码；仅成功事件不算证据。
- [ ] 确认二维码来自可在渲染前检查 Token 的文本 payload；PNG-only `qrDataUrl`
  必须在输出二维码前 fail closed。
- [ ] 确认登录后 API 在 `POST_LOGIN_READY_TIMEOUT` 有界窗口内就绪。
- [ ] 确认 auth 为 `logged_in`。
- [ ] 确认 chats API 可读且至少返回一个聊天，但不记录聊天 ID。
- [ ] 确认对 API 返回的一个聊天读取 messages 成功，但不记录正文。
- [ ] 确认上述条件全部通过后 `wechat-worker` 才启动。
- [ ] 确认 `wechat-worker` running/healthy，并检查 Gateway 提供的 heartbeat 证据。
- [ ] 运行 `./scripts/status.sh`，确认七个状态项且输出无账号 ID。

### 生命周期

- [ ] Agent 进程 crash 后不会自动重启。
- [ ] Docker daemon 重启后 Agent 不会自动恢复。
- [ ] Debian 重启后 `agent-wechat` 没有自动复用旧会话，且 Gateway boot stop gate
  让 `wechat-worker` 在人工脚本前持续停止；随后重新扫码成功。
- [ ] 容器重建后使用全新 runtime 并重新扫码成功。
- [ ] 人工停止后再次启动需要全新二维码。
- [ ] `stop-qr-runtime.sh` 停止 worker 与容器，但不删除任何数据。
- [ ] 至少验证一个失败场景，确认 cleanup 不主动删除已有 runtime、归档或其中已落盘
  的持久文件；不要把 Docker json-file 容器日志误写为脚本已归档。
- [ ] 检查 failed manifest 的 `failureCleanup`，确认 stop/remove 结果与现场一致；
  cleanup 自身失败时仍保留原失败阶段。
- [ ] 仅在 worker stop 与 agent remove 都已确认成功后，验证 Docker daemon 重启不会
  恢复失败容器；任一步失败时先人工处置，不得直接重启 Docker 或 Debian。

### 业务窗口

- [ ] 通知业务方：重启期间发送的消息可能不会被微信本地客户端补拉。
- [ ] 只在完整登录验证和 worker 启动后发送新的业务测试消息。

现场记录不得包含 Token 或指纹、二维码、微信账号、联系人、聊天 ID、聊天正文、媒体、
服务器地址、API Key、密码或数据库内容。
Host 时间按 `Asia/Shanghai` 展示；容器、日志、archive manifest 和原始证据使用 UTC。
同时记录时必须明确时区，不得混写。

## 历史生产证据

### 2026-08-13 部署与登录基线

Commit `fe3c963` 的记录验证了当时的正式 Compose、无 VNC 桌面链路、agent-server、
已信任设备手机确认、90 秒稳定性和 Gateway 网络访问。

该记录中的“已登录短路”和旧持久化会话恢复不再是当前生产流程。它不能证明
`newAccount=true`、全新 runtime、归档、完整消息验证或 worker 闸门。

详细记录：[2026-08-13 CFserver 生产验证](validation/2026-08-13-cfserver-production.md)。

### 2026-08-14 消息与媒体基线

历史记录验证了当时版本上的私聊/群聊文本发送、群消息字段、引用结构、图片 media 读取
和自消息字段。图片发送和文件发送仍不能由这些证据外推为已验证。

详细记录：[2026-08-14 消息与媒体生产验证](validation/2026-08-14-message-media-production.md)。

这些接口证据说明能力曾在旧基线工作，但不证明重启后本地微信一定补拉停机期间消息，也
不证明本次新 runtime 已现场验证。

## 可使用的当前表述

在 CFserver 新实机记录完成前，只能表述为：

> 强制全新二维码消费者侧加固已实现并纳入自动化门禁，仍需 CFserver 真实扫码；
> Gateway PR #4 尚未提供兼容 contract/checker，因此当前为
> **BLOCKED BY GATEWAY CONTRACT**。Bootstrap 只表示基础准备完成。

不得表述为“新的唯一生产启动流程已完成实机验证”。

## 回归要求

以下变化必须建立新的带日期、脱敏验证记录：

1. 镜像 digest、Compose 或容器启动策略变化。
2. Runtime 路径、原子归档、精确权限、树扫描、容量门禁或 manifest schema 变化。
3. Token 独立挂载、Gateway agreement、argv/env/inspect/config 边界或权限变化。
4. `start-qr-login.sh` 的 `newAccount=true` 请求、二维码监听或事件变化。
5. WeChat 进程、auth、chats、messages 判定变化。
6. Gateway `wechat-worker` 停止、放行或失败隔离变化。
7. Debian 重启、升级、重建或回滚。
8. Archive 分类、容量/inode、inventory、retention、备份或访问控制变化。
9. Gateway restart policy、systemd/Compose boot gate 或 Debian 开机顺序变化。
10. `seccomp=unconfined` 或 `SYS_PTRACE` 的必要性变化；两者是当前上游镜像要求，
    必须持续安全审查。

本项目不自动删除历史 Archive。到期处置使用默认 dry-run 的独立工具；实际删除仍须外部
审批、明确 Archive、TTY 二次确认和受保护审计记录。
