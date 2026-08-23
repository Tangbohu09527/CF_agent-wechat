# Gateway-WeChat Runtime Contract v1

本文固定 CF_agent-wechat 与 CF_agent-gateway 之间的生产运行契约。它只定义跨仓可观察
接口，不授权本仓库读取 Gateway 数据库、猜测 checkpoint 结构，或修改 Gateway 源码和
PostgreSQL。

> [!CAUTION]
> **BLOCKED BY GATEWAY CONTRACT**
>
> 截至 2026-08-24，只读审计的 Gateway PR #4 head
> 0c4f449fe42fdc28619ef64004de7be33d5a7508 尚未提供本契约要求的版本化 contract
> 文件和可部署 checker。该 commit 不兼容 contract v1。PR #3 可以完成本仓库内的
> fail-closed 消费者实现，但在 Gateway 发布兼容 commit 并完成联调前，不得宣称长期
> 生产目标完成。消费者侧 provenance 证明机制已经实现，但 compatible commit 与
> checker digest pin 尚未发布，当前固定值为空并主动 fail closed。手工放置内容匹配的
> root-owned JSON/checker 不能解除该阻断。

## 契约身份

| 字段 | 固定值 |
| --- | --- |
| Contract version | "1" |
| Checker interface version | 1 |
| Agent consumer | Tangbohu09527/CF_agent-wechat PR #3 |
| Gateway producer | Tangbohu09527/CF_agent-gateway PR #4 |
| 已审计 Gateway commit | 0c4f449fe42fdc28619ef64004de7be33d5a7508，不兼容 |
| 首个兼容 Gateway commit | 尚未发布；必须在 PR #4 中提供后记录 |
| Checker SHA-256 | 尚未发布；必须固定为兼容 commit 中被跟踪 checker 的 64 位小写十六进制摘要 |
| Agent network alias | cf-agent-wechat |
| Agent API port | 6174，仅在 cf-internal 网络内使用 |
| Gateway Compose project | cf-agent-gateway |
| Gateway service | worker |
| Heartbeat freshness | 最后有效 heartbeat 不超过 30 秒 |
| Checker hard timeout | 每次调用 10 秒 |
| 成功/失败 | 所有条件通过返回 0；任意失败或超时返回非零 |

Contract version 或任一固定字段不匹配时，消费者必须 fail closed。兼容性由精确契约
匹配确定，不能用“字段大致存在”或 PR 编号代替。

## 部署路径

生产默认路径固定如下：

| 资产 | 路径 |
| --- | --- |
| Gateway project | /opt/cf-agent-gateway |
| Gateway Compose | /opt/cf-agent-gateway/docker-compose.prod.yml |
| Gateway environment | /opt/cf-agent-gateway/.env |
| Versioned contract | /opt/cf-agent-gateway/deploy/wechat-runtime-contract.json |
| Versioned checker | /opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat |
| Agent Token authority | /srv/storage/cf-agent-wechat/secrets/auth-token |

Contract 和 checker 必须是 Gateway 仓库兼容 commit 中受版本控制的两个 blob，并由
该 commit 部署，不能是仅在文档中出现或在主机上手工创建的文件。仅满足 root owner、
mode 和内容字段不足以证明来源。它们必须是 root:root、单 hardlink、非 symlink 的普通
文件；contract mode 为 0644，checker mode 为 0755。checker 必须可由受控管理用户直接
读取和执行，不得通过 sudo 执行。消费者不得在来源验证后再次按该路径直接执行；每次
health probe 都必须重新取得稳定的 no-follow 内容快照、精确匹配批准 SHA-256，再执行
只读密封快照。

## Token 合同

Agent Token 的唯一权威来源是：

    /srv/storage/cf-agent-wechat/secrets/auth-token
    owner=root:root
    mode=0600

该文件必须是单 hardlink、非 symlink 的普通文件，并以只读方式挂载到 Agent。Token
不得进入 argv、进程环境、Docker inspect、Compose config、日志、异常、归档或 CI。

Gateway v1 的生产兼容接口只接受 file-based credential：

    CF_AGENT_WECHAT_TOKEN_FILE=/run/secrets/cf-agent-wechat-auth-token

