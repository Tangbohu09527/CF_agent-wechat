# agent-server API 边界

## 适用范围

本文描述 `CF_agent-wechat` 对外提供的 agent-server 接口及当前验证边界。Gateway
内部身份、权限、Hermes 调度、消息 checkpoint 和业务编排不属于本项目文档范围。

CFserver 容器间调用地址：

```text
http://cf-agent-wechat:6174
```

该地址只用于 `cf-internal` 网络。服务不提供 TLS，不应直接暴露到公网。

## 认证

除健康检查外，接口使用 Authorization 请求头携带生产 Token。公共示例只能使用
占位符 `<AGENT_WECHAT_TOKEN>`，不得读取、打印或提交真实 Token。

生产 Token 由 Compose 只读挂载到 `/data/auth-token`。宿主文件保持
`root:root 600`，其父目录保持 `root:root 700`。日常状态和登录操作应使用
`scripts/status.sh` 与 `scripts/login.sh`，不要为了手工调用放宽权限。

## 2026-08-13 生产验证

以下端点已经由 Gateway 经 `cf-internal` 实机调用：

| 方法 | 路径 | 用途 | 状态 |
| --- | --- | --- | --- |
| GET | `/health` | 服务健康检查 | 已实现并实机验证 |
| GET | `/api/status/auth` | 查询微信认证状态 | 已实现并实机验证 |
| GET | `/api/chats` | 读取聊天列表 | 已实现并实机验证 |
| GET | `/api/messages/{chat_id}` | 读取指定聊天的消息 | 已实现并实机验证 |

`{chat_id}` 必须来自 API 返回值并由调用方正确编码。公共文档和日志不得记录真实
聊天标识。

## 登录接口

生产登录工具使用：

| 方法或协议 | 路径 | 用途 | 状态 |
| --- | --- | --- | --- |
| GET | `/api/status/auth` | 登录前检查和登录后复核 | 已实现并实机验证 |
| POST | `/api/status/login` | 在 `logged_out` 时启动登录 | 已实现并实机验证 |
| WebSocket | `/api/ws/login` | 接收手机确认和成功事件 | 已实现并实机验证 |

已验证链路是已信任设备的手机确认登录。二维码事件处理与 SSH 终端渲染已经实现，
但完全新设备扫码闭环尚未实机验证。详细行为见
[微信登录管理](login-management.md)。

`GET /api/status/auth` 的当前关键状态为：

- `logged_in`：微信已登录。
- `logged_out`：微信未登录，可以启动登录流程。
- `app_not_running`：微信客户端未运行，应先查容器日志。

响应可能包含实际账号标识；任何对外记录都应替换为
`<BOT_WECHAT_ACCOUNT_ID>`。

## 2026-08-14 消息与媒体生产验证

以下接口已在 CFserver 生产环境中完成真实私聊、群聊或图片样本验证：

| 方法 | 路径 | 本次验证行为 | 状态 |
| --- | --- | --- | --- |
| POST | `/api/messages/send` | 使用 `chatId` 和 `text` 发送私聊、群聊文本，文本实际出现在微信中 | 已实现并实机验证 |
| GET | `/api/messages/{chat_id}` | 读取群消息字段、引用结构、图片消息和自消息字段 | 已实现并实机验证 |
| GET | `/api/messages/{chat_id}/media/{local_id}` | 读取真实图片的 JPEG 数据 | 已实现并实机验证 |

### 文本发送

生产验证使用以下脱敏请求体：

```json
{
  "chatId": "<CHAT_ID>",
  "text": "<REDACTED_MESSAGE_CONTENT>"
}
```

私聊和群聊均完成了“接口接收请求 -> 微信中实际出现文本”的观察。该结论只证明
agent-wechat 的文本发送行为，不描述调用方身份、权限或 Hermes 调度实现。

### 消息字段

| 场景 | 已观察字段或结构 | 准确边界 |
| --- | --- | --- |
| 普通群消息 | `sender`、`senderName`、`chatId`、`timestamp`、`isMentioned=false` | 提供微信消息原始字段 |
| 真正 @机器人 | 通过微信成员选择功能发送时 `isMentioned=true` | 下游可区分真正 @与普通手工文字；本项目不做权限判断 |
| 私聊和群聊引用 | 本次样本为 `type=49`，并存在 `reply` 结构 | 可提取被引用消息摘要；引用不等同于群聊 @ |
| 图片消息 | `type=3`，并有可用的 `localId`、`serverId` | 支持定位并读取本次图片样本 |
| 机器人发送文本 | 消息列表可见对应消息 | 可由 `isSelf` 或机器人发送者信息识别，不描述下游防回环实现 |

`type=49` 不能单独定义为引用消息；历史实验中的文件和合并转发外层也可能使用该
类型。本次引用结论由 `type=49` 与 `reply` 结构共同支持。`reply` 的存在不证明被
引用内容已经传入 Hermes；下游可以据此识别 reply 类型。

### 图片 media

真实图片样本的 media 响应已观察到：

| 检查项 | 结果 |
| --- | --- |
| `supported` | `true` |
| `media_type` | `image` |
| `format` | `jpeg` |
| `filename` | 存在，未记录真实值 |
| 媒体数据长度 | 5712 字节 |
| JPEG 文件签名 | 有效 |
| SHA-256 | 已在审计中计算，公共文档不记录值 |

该结果只证明图片消息识别和 media 读取。图片发送接口、文件发送接口尚未完成生产
实机验证；也不证明 Hermes 已读取图片或 Gateway 已完成附件持久化。

## 历史实验验证能力

以下能力或扩展边界只在早期固定镜像的实验环境中留下证据，仍只作为兼容性参考：

| 方法 | 路径 | 历史验证边界 |
| --- | --- | --- |
| GET | `/api/contacts` | 读取联系人 |

历史实验还覆盖过 `txt`/`zip` 文件 media、群消息、引用上下文和合并转发消息外层
识别。这些历史证据按原日期保留，不能与 2026-08-14 图片样本混写。合并转发内部
解析、图片发送和 API 文件发送未由这些记录证明。具体历史边界见
[V1 验证结果](05_V1验证结果.md)，该文档已封存为非当前生产方案。

## WebSocket 事件边界

`/api/ws/events` 在历史实验中仅验证过建立连接，未观察到新消息事件，因此仍属于
待调查能力。不得把登录 WebSocket `/api/ws/login` 的成功验证外推为实时消息事件
已经可用。

## 调用方约束

- 调用方应设置连接、请求和重试上限，不得假设未记录的响应字段已经冻结。
- 不得在日志、异常、URL 查询参数或命令历史中写入认证凭据。
- 账号、联系人、聊天标识和消息正文均按敏感数据处理。
- 容器健康不等于微信已登录；业务调用前应检查认证状态。
- Gateway 只作为本服务调用方出现，其内部故障应转交 Gateway 项目处理。

当前生产验证证据见
[2026-08-13 CFserver 生产验证](validation/2026-08-13-cfserver-production.md) 和
[2026-08-14 消息与媒体生产验证](validation/2026-08-14-message-media-production.md)。
