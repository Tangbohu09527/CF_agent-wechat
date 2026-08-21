# 验证总览

> [!WARNING]
> forced-QR 实现状态适用于 `feat/forced-qr-login@9cb7163` 及其后续合入版本；
> 本文审计的 `main` 代码基线 `96264e2` 不包含该实现。这里的“自动化验证”不是
> CFserver 实机验证，不得据此绕过代码能力门禁或宣称新生产流程已现场通过。

本页区分历史生产证据、本次自动化验证和仍待完成的 CFserver 实机验证。旧记录不能外推
为“强制全新二维码运行模式已经现场通过”。

## 状态定义

| 统一标签 | 本文使用方式 |
| --- | --- |
| **已完成** | 目标分支存在实现；必须同时注明是否已验证 |
| **已验证** | 明确区分自动化验证与带日期的 CFserver 实机验证 |
| **未验证** | 尚无目标环境现场证据，不从旧基线或自动化结果外推 |
| **后续规划** | 合入、现场验收、容量治理等尚未完成工作 |

- **已实现并自动化验证**：代码路径存在，并由不连接 CFserver、不使用真实微信账号的
  测试覆盖。
- **已实现但尚未实机验证**：实现和本地测试完成，但尚未在 CFserver 使用真实手机扫码
  完成闭环。
- **已实现并实机验证**：在带日期的 CFserver 记录中实际执行并观察到预期结果。
- **历史基线证据**：只证明当时版本和运行方式，不代表 forced-QR 目标流程已经验证。

## forced-QR 目标决策

forced-QR 目标基线不恢复旧微信登录会话。每次 Debian 重启、容器重建或人工重新启动微信入口，
唯一流程为：

```text
Debian 启动
  -> SSH
  -> ./scripts/start-qr-login.sh
  -> 手机扫码
  -> 自动验证
  -> Gateway wechat-worker 启动
```

旧 runtime 只归档，不恢复为活跃会话，也不自动删除。Gateway 和 Hermes 上下文仍由
各自数据库持久化。

本仓库未修改 Gateway，不能保证 Debian 启动至人工执行脚本前 `wechat-worker` 已停止；
该 boot/restart stop gate 必须在 CFserver 实机单独验证。

## 本次实现验证

| 范围 | 状态 | 验收结论 |
| --- | --- | --- |
| 生产 Compose | 已实现并自动化验证 | `restart: on-failure:3`，runtime 可轮换，Token 独立只读挂载 |
| 唯一启动入口 | 已实现并自动化验证 | `start-qr-login.sh` 编排归档、登录、验证和 worker 放行 |
| 停止入口 | 已实现并自动化验证 | `stop-qr-runtime.sh` 停止 worker 与容器，不删除数据 |
| 强制二维码 | 已实现并自动化验证 | `newAccount=true`，未实际渲染 QR 时拒绝成功 |
| 状态判定 | 已实现并自动化验证 | 进程、auth、chats 缺一不可，不输出账号 ID |
| 归档 | 已实现并自动化验证 | runtime 或 legacy 双目录进入一个 UTC 归档，mixed layout fail-fast |
| 有界就绪等待 | 已实现并自动化验证 | 登录后按 `POST_LOGIN_READY_TIMEOUT` 等待 auth/chats/messages |
| 失败隔离 | 已实现并自动化验证 | agent 轮换后的失败尝试停止 worker 并 stop/remove agent；结果单独确认 |
| Gateway boot stop gate | 尚待 CFserver 实机验证 | 本仓未修改 Gateway，不能保证脚本运行前的开机窗口 |
| 完全新设备 SSH 扫码 | 已实现但尚未实机验证 | 仍需 CFserver 真实手机扫码闭环 |

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
11. `login.sh --force-qr` 使用 `newAccount=true`。
12. `status.sh` 不把假 `logged_in` 判定为成功。
13. `stop-qr-runtime.sh` 不删除 runtime、Token 或归档。
14. 日志和输出不含 Token、账号、聊天 ID、二维码或消息正文。
15. 首次上线把 legacy 来源中实际存在的 `${STORAGE_ROOT}/data`、`wechat-home` 迁入同一个归档。
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

### 静态质量检查

变更完成时执行并记录：