Gateway Compose 必须把 host 权威文件
`/srv/storage/cf-agent-wechat/secrets/auth-token` 单次、只读 bind 到上述固定 Worker
路径。受限 Gateway `.env` 必须恰有一个无引号的 file-pointer 赋值且不得出现
`CF_AGENT_WECHAT_TOKEN`。

消费者从有界 stdin 解析 rendered Compose JSON，精确验证 project、service、file
pointer 和唯一只读 bind，并确认原始 JSON 不含 Token bytes。Worker 启动后通过
`--attestation-kind worker-inspect` 对实际 `docker inspect` JSON 重做检查，同时验证
Compose project/service labels。缺失、重复、可写 mount、路径漂移、明文 key 或 Token
bytes 均 fail closed。

该 bind 是整个 Gateway Compose 的唯一 Token mount allowlist：只有批准的 Worker service
可以把精确 host Token 文件单次只读挂载到精确 worker path。任何额外 service，或同一
service 通过 Token host path 的父目录、规范化后等价父目录、symlink 等价路径或其他
ancestor mount 间接暴露 Token，均必须 fail closed。
消费者必须枚举 rendered Compose 的全部 services；其他 service 只要 bind 精确 Token
文件、Token host path 的任一 ancestor 或其规范化/symlink 等价路径，就必须 fail closed。
批准的 Worker service 也不得有任何额外 mount，其规范化 container target 等于
`/run/secrets/cf-agent-wechat-auth-token`，或成为该路径的容器内父路径；等价路径同样拒绝。
Contract v1 禁止所有 service 使用 `volumes_from`，因为继承 Worker volumes 会把 Token
mount 复制到未批准容器。Top-level Compose `secrets`/`configs` 的 `file` 以及 named
volume `driver_opts.device` 也不得指向精确 Token host path、其任一 ancestor 或
规范化/symlink 等价路径；这些间接挂载机制与直接 bind 使用同一 fail-closed allowlist。
消费者还必须检查全部 service 的 `secrets`/`configs` target、`tmpfs` 字符串或
target/source 结构，以及 `devices` 的 container target。任一 target 等于固定 Worker
Token path、作为其父目录或规范化后等价时均 fail closed；普通 sibling secret 不受影响。
实际 Worker inspect 必须对 `HostConfig.Tmpfs` keys、`HostConfig.Devices[].PathInContainer`
执行同一门禁，不能只检查 `Mounts`。
root:root 0600 的 host bind 会保留 host inode 权限，因此“挂载存在”不等于实际
Worker 身份可读。首个 compatible pin 必须附带 producer Linux 集成证据：按发布
Compose 的真实 Worker 身份和完整 security settings 启动容器，证明它能从上述唯一只读
authority mount 读取凭据并完成受鉴权 Agent 请求。不得为通过测试而放宽 host owner、
mode 或 ACL，不得把 Worker 常驻身份提升为 root，不得把 Token 复制到环境、argv、
Compose、image layer、Docker inspect、日志或另一个持久文件。fake Worker、仅 root
执行的 probe 或只检查 mount metadata 都不能满足
`workerReadabilityProof=producer-linux-integration`；缺少该证据时继续
**BLOCKED BY GATEWAY CONTRACT**。



Gateway 当前只支持 `CF_AGENT_WECHAT_TOKEN` 的版本会把 Secret 暴露给 process
environment、Docker inspect 或 Compose config，不能标记为 v1 compatible。

独立 legacy migration audit 可以安全读取受限 `.env` 中唯一的明文赋值，并与权威文件
做常量时间比较，但它与 production verifier 分离：

1. 相同只返回 `MATCH_INCOMPATIBLE`。
2. 不同只返回 `MISMATCH_INCOMPATIBLE`。
3. 两个结果的 `production_compatible` 都固定为 false，不能放行 Agent 或 Worker。
4. parser 不 source/eval，不输出任一 Token、Hash、指纹或长度。
5. 本仓库不创建、改写或静默同步 Gateway environment。

Gateway 发布 file-based credential 后必须删除环境副本和容器环境注入；在此之前 PR #3
保持 **BLOCKED BY GATEWAY CONTRACT**。

## 发布来源证明

兼容发布必须同时固定以下三项，不允许从待验证文件自身建立信任：

1. producer repository 精确为 `Tangbohu09527/CF_agent-gateway`；
2. compatible Gateway commit 是 Agent 发布时批准并固定的完整 40 位 commit SHA；
3. checker SHA-256 是该 commit 中受跟踪 checker blob 的 64 位小写十六进制摘要。

