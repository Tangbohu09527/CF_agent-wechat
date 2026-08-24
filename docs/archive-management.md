# Archive Management Contract

本文是 forced fresh QR 生产归档的权威合同。Archive 用于受控审计、故障分析和经批准
的受限备份，不是微信 session recovery 介质，也不得挂回当前 `runtime/data` 或
`runtime/wechat-home`。

## 资产分类

生产 Archive 工具不接受调用环境或普通配置重定向以下四个路径；它们必须精确为：

```text
storage       /srv/storage/cf-agent-wechat
runtime       /srv/storage/cf-agent-wechat/runtime
archive       /srv/storage/cf-agent-wechat/session-archive
Agent Token   /srv/storage/cf-agent-wechat/secrets/auth-token
```

生产中归档根必须精确为 root:root `0700`，每个 UTC 时间戳顶层目录必须精确为
root:root `0700`，其中 `manifest.json` 必须为 root:root `0600`。这些路径必须是单一
目录/普通文件身份，不得是 symlink 或额外 hardlink；payload 子树保留原始权限作为审计
证据，但始终受顶层 `0700` 保护。Retention 审计记录必须保持 root:root `0600`。
生产顶层目录名只接受 `YYYYMMDDTHHMMSSZ` 或冲突后缀 `YYYYMMDDTHHMMSSZ-NN`。
归档 payload 可能包含完整历史微信 session、缓存、账号标识、聊天标识、消息元数据和
消息内容，因此整个 Archive 都是 `restricted` 敏感资产。不得自动上传、公开分享、加入
Git/CI artifact，或复制到普通用户目录。独立 Agent API Token
`/srv/storage/cf-agent-wechat/secrets/auth-token` 不属于 runtime，严禁进入任何 Archive。

## Manifest Schema v2

Runtime 顶层的 `manifest.json` 是归档工具保留的 metadata 名，不属于允许迁移的旧
payload。若旧 runtime 已存在该名字，移动前的有界扫描必须在创建目标 Archive 之前
fail closed；工具不得覆盖旧 payload，也不得把旧文件误当作 schema v2 manifest。

归档移动执行完整 no-follow/no-cross-filesystem 树扫描，记录每个 entry 的
device/inode/type/link-count/owner/mode/size/ctime；普通文件内容和每个目录项名称的原始
文件系统字节都检查当前独立 Agent Token，任何 xattr（包括 POSIX ACL）一律拒绝。
rename 前重验精确 entry 集合与身份，并验证受保护 parent、同一文件系统和目标不存在。
移动只使用 dirfd-relative rename，随后对目标重做身份复核。任一竞态、metadata 或复核
失败都 fail closed 并尝试原路回滚，不退化为复制、跟随 symlink 或覆盖目标；该控制
不能替代 trusted deployment principal 边界，也不表示 payload 已去标识化。

归档使用两阶段发布事务。工具先创建 root-protected
`.incomplete-<UTC-name>-<pid>` staging，将旧 payload 移入后 fsync 来源与目标 parent，
再复扫 Token；随后以“临时文件 fsync -> atomic replace -> staging 目录 fsync”的顺序写入
schema v2 `in_progress` manifest，最后把 staging rename 为合法 UTC 名并 fsync Archive
root。只有发布完成后才能创建 fresh Runtime。

顶层 `.incomplete-*` 表示发布前事务被中断；合法 UTC 目录中仍为 `in_progress` 的
schema v2 manifest 表示发布后事务尚未终结。两者都会让 inventory 返回非零并阻断下一次
生产启动。工具不会自动修复、改名、删除、上传这些现场，也不会复用其中 session；管理员
必须把它们作为 restricted 故障证据隔离调查。

上述 fsync 顺序缩小了持久化中断窗口，但不等于已经证明真实掉电行为。Linux
SIGTERM/SIGKILL/timeout fixture 只验证进程中断路径；CFserver 或 VM 的真实掉电/存储
故障注入仍是部署前待验证项。

新归档的 `manifest.json` 使用 `schemaVersion: 2`。`manifestData` 只描述 manifest
文件自身，不描述整个 archive payload：

```json
{
  "manifestData": {
    "tokenIncluded": false,
    "accountIdentifiersIncluded": false,
    "chatIdentifiersIncluded": false,
    "messageContentIncluded": false
  },
  "archivePayloadClassification": {
    "mayContainWechatSession": true,
    "mayContainAccountIdentifiers": true,
    "mayContainChatIdentifiers": true,
    "mayContainMessageMetadata": true,
    "mayContainMessageContent": true,
    "containsIndependentAgentApiToken": false,
    "independentAgentApiTokenScan": "verified",
    "accessClassification": "restricted",
    "productionSessionRecoveryAllowed": false
  }
}
```

`manifestData` 中的 `false` 只表示 manifest 没有写入对应实际值，不能解释为 Archive
payload 不含这些数据。`containsIndependentAgentApiToken` 仅在 payload 已原子移入
root-protected Archive、且隔离后的有界扫描通过时为 `false`，同时扫描状态为
`verified`；仅完成移动前预扫或扫描失败时该字段为 `null`，状态分别保留为
`preflight_passed` 或 `failed`，流程 fail closed。Manifest 还记录原目录 owner/mode、
UTC 时间、来源路径、批准的镜像 digest、归档结果和失败 cleanup 分类；它不得记录
Token、Hash、指纹、实际账号、Chat ID 或消息正文。

Schema v1 兼容仅适用于结构完整的 JSON object：`schemaVersion: 1`、terminal
`result` 为 `success` 或 `failed`、`archiveResult: succeeded`，且
`endedAtUtc` 非空。它只作为 restricted 历史证据保留；不得因旧字段缺失推断数据
不存在，不得原地改写，也不得用旧 Archive 恢复生产 session。