- Bash 语法检查；
- ShellCheck（若环境可用）；
- 所有新增脚本测试；
- `git diff --check`；
- Compose `config --quiet` 静态验证；
- Markdown 链接和围栏检查；
- UTF-8 检查；
- 敏感信息扫描；
- 修改范围检查，确认未修改其他仓库。

自动化和静态检查通过仍不能替代真实二维码、真实 WeChat 进程和真实 API 的现场证据。

## CFserver 实机验证清单

本任务完成后仍需在 CFserver 执行以下脱敏验证：

### 启动前

- [ ] 确认当前 Commit 和批准的镜像 digest。
- [ ] 确认 `wechat-worker` 可由脚本停止和启动。
- [ ] 实机检查 Gateway restart policy、Compose/systemd 启动方式，并通过 Debian
  重启确认 worker 从开机到人工执行脚本前持续停止。
- [ ] 确认 secrets/Token 只检查元数据，不读取内容。
- [ ] 运行 `./scripts/start-qr-login.sh --dry-run`，确认没有状态变化。

### 全新二维码登录

- [ ] 运行 `./scripts/start-qr-login.sh`。
- [ ] 确认旧容器停止并删除，但未执行 Compose `down`。
- [ ] 确认旧 runtime 移入新的 UTC 时间戳归档且未覆盖历史归档。
- [ ] 首次迁移场景确认 legacy 来源中实际存在的 `data`、`wechat-home` 进入同一个时间戳归档。
- [ ] mixed 新旧布局场景确认在停止 worker/容器或移动目录前 fail-fast。
- [ ] 确认 manifest 只有时间、权限和脱敏结果，不含敏感内容。
- [ ] 确认新 data 和 wechat-home 的 UID、GID、权限正确。
- [ ] 确认 agent-server 可访问。
- [ ] 确认 launcher 的 canonical executable 精确匹配，且同一 `PID:start_time`
  身份稳定。
- [ ] 确认 SSH 终端实际渲染至少一个全新 QR，并用手机扫码；仅成功事件不算证据。
- [ ] 确认登录后 API 在 `POST_LOGIN_READY_TIMEOUT` 有界窗口内就绪。
- [ ] 确认 auth 为 `logged_in`。
- [ ] 确认 chats API 可读且至少返回一个聊天，但不记录聊天 ID。
- [ ] 确认对 API 返回的一个聊天读取 messages 成功，但不记录正文。
- [ ] 确认上述条件全部通过后 `wechat-worker` 才启动。
- [ ] 运行 `./scripts/status.sh`，确认七个状态项且输出无账号 ID。

### 生命周期

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

## 历史生产证据

### 2026-08-13 部署与登录基线

Commit `fe3c963` 的记录验证了当时的正式 Compose、无 VNC 桌面链路、agent-server、
已信任设备手机确认、90 秒稳定性和 Gateway 网络访问。

该记录中的“已登录短路”和旧持久化会话恢复不属于 forced-QR 目标流程。它不能证明
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

> 强制全新二维码运行模式已实现并完成本地自动化验证；真实扫码和 Gateway boot stop
> gate 仍待 CFserver 实机验证。

不得表述为“新的唯一生产启动流程已完成实机验证”。

## 后续规划

1. 将 forced-QR 实现合入经批准的生产代码基线；当前文档警示在合入前必须保留。
2. 在 CFserver 完成真实扫码、legacy 迁移、mixed layout、失败 cleanup 和 worker 放行验证。
3. 通过 Debian 实机重启验证人工脚本前的 worker boot/restart stop gate。
4. 建立归档容量监控，并由数据和安全责任人批准保存期限与到期处置流程。
5. 现场证据评审通过后新增带日期记录，再更新“未验证”状态；不得回填旧验证记录。

## 回归要求

以下变化必须建立新的带日期、脱敏验证记录：

1. 镜像 digest、Compose 或容器启动策略变化。
2. runtime 路径、原子归档、权限继承或 manifest 变化。
3. Token 独立挂载或权限变化。
4. `login.sh --force-qr`、`newAccount=true` 或二维码事件变化。
5. WeChat 进程、auth、chats、messages 判定变化。
6. Gateway `wechat-worker` 停止、放行或失败隔离变化。
7. Debian 重启、升级、重建或回滚。
8. 归档保留策略或访问控制变化。
9. Gateway restart policy、systemd/Compose boot gate 或 Debian 开机顺序变化。

本项目脚本不自动删除历史归档。归档期限和到期处置由外部审批策略负责。
