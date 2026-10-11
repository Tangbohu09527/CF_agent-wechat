# agent-server API 边界

## Scope

本仓库不实现上游 `agent-server`。本文区分：

1. **R2 lifecycle contract**：仓库脚本和测试调用、解析并用于生产放行的接口。
2. **Observed upstream behavior**：生产集成中观察到的发送/media 行为，不是本仓库拥有
   的稳定公共 schema。
3. **Pinned media candidate**：锁文件固定的未合并升级候选；源码与隔离测试描述不代表
   现场已部署、已登录微信取件成功或下游已理解文件。

Gateway 内部 Message、Admission、Checkpoint、Dispatch、Response、Delivery Receipt、
重试和去重不属于本文。本仓负责微信通道、生命周期及上游适配，不实现文件理解、分类
或 Gateway 队列。

**状态日期边界（2026-10-11）**：R2 production online 来自
[2026-09-03 历史验收](validation/2026-09-03-forced-qr-r2-production.md)，不是今天的
在线探测。用户确认在 Gateway d9 新 plan 通过后执行了 CFserver reboot；重启后的
微信容器、登录、API 和 Poll/Delivery Gate 均未复验。Gateway plan 通过不能替代
WeChat 入站 PDF/原图验收。完整状态与来源见[生产状态](production-status.md)。

## Address and network

| 调用方 | Base URL |
| --- | --- |
| CFserver Host 生命周期脚本 | `http://127.0.0.1:6174` |
| `cf-internal` 中的 Gateway | `http://cf-agent-wechat:6174` |

6174 只绑定 Host loopback，不提供公网 API 或 TLS。WebSocket 从同一 loopback Agent
地址派生为 `ws://127.0.0.1:6174/api/ws/login`。

## Authentication

- `GET /health` 不使用 Bearer Token。
- 其他当前生命周期 HTTP 请求使用
  `Authorization: Bearer <AGENT_WECHAT_TOKEN>`。
- HTTP 与 WebSocket 同时发送 `X-Session-Id: default`。
- 生产 session ID 只接受 `default`。
- Token 从只读 `/data/auth-token` 对应的 Host 文件加载，不放在 URL、argv、`.env`
  或日志中。

公共示例不得替换成真实 Token。

## R2 lifecycle endpoints

### GET /health

| 项目 | 当前行为 |
| --- | --- |
| Authentication | 无 |
| Request body | 无 |
| Response parsing | 脚本只要求 HTTP 成功，不依赖 body schema |
| Timeout | 生命周期脚本默认 connect 5 秒、total 45 秒；Compose healthcheck timeout 5 秒 |
| Failure | 连接错误、超时或非成功 HTTP 状态均失败 |

Docker health 只证明该端点可达，不能证明 WeChat 登录或 Gateway readiness。

### GET /api/status/auth

| 项目 | 当前行为 |
| --- | --- |
| Authentication | Bearer + `X-Session-Id: default` |
| Request body/query | 无 |
| Required response | JSON object，顶层 `status` 必须为非空字符串且无控制字符 |
| Used values | `logged_in`、`logged_out`、`qr_pending`、`waiting_for_qr`、`waiting_for_scan` |
| Timeout | 默认 connect 5 秒、total 45 秒 |
| Failure | HTTP、JSON、类型或 `status` 校验失败均不可用 |

脚本不依赖账号字段，也不得输出账号字段。除上述状态外的上游值不会被文档宣称为稳定
枚举。

### GET /api/chats

| 项目 | 当前行为 |
| --- | --- |
| Authentication | Bearer + `X-Session-Id: default` |
| Request body/query | 无 |
| Accepted list shape | JSON list，或 object 中递归的 `chats/data/items/results/list` |
| Explicit rejection | `success=false` 或存在 `error` 的 object |
| Fresh start requirement | 至少一个可识别聊天 |
| Candidate ID fields | `chatId`、`chat_id`、`id`、`userName`、`username` |
| Timeout | 默认 connect 5 秒、total 45 秒 |

这些多形态 parser 是对上游已观察行为的兼容处理，不是本仓库冻结的响应 schema。状态
输出不会打印选中的 ID。

### GET /api/messages/{chat_id}

| 项目 | 当前行为 |
| --- | --- |
| Authentication | Bearer + `X-Session-Id: default` |
| Path field | `chat_id` 必须来自 chats API |
| URL encoding | 使用 percent-encoding，所有非安全字符编码后放入单个 path segment |
| Accepted list shape | JSON list，或 object 中递归的 `messages/data/items/results/list` |
| Explicit rejection | `success=false` 或存在 `error` 的 object |
| Timeout | 默认 connect 5 秒、total 45 秒 |

R2 放行只验证“可读取可识别的消息列表”，不冻结消息字段、排序、分页或时间单位，也不
输出 Chat ID 或正文。

### POST /api/status/login?newAccount=true

