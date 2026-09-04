# QR Login Guide

本文面向在 CFserver 交互式 SSH TTY 中执行 fresh QR 的 Operator。完整生命周期语义见
[微信登录生命周期](login-management.md)。

## Before starting

1. 确认当前是受控 SSH TTY，stdin/stdout 都连接终端，宽度足以显示二维码。
2. 关闭录屏、终端日志和会捕获二维码的会话共享。
3. 确认没有其他 start/stop 操作持有运行锁。
4. 若刚发生 CFserver reboot，先按
   [Host reboot recovery](deployment/cfserver-production.md#cfserver-reboot-recovery)
   显式执行 Controller `stop` 并确认。
5. 不读取 `.env`、Token 或旧 Archive 内容。

可选预览：

~~~bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh --dry-run
~~~

Dry run 不获取锁，也不改容器、Worker 或目录。

## Start and scan

~~~bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh
~~~

保持终端打开：

1. 等待脚本完成 Contract、Gate、旧容器、Archive 和 fresh Runtime 操作。
2. 等待 Docker health、Agent Server 与 WeChat 进程稳定。
3. 看到“请使用手机微信扫描二维码”后扫描终端中**最后显示**的二维码。
4. 在手机上确认登录。
5. 等待脚本完成 auth、chats、messages 和 Gateway Controller 验证。
6. 脚本返回 `0` 后运行 `./scripts/status.sh`。

不要截图、保存、转发或复制二维码内容。

## QR acceptance rules

- fresh start 的 HTTP 与 WebSocket 均使用 `newAccount=true`。
- 当前 WebSocket 必须实际提供并渲染至少一个 QR。
- `phone_confirm` 只表示需要手机确认，不是最终成功。
- 未显示 QR 的 `login_success` 会被拒绝。
- existing `logged_in` 不会绕过 fresh start。
- 文本 `qrBinaryData` 与 `qrData` 会在渲染前检查 Token。
- PNG-only `qrDataUrl` 当前必须 fail closed，不允许保存图片后手工扫码。
- WebSocket connect/recv/early-close、invalid JSON、non-UTF8、timeout 和 error 均失败。

## Readiness after phone confirmation

脚本不会在 `login_success` 后立即放行。它继续确认：

- `/usr/bin/wechat` 仍是同一 `PID:start_time`；
- Auth 为 `logged_in`；
- chats 可读且至少有一个聊天；
- 对 API 返回的一个聊天读取 messages 成功；
- 最终 WeChat 进程身份未被替换；
- Gateway ready、Token Contract、Poll/Delivery health 全部通过。

默认登录总时限为 `LOGIN_TIMEOUT_MS=300000`，登录后 API 就绪窗口为
`POST_LOGIN_READY_TIMEOUT=120` 秒。超时保持 fail closed。

## Success

成功输出只包含脱敏结果类别和 Archive path。随后：

~~~bash
./scripts/status.sh
~~~

只有 11 项状态全部通过且退出码为 `0`，才恢复业务消息。Docker health 或
`logged_in` 单项都不够。

## Failure

1. 记录退出码、失败 phase 和脱敏 Archive path。
2. 不手工启动 Gateway Worker，不执行裸 Compose restart/up/down。
3. 不删除 Runtime、Archive 或锁文件，不恢复旧 Session。
4. 等待当前流程结束并释放锁。
5. 按 [Recovery Guide](recovery-guide.md) 处理根因后，重新运行完整 fresh QR。

失败中已经显示过的二维码不得再次回显到日志或工单。只记录时间、Commit、状态类别和
退出码。
