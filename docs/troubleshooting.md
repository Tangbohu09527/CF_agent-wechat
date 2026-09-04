# CFserver 生产故障排查

固定格式：Symptom -> Read-only checks -> Likely classification -> Safe action ->
Verification -> Do not do。详细恢复步骤见 [Recovery Guide](recovery-guide.md)。

## Troubleshooting matrix

| Symptom | Read-only checks | Likely classification | Safe action | Verification | Do not do |
| --- | --- | --- | --- | --- | --- |
| start refuses non-TTY | 检查 stdin/stdout 是否为当前 SSH TTY | 交互门禁按设计生效 | 在受控交互式 SSH 会话重跑 | QR 可在当前终端显示 | 不用 CI、重定向或后台任务绕过 |
| QR not displayed | 看脱敏事件类别、终端宽度和流程 phase | 无 QR payload、终端过窄或连接失败 | 修复终端/上游事件后完整重跑 | 当前 WebSocket 实际渲染 QR | 不接受仅有 `login_success` |
| PNG-only QR rejected | 错误包含图片型二维码拒绝 | 生产 Token 审计门禁 | 修复上游为文本 `qrData`/`qrBinaryData` | 文本 QR 在输出前通过检查 | 不保存 PNG、不降级绕过 |
| `login_success` before QR | 确认当前 WebSocket 未渲染 QR | 事件顺序不可信 | 保留错误，完整重跑 | QR 先显示，再成功 | 不使用 HTTP/旧 QR 作为凭据 |
| container healthy but status fails | 查看 11 项状态 | Docker health 只证明 `/health` | 按失败层处理 | status 退出 `0` | 不把 healthy 当生产在线 |
| WeChat process absent | `WeChat Process=not_running` | 上游客户端/Xvfb/资源故障 | 保留日志后 fresh QR | 同一 `PID:start_time` 稳定 | 不按进程名宽松匹配 |
| WeChat process replaced | `exited_or_replaced` | PID identity 变化 | fresh QR，查客户端崩溃 | 登录前后身份一致 | 不只比较 PID 或 cmdline |
| Auth logged_out | status 退出 `2` | 当前 Runtime 未登录 | 完整 fresh QR | Auth + chats/messages + Gateway | 不只 POST login、不 UI logout |
| chats empty/unreadable | Auth 可能 logged_in | 假可用或上游 API 未就绪 | fresh QR 或按上游故障排查 | chats 非空 | 不硬编码 Chat ID |
| messages API unreadable | chats 有 ID，messages 校验失败 | 生产就绪未闭环 | 保持 Gate 关闭，完整重跑 | 对 API 返回聊天读取成功 | 不跳过 messages 门槛 |
| controller stop failure | Controller 返回非零/无 `stopped=true` | Gate 状态未知 | 停止操作，交 Gateway 运维 | stop 明确确认 | 不继续删容器/移 Runtime |
| controller start/status failure | Agent 已就绪但 Gateway 未 ready | Gateway Contract/Worker 故障 | 保持/恢复 stop，交 Gateway 运维 | ready/token/Poll/Delivery 全过 | 不手工启动 service |
| Poll/Delivery health failure | status 中任一非 healthy | Gateway readiness 失败 | 通过正式 Controller 处理 | 两项均 healthy | 不把 Dispatch 或 DB 改动写进本仓流程 |
| Token Contract invalid | Gateway token 状态 false | Agent/Gateway 文件契约不一致 | 保持 Gate 关闭，按双方契约修复 | `token_contract_valid=true` | 不打印/复制/轮换 Token 猜测修复 |
| Token metadata invalid | 仅 `stat` 查 type/owner/mode/link | 文件安全契约偏离 | 保留文件，离线修复后 Bootstrap | 当前 Token 契约通过 | 不 `cat`、hash、`chmod 644` |
| runtime mixed layout | 同时存在 Runtime 与 legacy path | 来源不明确 | 保留现场，确认受控来源后处理 | 校验不再 mixed，再 Bootstrap/start | 不自动合并或删除 |
| Archive scan failure | 查看失败 phase、路径类型和权限 | tree 中疑似 Token/特殊文件或扫描超时 | 保留源目录，安全调查 | Token scan 成功后才归档 | 不跳过 scan |
| failed Archive manifest | 只读看 result/phase/cleanup | 前次流程失败证据 | 保留旧 Archive，修复后新流程 | 新 Archive 成功且旧证据仍在 | 不改写历史 manifest |
| Agent stays stopped after reboot | `restart=no`，container stopped | **预期行为** | 先关闭 Gate，再 fresh QR | status 全过 | 不改为自动 restart |
| Workers running while Agent offline after reboot | Controller status 显示 running/healthy | automatic boot stop gate 未实现/证明 | 立即 Controller `stop --timeout-seconds 30`，再 fresh QR | stop 已确认，最终 status 全过 | 不假设稍后脚本 stop 已足够 |
| proxy rejected | 查看脱敏配置错误，不打印值 | scheme/host/port 或 userinfo/query 不合规 | 改为允许的无认证 URL 或空值，重跑 Bootstrap | 配置验证通过 | 不记录代理凭据 |
| Docker socket/context/live-restore invalid | 检查 fixed socket、default context、endpoint、rootless、live-restore | Host 不符合生产契约 | 修复 Host 配置后重跑 Bootstrap | local rootful/default，live-restore false | 不覆盖到 remote daemon |
| lock already held | 确认是否有活动 start/stop；锁文件可为空 | 并发操作 | 等待现有流程结束 | 后续操作取得锁 | 不因文件存在就删除锁 |
| failed cleanup cannot remove container | 查看 stop/remove 脱敏结果和 container state | 残留容器可能在 | 保留现场，人工确认 stopped/absent | 状态明确后才重试 | 不先重启 Docker/Host |
| logs rotate too fast | 查看 Agent 日志时间范围与 `20m × 3` 配置 | 日志量过大或采集不足 | 降低允许的日志级别，接入外部受控采集 | 关键失败窗口可追踪且无敏感信息 | 不误写成 Gateway `64m × 10` |
| disk growth in session-archive | `du -sh`、目录数量、文件系统剩余空间 | Archive 不自动清理 | 按外部保留/审批策略处置 | 容量恢复且审计要求满足 | 不在本仓提供自动删除命令 |