| 项目 | 当前行为 |
| --- | --- |
| Authentication | Bearer + `X-Session-Id: default` |
| Query | 必须为 `newAccount=true` |
| Request body | 当前脚本不发送 body |
| Accepted response | JSON object；无有效 `error/errors`，且 `success=true` 或 status 为 QR pending 状态 |
| Status location | 顶层 `status`，或 object `state.status` |
| Timeout | 默认 connect 5 秒、total 45 秒 |

该 HTTP 成功只表示登录流程已开始，不是二维码证据或登录成功。

### WebSocket /api/ws/login

实际连接：

~~~text
GET Upgrade /api/ws/login?timeoutMs=<LOGIN_TIMEOUT_MS>&newAccount=true
Authorization: Bearer <AGENT_WECHAT_TOKEN>
X-Session-Id: default
~~~

| 项目 | 当前行为 |
| --- | --- |
| Default timeout | `LOGIN_TIMEOUT_MS=300000`，作为总 deadline 和 `timeoutMs` query |
| Proxy | WebSocket client 使用 no-proxy |
| Accepted event object | 必须是 UTF-8 JSON object |
| Event types | `status`、`qr`、`phone_confirm`、`login_success`、`login_timeout`、`error` |
| QR payload lookup | event 本身，以及 object `state`、`data`、`payload` |
| Text QR fields | `qrBinaryData`（UTF-8 bytes/list 或 string）、`qrData` string |
| PNG field | `qrDataUrl` 在 production fresh QR 中被拒绝 |

关键错误行为：

- WebSocket URL 含 username/password：拒绝。
- 非 `default` session ID：拒绝。
- connect/recv 失败、early close、invalid JSON、non-UTF8、timeout：拒绝。
- 外部错误内容会替换 Token、移除 C0/DEL 控制字符并截断到 240 字符。
- 当前 WebSocket 未渲染 QR 时收到 `login_success`：拒绝。
- QR 文本包含 Token：在渲染前拒绝。
- PNG-only `qrDataUrl`：在任何二维码输出前拒绝。

收到 `login_success` 后仍需 Auth 确认以及
`POST_LOGIN_READY_TIMEOUT=120` 秒内的进程/chats/messages 验证。

## Observed upstream send behavior

### POST /api/messages/send

该端点在 [2026-08-14 直接验收](validation/2026-08-14-message-media-production.md)
及 [2026-09-03 R2 集成验收](validation/2026-09-03-forced-qr-r2-production.md)中
观察到文本发送；这些历史结果不证明 2026-10-11 reboot 后仍可发送：

~~~json
{
  "chatId": "<CHAT_ID>",
  "text": "<REDACTED_MESSAGE_CONTENT>"
}
~~~

- 使用同一 Bearer Agent API 边界。
- 私聊和群聊均观察到微信侧收到文本。
- 历史样本观察到 `success=true`。
- 字段可选性、错误码、限流、重试与完整响应 schema 未由本仓库冻结。
- 当前生命周期脚本不调用该端点；Gateway 调用方必须自行设置有界超时。

这是 **observed upstream behavior, not a repository-owned stable public contract**。

## Observed upstream media behavior

2026-09-28 的[媒体取件核验](validation/2026-09-28-media-retrieval-candidate.md)区分
固定历史镜像与升级候选：历史文件 GET 仅查缓存，不触发原生下载，图片可优先返回
缩略图。候选身份只以 [media-retrieval.lock.json](../upstream/media-retrieval.lock.json)
为准：release `0.15.1`、源码 `96c2e90c497d999bf5189a134a9b3b293731f42e`，仅
`linux/amd64` 已审计。它不是“当前最新”或生产现用版本的声明，锁文件也没有被生产
Compose/安装脚本读取。

### GET /api/messages/{chat_id}/media/{local_id}

2026-08-14 历史生产样本取得过 5712 字节 JPEG，并检查文件签名；该样本层级及是否与
发送前文件逐字节一致未证明。2026-09-28 记录的 PDF 两次相隔约 10 分钟仍是 HTTP 200、
`pending`、无 data/url；图片 JPEG 的大小/摘要与源样本不同。这些失败记录仍然有效，
不因候选代码或 Gateway plan 通过而改为成功。

调用和证据边界：

- 使用 Bearer Agent API 认证。
- 两个 path 标识都来自上游消息结果，并应按单个 path segment 安全编码。
- 图片读取曾通过；图片发送和文件发送不能由此推导。
- media response 字段、Base64/二进制表示、错误码和跨版本兼容性未冻结。
- 该端点不是 R2 status 或 fresh QR 放行条件。

这是 **observed upstream behavior, not a repository-owned stable public contract**。

### 附件取件的四层证据

