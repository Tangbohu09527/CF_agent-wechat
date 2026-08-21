# 验证总览

本文记录当前 V1 Beta 持久 session 基线的自动化证据、历史生产证据和仍需在
CFserver 完成的现场验收。当前生产操作以 [Deployment Guide](deployment-guide.md)、
[Recovery Guide](recovery-guide.md) 和 [QR Login Guide](qr-login-guide.md) 为准。

## 状态口径

| 标签 | 含义 |
| --- | --- |
| 已实现 | 当前分支存在对应代码；不等于真实 CFserver 已通过 |
| 自动化通过 | 本地或 CI 使用 mock/静态输入验证了可重复行为 |
| 历史实机证据 | 只证明带日期记录中的旧 Commit、镜像和环境 |
| 待实机验证 | 必须在目标 Debian、Docker、镜像和真实手机上执行 |

自动化测试不能证明真实 WeChat 客户端、Docker daemon 开机行为、手机扫码或长期
session 稳定性。历史证据也不能外推到新的 bootstrap 和恢复实现。

## 当前自动化

| 范围 | 命令 | 覆盖 |
| --- | --- | --- |
| 部署与 runtime | `bash tests/deployment/bootstrap_cfserver.sh` | 三个 ROOT、权威文件、systemd、首次初始化、幂等恢复、Docker/Compose 硬超时、mount/restart/network 和 health/auth 失败门禁 |
| 生产 Compose 恢复 E2E | `bash tests/integration/production_compose_recovery.sh` | 生产 Compose 加 mock-agent override，在真实 Docker 上验证 health、network、mount、认证 API，以及进程异常退出、容器 restart/recreate 后的 runtime/session 保持 |
| 重启与 session | `bash tests/integration/session_recovery.sh` | container/health/API 恢复、state/health inspect 总预算、`logged_in` session 复用、登录等待态和 QR 分支 |
| fresh QR | `python3 -m unittest -v tests/unit/test_qr_login.py` | `newAccount=true`、嵌套 QR、必须实际渲染 QR、token/控制字符清理 |
| 权限边界 | `tests/integration/login_management_permissions.sh` | root-only Token、普通用户管理脚本、受控 sudo、venv 所有权和 token 防泄漏；仅在隔离 CI 运行 |

CI 入口为 `.github/workflows/deployment-hardening.yml` 和
`.github/workflows/login-management-permissions.yml`。部署测试使用 fake Docker/curl
验证 bootstrap 编排和失败语义；真实 Compose 渲染门禁在 Docker Compose v2 上运行，
production Compose recovery E2E 使用真实 Docker daemon 和 mock agent API 容器验证重启与
重建。该 E2E 只能在隔离 Docker daemon 上运行；因为生产 Compose 使用固定外部网络名
`cf-internal`，测试发现该网络已存在时会明确拒绝运行，绝不复用或删除已有网络。
mock 容器不包含真实微信客户端，因此不能替代 CFserver 现场验收。

### 自动化已证明

- bootstrap 缺少 Docker/Compose 时在创建 env、runtime 或 Token 前失败；
- 首次运行原子创建 env 和 Token，重复运行不替换 Token 或 session marker；
- 已有数据缺少原 Token 时拒绝生成替代 Token；
- 固定代码根、`docker/`、Compose 和 env 的 owner/mode/type 不受批准或存在额外硬链接时
  fail closed；env 缺失时管理脚本不接受进程变量替代；
- systemd 不活跃或 `docker.service` 未启用时，bootstrap 在部署变更前失败；
- Docker/Compose metadata、启动和 state/health inspect 均有硬上限，轮询中的查询还受
  当前阶段剩余总预算约束；
- 生产容器必须为 running/healthy、`restart: unless-stopped`，且三项 bind mount 指向
  同一持久根；
- health 或认证 API 无法恢复、返回无效 JSON、挂载错误或 restart policy 错误时失败；
- 生产 Compose 的真实容器在 PID 1 异常退出自动恢复、显式 restart 和 force-recreate 后仍使用原 bind
  runtime、只读 Token、`cf-internal` alias 和 `unless-stopped`，且 mock auth API 继续返回
  `logged_in`；