缺失 manifest、malformed/non-object JSON、unsupported schema、manifest 临时残留，
以及 schema v2 `in_progress` 或非 terminal 结果都不是 v1 compatibility；inventory
和生产启动必须 fail closed。

Schema v2 也不表示 payload 已去标识化。只有 `manifestData` 四个字段描述 manifest 自身；
payload 仍按可能包含 session、账号/聊天标识、消息元数据和消息内容的最高限制级别处理。

## 启动前容量门禁

`start-qr-login.sh` 获得管理锁后先停止并确认 Gateway `worker` service，再在修改
Archive 之前使用固定系统 `df` 分别检查 block 与 inode。两次 `df` 都在固定
`/usr/bin/timeout` 的 hard timeout 内执行，先有界捕获输出再解析；任何一次失败或超时都
fail closed。以下三个阈值必须同时满足：

| `docker/.env` 键 | 生产含义 | 默认合同 |
| --- | --- | --- |
| `CF_AGENT_WECHAT_MIN_FREE_BYTES` | 最少可用字节 | `1073741824` |
| `CF_AGENT_WECHAT_MIN_FREE_PERCENT` | 最少可用百分比 | `10` |
| `CF_AGENT_WECHAT_MIN_FREE_INODES` | 最少可用 inode | `1024` |

无法读取容量、probe 路径为 symlink、可用字节/百分比/inode 任一低于阈值时，流程在归档
和二维码之前 fail closed。它不会自动删除 Archive 来腾出空间，也不会启动 Agent；
Worker 已停止并保持停止。阈值只能通过受保护且经过 Bootstrap 校验的 `docker/.env`
管理，不能使用调用进程环境临时覆盖。

## Inventory

生产启动会在容量门禁后自动运行一次受限 inventory。运维也可以只读执行：

```bash
cd /opt/cf-agent-wechat
sudo python3 scripts/archive-runtime.py inventory
sudo python3 scripts/archive-runtime.py inventory --json
```

Inventory 输出 Archive 数量、总 apparent bytes、普通文件数量、最老/最新 UTC 时间，
以及每个时间戳 Archive 的大小摘要。不合规顶层名使 inventory 返回非零，只输出脱敏
数量而不回显原名。它不输出 payload 文件名、payload 路径、文件内容、Token、账号、
Chat ID、消息正文、device 或 inode。扫描有 entry-count 与扫描时间上限；它还读取
当前 mount namespace 的 `/proc/self/mountinfo`，拒绝 Archive 根内任何子挂载，包括
同一文件系统 bind mount。遇到路径逃逸、symlink、额外 hardlink、特殊文件、跨文件系统
内容、子挂载或扫描失败时返回非零。

CLI hard timeout 从受保护 `docker/.env` 的 nonblocking/no-follow 读取开始，覆盖合同解析、
inventory 和 retention 验证/删除；环境文件在打开前、打开后和读取后必须保持同一
device/inode/size/ctime 身份。删除已经写入 `started` 后失败时，`failed` 审计使用新的短
recovery deadline，原 operation deadline 已耗尽也不能使审计永久阻塞。隐藏的
`--testing-env-file` 仅在显式 `CF_AGENT_WECHAT_TESTING=1` 下用于只读 inventory，不能
用于 retention，也不能改变生产四路径合同。

Inventory、容量门禁和 Token 扫描都只是本机 fail-closed 控制，不授权自动上传、同步、
恢复或删除任何 Archive。

## Retention

Retention 永远默认 dry-run，并且必须明确指定 Archive 的直接子目录名：

```bash
sudo python3 scripts/archive-runtime.py retention \
  --archive 20300101T000000Z
```

上述命令只输出计划，不删除，也不写删除审计。实际删除属于破坏性、需另行审批的操作，
必须同时满足：

1. 明确指定一个 inventory 中存在的 UTC Archive 名；
2. 增加 `--execute --confirm DELETE:<archive-name>`；
3. 在受控 TTY 再次逐字输入同一确认短语；
4. 成功获取与 fresh QR 相同的 root-protected 管理锁；
5. 再次通过路径 containment、identity、权限、symlink/hardlink、特殊文件和跨文件系统
   检查；在第一个 unlink 前再次读取 mountinfo 并拒绝任何 Archive 子挂载。

示例：

```bash
sudo python3 scripts/archive-runtime.py retention \
  --archive 20300101T000000Z \
  --execute \
  --confirm DELETE:20300101T000000Z
```

工具绝不按年龄、数量或磁盘压力自动选取 Archive，绝不触碰当前 runtime、legacy
目录、Token 或未知路径。实际请求以 `0600` JSONL 记录 `started`、`completed` 或
`failed` 审计事件；审计记录不包含 payload 内容或 Secret。不得配置 cron/systemd
定时执行破坏性 retention。

## 受限备份

Archive 备份必须由数据所有者和安全负责人批准，并满足：

- 目标是访问受控、加密、具有保存期限和访问审计的受限存储；
- 只复制完整 Archive 与 manifest，不把 payload 解包到普通目录；
- 不自动上传到 GitHub Actions、公共对象存储、聊天、工单或普通日志；
- 不把独立 Agent API Token 合并进备份；
- 恢复演练只允许隔离、离线的审计或故障分析，不得挂载到生产 Agent；
- 到期处置继续使用明确 Archive、审批、TTY 二次确认和审计记录。

备份成功不改变生产恢复模型。任何 crash、daemon/Host restart、recreate、升级或回滚
之后，都必须创建全新 runtime、显示 fresh QR、完成 auth/chats/messages 验证，再放行
Gateway `worker` service。