| 层级 | 能证明什么 | 不能据此声称什么 |
| --- | --- | --- |
| 消息/附件元数据 | 消息含类型、文件名、ID，可能含声明长度/MD5 | 元数据不是文件；有文件名或 HTTP 200 不代表已有字节 |
| 下载触发 | 固定候选在缓存无可用字节且原生元数据合格时尝试提交 native 下载；提交/拒绝需独立证据 | 历史 GET 只查缓存；`pending` 不等于 queued/downloading，提交成功也不等于下载完成 |
| 缓存命中 | 找到可读文件；候选普通文件还校验消息声明长度/MD5 | 缓存存在不证明本次 GET 触发过下载，也不自动证明是发送前原文件 |
| 完整字节取得 | 实际解码 data 或取回 url 的字节，并核对大小/摘要；候选普通文件完整性与消息声明相符 | `data`/`url` 字段存在、扩展名、HTTP 200 或文字回复均不替代字节校验或内容理解 |

历史 `pending` 还可能表示文件缺失或读取失败；候选元数据不足、原生进程/helper 拒绝、
尚无完整匹配缓存等也可能表现为 pending/无 data，不能把它当作下载进度。重复历史
GET 不会启动下载；候选 GET 可能改变微信缓存，不能把两版接口视为同一种只读操作。

PDF、Word、Excel、PPT 及旧 Office 在固定候选中共用普通文件 subtype 6 取件路径。
该路径不实现格式解析、OCR、文件理解或分类；取得字节与下游内容处理须分别验收。
合成缓存 fixture、源码和制品校验不证明真实登录微信的 native 取件通过。

### 候选图片质量与“原件”

| 请求/概念 | 固定候选含义 | 验收边界 |
| --- | --- | --- |
| 默认或 `quality=best` | 从 full、standard、thumbnail 中选当前可用最高层，并报告质量 | 可降到标准图/缩略图；展示可用不等于原图可用 |
| `quality=full` | 严格选择 `_h.dat` 原图缓存层 | 缺 full 不用 standard/thumbnail 冒充；响应 `type=image` 仍可能无字节 |
| `quality=standard` | 选择普通 `.dat` 标准图层 | 不是 full；未发送 Original 的普通图依赖微信实际缓存 |
| `quality=thumbnail` | 选择 `_t.dat` 缩略图层 | 只证明预览图层，不满足原图存取 |
| 发送前文件逐字节一致 | 实际取得字节与发送前样本大小、SHA-256 一致 | `quality=full` 只是缓存层级；WXGF 转 JPEG/GIF 后不能称为逐字节原件 |

记录请求质量、响应质量、实际字节和是否转码。固定候选显式 full/standard/thumbnail
响应的 `quality` 可能缺失或为 null，不能据此改写请求层级；同样不能仅凭 quality
标签、文件名或 HTTP 200 判定成功。必须实际解码/取回字节；转码结果单独标注，摘要
不同本身也不能区分发送转换、标准图或缩略图。以上仍待真实微信入站原图验收。

## Error and timeout policy

- `curl --fail` 将 HTTP 非成功状态视为失败，但本仓库不声明固定的 4xx/5xx code map。
- HTTP 默认 `HTTP_CONNECT_TIMEOUT=5`、`HTTP_TIMEOUT=45` 秒。
- WebSocket 登录默认 300 秒总 deadline，状态事件不会延长总 deadline。
- 登录成功后的 Runtime readiness 默认 120 秒，每 2 秒轮询。
- Agent/Gateway/Docker/Compose 还各有独立硬超时，不能改成无限等待。
- 上游响应若不符合脚本当前 parser，生命周期按失败处理。

## Status mapping

`status.sh` 使用 `/health`、auth、chats 和 messages，再叠加容器、WeChat 进程、
Runtime mounts 与 Gateway Contract。退出码：

- `0`：全部 11 项生产门槛通过。
- `1`：配置/查询/Token/Message API/Gateway failure。
- `2`：明确 `logged_out`。
- `3`：容器、health、Agent、进程、Runtime mode 或其他 auth 状态不可用。

退出码只说明该次执行的结果，历史 `0` 不代表 reboot 后当前在线。`restart: "no"`、
每次启动 fresh QR、Archive 不得恢复活动 Session 的规则继续有效；automatic boot
stop gate 未被证明，不能承诺 Host reboot 后 Poll/Delivery Gate 一定关闭。恢复时须
显式 stop/confirm，再按 fresh QR 和完整 readiness 重新验收。

## 调用方约束

- 调用方必须设置连接、总请求和重试上限，不假设未记录字段已经冻结。
- Token 不得进入 URL、argv、环境文件、异常、命令历史或日志。
- 账号、联系人、Chat ID、消息正文和 media 均按敏感数据处理。
- 业务调用前检查完整在线状态；Docker health 或 Auth 单项不足以放行。
- Gateway 只作为本服务调用方出现，其内部故障转交 Gateway 项目处理。
## Non-contract historical endpoints

旧 V1 记录中出现过 contacts 与消息事件 WebSocket。当前 R2 脚本和测试不调用它们，
本文不把它们列为当前生产 API。需要追溯时只查看
[V1 验证结果](05_V1验证结果.md)，不得把历史观察外推到当前上游镜像。

历史实机证据见
[2026-09-03 R2 生产验收](validation/2026-09-03-forced-qr-r2-production.md)；
2026-10-11 reboot 后状态仍待复验，见[生产状态](production-status.md)。