消费者必须确认 Gateway checkout/部署物对应固定 commit，contract 与 checker 都是该
commit 的受跟踪 blob，并对安装后的 checker 重新计算 SHA-256 精确比较。Contract 中的
自声明不能代替 Agent 侧批准 pin。

Git 来源核验只能在清空调用进程 Git 环境、禁用 system/global config、replace object、
fsmonitor、untracked cache 和 hooks 的 hard timeout 中运行。root-owned checkout 由普通
管理用户只读核验时，只注入精确项目路径的 command-scope `safe.directory`；不得写入
持久 global 配置或使用 `safe.directory=*`。checkout top-level 必须精确等于固定 Gateway
项目，Git metadata 必须是项目内直接、非 symlink 的 `.git` 目录；父仓库发现、gitfile
或其他 metadata 路径均拒绝。管理用户仍须具备 checkout 与 `.git` 的只读遍历权限，
`safe.directory` 不会授予文件系统权限。

origin 必须从 `--local --no-includes` 原始配置读取且恰有一个批准值；本地
`include`/`includeIf` 和 `url.*` rewrite 全部拒绝。Index 必须精确匹配 compatible
commit，tracked worktree 必须匹配 Index，`assume-unchanged` 和 `skip-worktree` 均
拒绝。普通与 ignored untracked 使用不带 exclude 规则的 inventory 一并检查；唯一
allowlist 是 top-level `.env`，且其路径必须精确等于已独立通过 owner、mode、
symlink/hardlink 门禁的 `GATEWAY_ENV_FILE`。缺少该文件、将它纳入 Git、或存在任何第二个
untracked/ignored 路径均 fail closed。错误和超时只返回固定脱敏文本，不输出文件名。
受控 Git wrapper 固定 `diff.ignoreSubmodules=none`，tracked-tree 检查还显式传递
`--ignore-submodules=none`；本地配置不能隐藏 submodule commit 漂移、已跟踪修改或未跟踪内容。

Bootstrap 在部署准备放行前执行上述检查；生产 start 先停止并确认 Worker，再在 Agent、
archive 和 QR 变更前执行。commit、tracked/index/worktree、raw origin、artifact blob、
checker 摘要或 Git 命令任一不匹配/失败均 fail closed。

## 精确 Contract 文件

wechat-runtime-contract.json 必须是下列 JSON 的精确语义值，不允许额外字段：

    {
      "contractVersion": "1",
      "producer": {
        "repository": "Tangbohu09527/CF_agent-gateway",
        "checkerSha256": "<64-lowercase-hex-sha256>"
      },
      "agent": {
        "networkAlias": "cf-agent-wechat",
        "port": 6174,
        "tokenAuthority": {
          "hostPath": "/srv/storage/cf-agent-wechat/secrets/auth-token",
          "ownership": "root:root",
          "mode": "0600"
        }
      },
      "gateway": {
        "service": "worker",
        "composeProject": "cf-agent-gateway",
        "checker": "/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat",
        "checkerInterfaceVersion": 1,
        "heartbeatMaxAgeSeconds": 30,
        "requiresDockerHealth": true,
        "requiresSuccessfulPoll": true,
        "requiresLoggedIn": true,
        "silentOutput": true,
        "checkerExecution": {
          "caller": "management-user",
          "sudo": false,
          "dockerSocketAccess": false,
          "producerLinuxProof": "required"
        },
        "lifecycle": {
          "restartPolicy": "no",
          "bootPolicy": "manual-after-fresh-qr",
          "producerLinuxProof": "required"
        },
        "credential": {
          "type": "file",
          "environmentVariable": "CF_AGENT_WECHAT_TOKEN_FILE",
          "workerPath": "/run/secrets/cf-agent-wechat-auth-token",
          "readOnly": true,
          "forbiddenEnvironmentVariable": "CF_AGENT_WECHAT_TOKEN",
          "workerReadabilityProof": "producer-linux-integration"
        }
      }
    }

尖括号内容只是未发布字段的格式说明，不是可部署值。首个兼容 Gateway commit 发布后，
PR #3 必须固定实际 commit 和 checker SHA-256，并让消费者自动验证后，才能形成可部署
contract v1。Compatible commit 只存在于 Agent 侧信任 pin，不能写入由该 commit 自身
跟踪的 contract blob；否则会形成改变文件即改变 commit SHA 的自引用。

