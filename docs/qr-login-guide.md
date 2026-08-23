# QR Login Guide

本文是生产 forced fresh QR 操作指南。生产环境每次启动都要求新的 runtime 和新的二维码，
不检查旧 session 是否仍可复用。

## 唯一入口

由人工在受控 SSH TTY 执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
```

`scripts/login.sh` 只是无条件 `exec` 到上述入口的兼容包装，不提供第二套登录、
诊断或恢复语义。首次部署时应先完成
[Bootstrap](deployment/new-device-bootstrap.md)；已运行部署的输入变化时，应先用
`stop-qr-runtime.sh` 受控停止 Agent/Worker，再执行 Bootstrap。Bootstrap 不会登录微信。

## 启动前

确认：

1. 当前 SSH 会话是受控 TTY，终端宽度足以显示二维码。
2. 没有另一个 start/stop 流程持有并发锁。
3. Bootstrap 已完成且生产 Compose render 为 `restart: "no"`。
4. `wechat-worker` 可由脚本停止和确认。
5. Token、runtime、archive、Gateway 路径、固定 heartbeat checker、Docker
   socket、`live-restore=false` 和 Compose 校验通过。
6. 终端、录屏、日志采集和 CI 不会捕获二维码。

## 权威状态机

`start-qr-login.sh` 必须按顺序：

1. 校验用户、TTY、配置和依赖。
2. 获取独占锁。
3. 安全读取 `docker/.env` 和 root-only Token。
4. 校验本机 Docker、Compose 和 Gateway 路径。
5. 停止并确认 Gateway `wechat-worker`。
6. 停止并移除旧 `agent-wechat` 容器，不删除 bind 数据。
7. 原子归档旧 runtime，并写入脱敏 manifest。
8. 创建全新的 `runtime/data` 和 `runtime/wechat-home`。
9. 使用 `restart: "no"` 创建新容器。
10. 请求 `newAccount=true` 的 fresh QR。
11. 在当前 TTY 实际显示二维码后才接受后续成功事件。
12. 等待手机扫码和确认。
13. 验证 container running、Docker health 和 WeChat process 稳定。
14. 验证 auth 为 `logged_in`、chats 可读且非空、messages 可读。
15. 再次确认 WeChat process identity 稳定。
16. 只有全部通过才启动 `wechat-worker`，并确认 running/healthy/heartbeat。

如果新 runtime 的 API 在显示二维码前报告 `logged_in`，不得短路成功；流程必须
fail closed，并保留现场。生产运行每次都必须看到新的二维码。

## 二维码安全

- 二维码只输出到本次受控 TTY。
- 不保存图片或文本文件。
- 不进入 Docker 日志、shell trace、CI artifact、截图、工单或聊天。
- 二维码刷新后只扫描当前终端最后显示的一张。
- 未实际显示 QR 时，`login_success`、`phone_confirm` 或已有 `logged_in` 均无效。
- WebSocket 外部错误必须去除 C0/DEL 控制字符、限制长度并隐藏 Token。
- connect/recv/early-close、invalid JSON、non-UTF8 和 timeout 均返回非零。
- forced production 只接受可先检查 Token 的文本 QR payload；PNG-only
  `qrDataUrl` 必须在打印任何二维码前 fail closed。

## 放行门槛

Docker healthcheck 只证明容器和 Agent API 健康。生产放行还要求：

| 层级 | 通过条件 |
| --- | --- |
| Container | 正式容器 running |
| Docker health | healthcheck 通过 |
| WeChat | canonical executable 与同一 process identity 稳定 |
| Auth | `logged_in` |
| Chats | API 可读且至少一个聊天 |
| Messages | 对 API 返回的一个聊天读取成功 |
| Gateway | `wechat-worker` running/healthy，heartbeat 正常 |

固定 checker 为
`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`，由 Gateway 部署提供。
本仓库只校验并以管理用户身份在 hard timeout 内执行，不创建、修改或通过 `sudo`
执行它；checker 仅以退出码报告当前 Worker heartbeat，且不得输出敏感内容。

任何单项都不能替代完整门槛。验证不得输出账号、聊天 ID 或消息正文。

## 失败语义

任一步失败：

- `wechat-worker` 保持停止；
- 当前失败 runtime 保留或隔离；
- 已有 archive 不删除、不覆盖；
- Token 不输出；本轮已在受控 TTY 显示的二维码不再次回显，也不写入错误、日志或文件；
- 返回非零；
- 修复原因后重新运行完整入口，生成另一套 fresh runtime 和新二维码。

不得执行 UI logout、裸 `docker compose up/restart/down`、旧 session 恢复或数据库修改
来绕过失败。

## 成功输出

成功只报告脱敏状态：

- fresh runtime status；
- archive path；
- container/health/process/auth/chats/messages 结果类别；
- Worker running/healthy/heartbeat 状态。

CFserver Host 按 `Asia/Shanghai` 展示，容器、日志、archive manifest 和原始审计时间
使用 UTC。不要在同一字段中混用时区。

详细故障处理见[故障排查](troubleshooting.md)，实机验收项见
[验证总览](validation.md)。