- `status.sh --wait` 可观察 stopped/starting 到 running/healthy，以及 API 从不可用到
  可用的恢复过程；
- auth 为 `logged_in` 时 `login.sh` 不调用 POST 或 WebSocket；
- auth 需要登录时 fresh QR 只使用 `newAccount=true` WebSocket，不让旧 HTTP QR 满足
  证据门槛；当前 TTY 没有成功渲染本次新 QR 时拒绝 `login_success`；
- 非 TTY、终端过窄、空白/无效 QR 和并发登录都 fail closed；
- 默认 root-only Token 的 sudo 读取范围固定，不接受任意自定义路径；
- 状态和登录输出不打印账号或 Token。

## 历史生产证据

- [2026-08-13 CFserver 生产验证](validation/2026-08-13-cfserver-production.md) 证明当时
  Commit 上的容器、无 VNC 链路、已信任设备手机确认、基础认证与内部网络 API。
- [2026-08-14 消息与媒体生产验证](validation/2026-08-14-message-media-production.md)
  证明当时 Commit 上的文本发送、群消息字段、引用结构和图片 media 读取。

这两份记录不是当前 bootstrap、主机重启恢复或 fresh QR 的现场证据。旧实验和候选
生命周期文档中的命令均不得作为当前 runbook。

## CFserver 验收

发布前应在维护窗口建立一份新的、带日期的脱敏记录。

### 主机与部署

- [ ] 记录代码 Commit、批准的镜像 digest、Debian、Docker Engine 和 Compose 版本。
- [ ] 确认 Docker daemon 已启用开机启动，磁盘和时间同步正常。
- [ ] 使用标准路径或完整记录三个 ROOT 覆盖，执行一次 bootstrap。
- [ ] 确认 container running、Docker health healthy、`/health` 和 auth API 可读。
- [ ] 确认实际 mount source、`unless-stopped` 和 `cf-internal` 网络。
- [ ] 确认生产无 x11vnc/websockify，6174 只绑定批准的 loopback 地址。

### 重启恢复

- [ ] 在 `logged_in` 基线上重启 `agent-wechat` 容器，运行 `status.sh --wait`。
- [ ] 确认 `data`、`wechat-home` 和原 `auth-token` 未替换，session 无需扫码即可恢复。
- [ ] 重启 Docker daemon，再次确认 container、health、API 和 session。
- [ ] 重启 Debian，确认 Docker 自动启动服务并重复同一验证。
- [ ] 验证人工 `stop` 后 `unless-stopped` 不会违背停止意图，bootstrap 可明确恢复服务。

### QR 登录

- [ ] 在全新部署或 auth 明确需要登录时运行 `login.sh`。
- [ ] SSH 终端实际显示 fresh QR，手机扫描并确认。
- [ ] 确认脚本收到成功事件后再次验证 auth 为 `logged_in`。
- [ ] 验证一次 QR 超时或中断，确认非零退出且持久数据不被删除。

### 数据恢复

- [ ] 使用同一时点的 `data`、`wechat-home` 和原 `auth-token` 做一致备份。
- [ ] 在隔离演练中恢复完整集合，运行 bootstrap 和 `status.sh --wait`。
- [ ] 确认已有数据缺 Token、错误权限和错误 mount 都安全失败。
- [ ] 验证备份加密、访问控制、保留期和删除审批由外部平台落实。

## 记录规则

现场记录只包含时间、Commit、镜像 digest、版本、脱敏状态、返回码和耗时。不得记录
Token 或指纹、二维码、微信账号、联系人、聊天 ID、消息正文、媒体、服务器地址、
API Key、密码或数据库内容。

以下变化需要重新建立现场证据：镜像 digest、Compose/restart policy、runtime 路径或
权限、Token 挂载、登录参数、health/auth API、Docker/系统版本及备份恢复方式。