消费者拒绝 invalid JSON、非 UTF-8、超限文件、symlink、额外 hardlink、未知 version、
缺字段、额外字段、占位符、非小写 SHA-256、来源无法验证或任一值漂移；Agent 侧 commit
pin 另行要求完整 40 位小写 SHA。

## Checker 接口

checker 是固定路径、无参数、只读的同步命令。消费者以管理用户、最小固定生产环境执行
摘要绑定的只读密封内容快照，工作目录固定为 `/opt/cf-agent-gateway`；不通过
`sudo`，也不在摘要核验后重新打开原 checker 路径。每次调用都必须在 10 秒 hard
timeout 内完成，并同时确认：

1. Gateway Compose project cf-agent-gateway 的当前 worker 实例存在且 running。
2. 当前 Worker 容器 Docker health 为 healthy。
3. 当前实例的 heartbeat 新鲜，年龄不超过 30 秒；旧实例 heartbeat 不得通过。
4. 最新 Poll Cycle 成功，且不存在持续失败状态。
5. Agent WeChat auth 为 logged_in。

只有所有条件同时满足才返回 0。缺配置、实例变化、unhealthy、stale、Poll Cycle
失败、auth 非 logged_in、依赖 API 失败或内部错误均返回非零。超时由消费者视同非零。

stdout 和 stderr 在成功与失败时都必须为空。checker 不得输出 Token、Hash、账号、
联系人、Chat ID、消息正文、checkpoint、数据库行或上游原始错误。必要诊断只能进入
Gateway 自身受限且脱敏的运维日志。消费者观察到任何 checker 输出都必须拒绝该结果，
对外只报告固定脱敏错误。

消费者只用匿名有界管道检测输出，不创建或重新打开临时输出路径。管道出现第一个字节
即丢弃该字节、终止 checker 进程组并返回固定失败；内容不进入 shell 变量、文件、日志
或错误。超时同样终止进程组，外层 hard timeout 仅作第二道兜底。

Contract v1 的 checker 必须可从 descriptor-backed 密封快照执行。它不得通过
`$0`、`BASH_SOURCE`、`/proc/self/exe` 或固定 checker 路径重新读取/执行自身，也
不得依赖这些值定位同仓资源；脚本执行时这些值可以是 `/proc/self/fd/<n>`。需要的
Gateway 资源必须使用上述绝对部署路径，或从固定工作目录
`/opt/cf-agent-gateway` 定位。此约束阻止同 UID 在 provenance 检查后替换路径并伪造
健康返回 0，也避免内容快照悄然改变合法 checker 的工作目录合同。

checker 可以使用 Gateway 自己发布的受鉴权 runtime-health 接口，但其语义必须覆盖
以上全部条件并固定 interface version。本仓库不得以 SQL 或未发布的数据库结构替代
checker。
首个 compatible Gateway pin 还必须提供 producer Linux 集成证据：固定管理用户不在
docker group 且不能直接访问 `docker.sock`，Agent 管理 Docker 通过已授权的 `sudo -n`
fallback，而 checker 本身不经 sudo，仍能通过受鉴权 runtime-health 或等价的已发布接口
同时验证当前实例、Docker health、heartbeat、最新 Poll Cycle 和 auth。该证据必须绑定
compatible Gateway commit、可重复执行且保持 checker 静默与 hard timeout；fake checker
或手工 Host 文件不能满足发布门禁。缺少该 producer 证据时继续
**BLOCKED BY GATEWAY CONTRACT**。

## 生命周期门禁

Bootstrap 必须在基础准备放行前验证。每次 start-qr-login.sh 必须先停止并确认 Worker，
然后在 Agent、archive 或 QR 变更前验证：

- contract 文件和 checker 的路径、owner、mode、symlink/hardlink 合同；
- contract version、producer repository、checker SHA-256 与全部精确字段；
- Agent 侧 compatible commit pin、checkout origin/HEAD 和 tracked blob provenance；
- contract/checker 确为 compatible commit 的受跟踪 blob，且安装后 checker 摘要匹配；
- file credential env pointer、rendered Compose 唯一只读 bind 和 Token bytes absence；
- checker 可执行性和 hard timeout 合同。
- producer Linux 非 docker-group 管理用户、sudo-Docker fallback 与无 sudo checker 集成证据；