## Safe read-only commands

~~~bash
cd /opt/cf-agent-wechat
./scripts/status.sh

sudo -v

sudo -n docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  --project-name cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  ps

sudo -n docker compose \
  --env-file /opt/cf-agent-wechat/docker/.env \
  --project-directory /opt/cf-agent-wechat \
  --project-name cf-agent-wechat \
  -f /opt/cf-agent-wechat/docker/compose.cfserver.yaml \
  logs --tail=200 agent-wechat

sudo -n stat -c '%F %u:%g:%a:%h %n' \
  /srv/storage/cf-agent-wechat/secrets \
  /srv/storage/cf-agent-wechat/secrets/auth-token
~~~

不要输出完整 Compose render 或 `.env`。日志、工单和截图不得包含 Token、
Authorization、二维码、账号、联系人、群名、Chat ID、消息正文、内网 IP 或数据库 URL。

## Common questions

### 容器 healthy 是否等于生产在线？

不等于。还要验证真实 WeChat 进程、Auth、fresh Runtime、chats/messages，以及
Controller ready、Token Contract、Poll/Delivery health；以 11 项 status 和退出码为准。

### 可以恢复旧 Archive 或改用 VNC 吗？

不可以。Archive 只保留证据，不能恢复为 active Session；VNC/noVNC、Host X11、XFCE
和 RDP 不属于当前生产路径。

### 登录失败后可以手工启动 Worker 吗？

不可以。Controller 是 Poll/Delivery 唯一入口；只有完整 Agent/API 验证后才允许
`start/status`，失败时先确认 `stop`。

### Agent 正常但没有 AI 回复，应重新登录吗？

不应先重建 Agent。若 11 项状态通过，问题转交 Gateway/Hermes；本仓库不处理其内部
Admission、Checkpoint、Dispatch、Response 或 Delivery Receipt。

## Incident reporting minimum

只记录 UTC 时间、源码 Commit、批准镜像引用或现场 Image ID、脱敏 11 项状态、脚本
退出码和 Archive path。不得附带 Token 或指纹、二维码、账号、联系人、Chat ID、正文、
media、服务器地址、API Key、密码、`.env` 或数据库内容。
## Layer ownership

- Agent/container/WeChat/auth/chats/messages/Runtime：本仓库运维边界。
- Controller ready、Token Contract、Poll/Delivery health：Gateway Runtime Contract
  交界面。
- 去重、Admission、Checkpoint、Dispatch、Response、Delivery Receipt：Gateway。
- Hermes 连通性、推理和 Skills：Hermes/下游系统。

Agent 11 项状态全部通过但无 AI 回复时，转交 Gateway/Hermes；不要通过重建 Agent
尝试修复外部系统。
