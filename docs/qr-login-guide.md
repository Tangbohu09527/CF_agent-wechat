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
3. Bootstrap 已完成；但脚本仍会重新核验 systemd/docker.service、local rootful
   default Docker、socket、`live-restore=false`、auto-start unit 和 Compose。
4. Gateway 固定 `worker` service 可停止，contract v1/checker 与 Agent Token 一致。
5. 固定 `docker/.env`、Runtime 精确权限、Archive 容量/inode、树扫描、Hash 锁定 QR
   venv 和管理锁合同可通过。
6. 调用进程没有 API/WS、Token/session、Agent/Compose/Proxy、Python、Runtime 或 Gateway
   管理覆盖；生产设置这些变量会在任何网络请求前被拒绝。
7. 终端、录屏、日志采集和 CI 不会捕获二维码。

## 权威状态机

`start-qr-login.sh` 必须按顺序：

1. 校验用户/TTY，拒绝生产环境覆盖，安全读取固定 `docker/.env`，由批准 loopback/port
   派生 API/WS；Token path 与 session 固定。
2. 重新校验 systemd、docker.service、local rootful default Docker、socket、
   `live-restore=false`、auto-start unit、`cf-internal`、Gateway contract 和 clean
   Compose 精确 attestation。
3. 精确校验现有 Runtime/legacy UID/GID/mode，并完成 no-follow、no-cross-filesystem、
   有界特殊文件/Token 树扫描；目录项名称也检查 Token，任何 xattr/POSIX ACL 都拒绝。
4. 获取 owner/group/mode/link 合规的 `0640` 独占管理锁。
5. 停止并确认 Gateway `worker`。
6. 校验 Archive bytes/percent/inode 并输出 inventory；失败时 Worker 保持停止。
7. 验证固定 Python、仓库 Hash lock 与 passwd home QR venv；必要时有界事务式重建。
8. 把 root-only Token 读入当前进程内存。
9. 停止并移除旧 Agent 容器，不删除 bind 数据；原子归档旧 Runtime，写 schema v2 manifest。
10. 始终以批准 UID/GID/mode 创建全新的 `runtime/data` 和 `runtime/wechat-home`。
11. 使用 `restart: "no"` 创建容器，并精确 attest 实际 image/name/project、
    RestartPolicy、mount、loopback port、alias 和 environment。
12. 等待 container running、Docker health、Agent API 和 WeChat process identity 稳定。
13. 请求 `newAccount=true` fresh QR；当前 TTY 实际显示后才接受后续成功事件。
14. 等待手机扫码，在有界窗口验证同一 process、auth=`logged_in`、chats 非空和 messages。
15. 只有全部通过才启动 Gateway `worker`；contract checker 在稳定窗口内持续无输出
    且返回 0 后才成功。

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
| Gateway | `worker` running/healthy；contract checker 确认 heartbeat/Poll/auth |

固定 contract/checker 为
`/opt/cf-agent-gateway/deploy/wechat-runtime-contract.json` 和
`/opt/cf-agent-gateway/deploy/check-wechat-worker-heartbeat`，必须由兼容 Gateway
commit 部署。checker 由管理用户无参数执行，不使用 `sudo`；只有 10 秒内无输出且
确认当前 `worker` running/healthy、30 秒内 heartbeat、最新 Poll Cycle 成功和
auth=`logged_in` 才通过。stale、失败、超时或输出内容时脚本撤销 Worker 放行并保留
Agent/Archive 现场。当前 PR #4 尚不兼容，状态为 **BLOCKED BY GATEWAY CONTRACT**。

任何单项都不能替代完整门槛。验证不得输出账号、聊天 ID 或消息正文。

## 失败语义

任一步失败：

- `wechat-worker` 保持停止；
- 当前失败 runtime 保留或隔离；
- 已有 Archive 不删除、不覆盖；它按 `restricted` 敏感资产保留，不挂回生产；
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

Archive schema、容量/inode、inventory/retention 见[Archive Management Contract](archive-management.md)。
详细故障处理见[故障排查](troubleshooting.md)，实机验收项见
[验证总览](validation.md)。