Bootstrap 只证明基础部署输入兼容，不运行 checker 来宣称微信已登录，也不启动 Agent
或 Worker。

fresh QR 的 auth/chats/messages 验证全部通过后，脚本才可启动 Gateway worker。
启动后 checker 必须在稳定窗口内重复通过。checker 缺失、输出内容、返回非零、报告
stale 或超时，必须撤销 Worker 放行并确认 Worker 停止；Agent 现场和 archive 保留用于
受限调查，不得用 fake checker 代替生产契约。
`checkerExecution` 固定了消费者权限边界：checker 必须由 management user 直接执行，
不得 sudo，也不得要求该用户可读 Docker socket；`requiresDockerHealth=true` 仍要求
producer 通过已发布的受鉴权接口证明当前 Worker 的真实 Docker health，而不是把该条件
降级成“进程存在”或 heartbeat 文件存在。

`lifecycle.restartPolicy=no` 必须同时由 rendered Compose 和启动后的实际
`HostConfig.RestartPolicy` 精确证明；最大重试次数也必须为 0。
`bootPolicy=manual-after-fresh-qr` 还要求 compatible Gateway producer 提供绑定该
commit 的 Linux 集成证据：Worker 被停止后，Docker daemon restart 与 Debian reboot
都不能在人工 fresh QR 放行前启动它，且不存在 Gateway 自身的 boot unit 绕过该门禁。
只在文档中声明、只测试 `docker compose stop` 或沿用 `unless-stopped` 均不兼容。

本仓每次 fresh QR 前会枚举 enabled/linked systemd service、timer、path、socket、
target，并检查 timer/path/socket 的一跳 activation 与 target 的直接 Wants/Requires；
该扫描只覆盖可由当前 systemd inventory 证明的 Agent 自动启动源。它不能自动证明 cron、
Docker Swarm、Kubernetes、外部配置管理、外部编排器或人工 `docker run` 不存在，也
不递归证明任意深度的 systemd dependency graph。这些非 systemd/超出枚举深度的启动源
仍是 CFserver 人工审计 pending，文档和 CI 不得声称已经穷尽；Gateway producer 的
versioned boot-stop gate 缺失时继续 **BLOCKED BY GATEWAY CONTRACT**。


## Gateway 审计缺口

对 Gateway PR #4 commit 0c4f449fe42fdc28619ef64004de7be33d5a7508 的只读审计
确认：

- Gateway 只支持 environment-based CF_AGENT_WECHAT_TOKEN，尚无 file-based
  credential；
- production Worker 固定为 `10001:10001`，当前没有能够让该真实身份读取
  root:root 0600 authority mount、且不降低 Secret 合同的实现或 producer Linux 证据；
- production Worker 仍为 `restart: unless-stopped`，没有发布
  `manual-after-fresh-qr` boot-stop gate 或 daemon/Host restart 证据；
- 仓库未提供上述 versioned contract JSON；
- 仓库未提供上述可部署 checker；
- 本仓消费者已实现 producer/Agent-side commit/tracked-blob/checker SHA-256 证明机制，
  但兼容 commit 与 digest pin 尚未发布，因此生产路径主动 fail closed；
- 未发现能够替代缺失 contract/checker 文件、并满足本契约全部版本与输出约束的稳定
  runtime-health 接口。

因此该 commit 不能填写为“compatible Gateway commit”。Gateway PR #4 后续发布兼容
commit 后，必须重新只读审计精确文件、Token 输入、checker 行为、测试和绿色 Workflow
Run，再更新本节。

## 仍需 CFserver 验证

跨仓代码契约具备兼容 commit 后，仍需在 CFserver 使用真实 Agent 镜像和真实手机验证：

- Token 文件可被 Agent 与 Gateway 按合同读取且不进入 process environment、
  rendered Compose、Docker inspect 或日志；
- cf-internal alias 与 6174 连接可用；
- fresh QR 后 auth/chats/messages 全部通过；
- 当前 Worker health、heartbeat、Poll Cycle 和 auth 由 checker 同时确认；
- checker stale、失败、超时和输出违规都会停止 Worker；
- Host reboot 窗口内 Agent 与 Worker 均保持批准的停止状态。

这些实机项目不能由 fake Docker、Alpine/Nginx policy fixture 或 mock checker 替代。
