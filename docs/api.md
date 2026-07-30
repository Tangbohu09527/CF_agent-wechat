# API 文档

## 适用范围

本文只记录镜像 `ghcr.io/thisnick/agent-wechat:0.11.15` 固定 digest 基线中已经
验证的端点和行为。请求/响应字段尚未作为 CF Gateway 稳定契约冻结；升级镜像后
必须重新验证。

## 访问与认证

默认基础地址为 `http://127.0.0.1:6174`。服务没有 TLS，远程管理应通过 SSH
隧道访问，不能把 6174 端口直接暴露到公网。

REST 请求使用部署目录中的 auth-token：

```bash
BASE_URL=http://127.0.0.1:6174
TOKEN="$(cat secrets/auth-token)"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${TOKEN}" \
  "${BASE_URL}/api/status/auth"
unset TOKEN
```

不得把 token 写入 Git、共享日志、截图或命令历史。WebSocket 客户端应沿用固定
镜像版本实际要求的认证方式；在 Gateway 契约冻结前不要假设其握手字段长期稳定。

## REST 接口

| 方法 | 路径 | 能力 | 状态 |
| --- | --- | --- | --- |
| GET | `/api/status/auth` | 查询 agent-wechat session 认证状态 | **Verified** |
| GET | `/api/contacts` | 读取联系人 | **Verified** |
| GET | `/api/chats` | 读取聊天 | **Verified** |
| GET | `/api/messages/{chat_id}` | 读取指定聊天的消息 | **Verified** |
| POST | `/api/messages/send` | 按 `chatId` 发送文本 | **Verified**：`success=true` |
| GET | `/api/messages/{chat_id}/media/{local_id}` | 获取文件 Base64 数据 | **Verified**：`txt`、`zip` |

`{chat_id}` 必须使用 API 返回的聊天标识，并由客户端做 URL 编码。当前验证确认
端点可用，但尚未在本仓库冻结分页、错误码、消息体字段和兼容性契约；Gateway
接入前应基于固定 digest 补充契约测试，不能自行猜测字段。

## WebSocket 接口

| 路径 | 能力 | 状态 |
| --- | --- | --- |
| `/api/ws/login` | 执行 agent-wechat 登录/初始化流程 | **Verified** |
| `/api/ws/events` | 接收实时消息事件 | **Pending Investigation**：连接成功，未观察到新消息事件 |

## 登录与初始化

微信 GUI 和 agent-wechat session 不是同一个状态源。Docker 重启后的本轮测试中，
容器、health 和 VNC 自动恢复，但微信客户端需要重新登录；重新登录后 agent-server
登录状态恢复正常。

业务 API 的正确前置流程是：

```text
连接 /api/ws/login
        ↓
执行 login flow
        ↓
等待 login_success
        ↓
保存本次返回的 userId
        ↓
验证 /api/contacts、/api/chats、/api/messages/{chat_id}
```

连接建立或 GUI 可见都不能作为初始化成功标准。最终应直接查询
`GET /api/status/auth` 并验证业务 API。本轮已验证的关键响应字段为：

```json
{
  "status": "logged_in",
  "loggedInUser": "wxid_trx4eew84jvc22_0352"
}
```

以上只记录本次响应中已核对的字段，不代表完整响应 schema 已冻结。

## 文本消息

`POST /api/messages/send` 已验证可指定 `chatId` 并发送文本，成功响应包含
`success=true`。

`GET /api/messages/{chat_id}` 已验证返回消息的以下字段：

- `sender`
- `senderName`
- `content`
- `timestamp`
- `isSelf`

## 文件消息

从微信发送 `txt`、`zip` 文件后，消息可被识别为 `type=49`，并包含用于获取文件的
`localId` 以及文件名相关的 `filename`/`content` 信息。

`GET /api/messages/{chat_id}/media/{local_id}` 已验证返回：

```json
{
  "type": "file",
  "data": "<base64>",
  "format": "<format>",
  "filename": "<filename>"
}
```

`txt`、`zip` 均已成功取得 Base64 数据。该结果不表示 API 文件发送已经验证。

## 群聊与引用

群聊已验证使用群 `chatId` 读取消息、识别 `sender` 和群文件；群消息包含
`isGroup=true`。

群聊中的文本引用和文件引用均可返回上下文：

```json
{
  "reply": {
    "sender": "<sender>",
    "content": "<content>"
  }
}
```

## 已验证能力

- **Verified**：联系人读取。
- **Verified**：聊天读取。
- **Verified**：消息读取。
- **Verified**：按 `chatId` 发送文本。
- **Verified**：`txt`、`zip` 文件消息识别与 Base64 获取。
- **Verified**：群消息、发送者和群文件识别。
- **Verified**：文本和文件引用上下文读取。

## 尚未验证

- **Pending**：图片发送。
- **Pending**：通过 API 发送文件。
- **Pending Investigation**：`/api/ws/events` 实时消息事件；仅连接已验证。
- **Pending**：CF Gateway / Hermes Agent 集成。

文件接收与获取不等于文件发送，因此不能将 `POST /api/messages/send` 描述为支持
所有消息类型。实时消息事件尚未观察到，不得对外宣称支持。

## Gateway 接入前待冻结项

- 请求和响应 JSON schema。
- 分页、排序和消息时间语义。
- 错误码、超时和重试条件。
- 发送幂等与重复消息识别。
- WebSocket 认证、心跳、重连和事件去重。
- chat ID、user ID 和 message ID 的稳定性与映射规则。
- 敏感数据脱敏和审计字段。

这些项目均为 `Pending`。
