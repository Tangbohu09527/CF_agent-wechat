# 2026-08-14 消息与媒体生产验证记录

> [!CAUTION]
> **Historical / Archived.** 本页适用于 2026-08-14 的消息/media 样本；文档审计起点
> 为 Commit `5ee3b21bd8a01dd36d15b506ffa1441d85a1328a`，不代表现场镜像源码映射。
> 它不是当前 CFserver Runbook。仍有效的是当时私聊/群聊文本、消息字段和图片 media
> 观察；不能外推到当前上游 schema、forced QR、Gateway 内部语义或图片/文件发送。
> 当前事实见 [生产状态](../production-status.md)，当前验收见
> [2026-09-03 R2 记录](2026-09-03-forced-qr-r2-production.md)。
>
> Repository promotion was completed later on 2026-09-04; this record preserves the
> state at its evidence date.

## 记录边界

本文记录 `CF_agent-wechat` 在 CFserver 上新增的脱敏实机证据。文档录入前的仓库
基线为 Commit `5ee3b21bd8a01dd36d15b506ffa1441d85a1328a`；该 Commit 只标识本次
文档审计起点，不用于推断 CFserver 当时运行镜像或代码的 Commit。

本文只证明 agent-wechat 接收或返回的接口字段，以及微信侧实际观察到的结果。本文
不记录真实账号、联系人、聊天标识、消息标识、服务器 IP、Token、图片、图片哈希、
API Key、数据库 URL 或密钥，也不描述 Gateway/Hermes 的身份、权限、调度、存储、
防回环或数据库修复实现。

本文是 2026-08-14 的追加证据，不回填或改写
[2026-08-13 CFserver 生产验证](2026-08-13-cfserver-production.md)的部署与登录结论。

## 生产验证矩阵

| 验证项 | 结果 | 状态 |
| --- | --- | --- |
| 私聊文本发送 | 请求成功，文本实际出现在微信私聊中 | 已实现并实机验证 |
| 群聊文本发送 | 请求成功，文本实际出现在微信群聊中 | 已实现并实机验证 |
| 普通群消息 | `isMentioned=false` | 已实现并实机验证 |
| 真正 @机器人 | 使用微信成员选择功能时 `isMentioned=true` | 已实现并实机验证 |
| 私聊引用消息 | 本次样本为 `type=49` 且存在 `reply` | 已实现并实机验证 |
| 群聊引用消息 | 本次样本为 `type=49` 且存在 `reply` | 已实现并实机验证 |
| 图片消息读取 | 本次样本为 `type=3`，消息 ID 字段可用 | 已实现并实机验证 |
| 图片 media 读取 | 取得 5712 字节 JPEG 数据并通过文件签名检查 | 已实现并实机验证 |
| 自消息识别字段 | 发送后消息可通过字段识别 | 已实现并实机验证 |

## 文本发送

本次通过以下接口完成真实私聊和群聊发送：

```text
POST /api/messages/send
```

脱敏请求体为：

```json
{
  "chatId": "<CHAT_ID>",
  "text": "<REDACTED_MESSAGE_CONTENT>"
}
```

两个场景均观察到文本实际出现在微信中。该证据只证明 agent-wechat 接收发送请求并
完成微信文本发送，不描述调用方的身份、权限或 AI 调度实现。

## 群消息与真正 @字段

真实群聊样本包含 `sender`、`senderName`、`chatId`、`timestamp` 等字段。本次对照
观察到：

- 普通群消息：`isMentioned=false`。
- 通过微信成员选择功能真正 @机器人：`isMentioned=true`。

因此，下游可以使用 `isMentioned` 区分本次观察到的真正 @与普通手工文字。该布尔值
是 agent-wechat 提供的原始字段，不表示本项目负责权限、身份或准入判断。

## 引用消息

私聊和群聊引用消息均已通过以下接口读取：

```text
GET /api/messages/{chat_id}
```

本次引用样本的微信原始类型为 `49`，并存在 `reply` 结构，可从中提取被引用消息摘要。
`type=49` 不是引用消息的充分判据：历史文件与合并转发外层也可能使用该类型，应同时
检查 `reply` 结构。

该结果只证明 agent-wechat 提供了引用结构。引用消息不等同于群聊 @机器人，也不证明
被引用内容已经传入 Hermes；下游可以据此识别 reply 类型。

## 图片消息与 media 提取

真实微信图片的原始类型为 `3`，通过
`GET /api/messages/{chat_id}` 可读取，并具有可用于 media 请求的 `localId` 和
`serverId`。随后通过以下接口成功取得图片数据：

```text
GET /api/messages/{chat_id}/media/{local_id}
```

| 检查项 | 结果 |
| --- | --- |
| `supported` | `true` |
| `media_type` | `image` |
| `format` | `jpeg` |
| `filename` | 存在，真实值未记录 |
| 媒体数据长度 | 5712 字节 |
| JPEG 文件签名 | 有效 |
| SHA-256 | 已在审计中计算，公共记录不保留值 |

该结果证明图片消息识别和媒体读取已完成生产实机验证。图片发送接口和文件发送接口
尚未完成生产实机验证；本文也不声称 Hermes 已读取该图片或 Gateway 已完成附件
持久化。

## 自消息字段

机器人发送文本后，`GET /api/messages/{chat_id}` 的消息列表可看到对应消息，并可通过
`isSelf` 或机器人发送者信息识别。该结论只记录接口字段能力，不描述下游具体的
防回环实现。

## 下游故障边界

验证期间曾出现下游 AI 服务不可达而没有机器人回复；同时观察到：

- `cf-agent-wechat` 容器和 agent-server 健康。
- 微信登录状态正常。
- 目标消息可以由 agent-wechat 正常读取。

因此，“消息可读但没有 AI 回复”应转交 Gateway/Hermes 链路排查，不能直接判定为
agent-wechat 或微信登录故障。本文不记录下游数据库或服务修复过程。

## 尚未完成的实机验证

- 完全新设备在 SSH 终端显示二维码、手机扫码并完成登录。
- 图片发送接口。
- 文件发送接口。

新设备二维码流程已经实现，但当前实际通过的仍是“已信任设备 -> 手机确认 -> 登录
成功”。图片接收和 media 读取不能外推为图片或文件发送已经验证。

## 结论

本次新增证据支持以下准确表述：

> 私聊和群聊文本发送、群消息真正 @字段、私聊和群聊引用结构、图片消息识别与
> media 读取已完成 CFserver 生产实机验证。

本结论不表示 Gateway/Hermes 内部能力、AI 回复链路或附件持久化已经完成。接口边界见
[API 文档](../api.md)，验证状态见 [验证总览](../validation.md)，故障分层见
[故障排查](../troubleshooting.md)。
