# CF_agent-wechat

`CF_agent-wechat` 是企业 AI 自动化系统的**微信入口层**。它在 CFserver 上运行
WeChat Linux 客户端与 agent-server，管理微信登录和本地运行态，并向上层调用方提供
健康、认证、聊天和消息接口。

本项目**不是 Gateway**，不负责任务调度、AI 推理、业务编排、权限决策或企业系统
逻辑。Gateway 是本项目的调用方；本项目只在 forced-QR 生命周期中控制其
`wechat-worker` 的停止与放行，不维护 Gateway 的代码、数据库或启动策略。

> [!WARNING]
> forced-QR、`runtime/session-archive` 和 worker 闸门仅适用于本仓库
> `feat/forced-qr-login@9cb7163` 及其后续合入版本。该流程已完成本地自动化验证，
> 尚未完成 CFserver 真实手机扫码与 Debian 启动窗口验证；本文审计的 `main` 代码基线为 `96264e2`，
> 不包含这些入口，不得按目标流程命令运行。仅合入本文档不会获得运行能力。

## 项目职责

本项目负责：

- 运行容器内 Xvfb、fluxbox、dunst、WeChat Linux 客户端和 agent-server；
- 管理微信登录、运行目录轮换、历史会话归档和登录状态检查；
- 在完整健康、进程、认证、聊天和消息验证通过后放行 `wechat-worker`；
- 提供 `/health`、认证、聊天、消息和 media 接口边界；
- 维护本项目的部署、运维、验证和故障排查文档。

本项目不负责：

- Gateway 内部身份、权限、路由、轮询或任务调度；
- Hermes 或其他 AI 服务的推理与上下文管理；
- Skills、ERP 或其他企业业务逻辑；
- 宿主机整体备份平台、归档到期删除或外部监控系统。

## 状态口径

| 状态 | 定义 |
| --- | --- |
| **已完成** | 本仓库目标分支存在可执行实现；不等于已在 CFserver 实机通过 |
| **已验证** | 必须注明“自动化验证”或“CFserver 实机验证”，二者不能互相替代 |
| **未验证** | 实现可能存在，但当前缺少对应现场证据 |
| **后续规划** | 尚未完成的合入、现场验收或运维治理工作，不得写成现有能力 |

### 已完成

| 能力 | 实现边界 |
| --- | --- |
| forced-QR 启动 | `start-qr-login.sh` 编排全新 runtime，内部调用 `login.sh --force-qr` 和 `newAccount=true` |
| runtime/archive 保护 | 旧 runtime 原子移入唯一 UTC 归档；不覆盖历史；Token 独立；mixed layout fail-fast |
| 停止入口 | `stop-qr-runtime.sh` 先停 worker、再停入口容器，不删除 runtime、Token 或归档 |
| worker 闸门 | 脚本取得控制后先停 `wechat-worker`；进程、auth、chats、messages 全部通过后才启动 |
| 失败隔离 | 轮换后的失败保持 worker 停止并尝试 stop/remove 入口容器；不主动删除持久数据 |

以上“已完成”仅指 `feat/forced-qr-login` 目标实现，不表示这些入口已存在于当前
`main`。

### 已验证

- **自动化验证：** forced-QR 参数、实际 QR 渲染门槛、runtime/legacy 归档、不覆盖、
  mixed layout、独占锁、失败清理、状态判定和 worker 放行顺序已由本仓测试覆盖。
- **历史 CFserver 实机验证：** 2026-08-13 验证了当时基线的容器、无 VNC 链路、
  已信任设备手机确认、状态管理及 Gateway 对四个入口端点的访问。
- **历史 CFserver 实机验证：** 2026-08-14 验证了文本发送、群消息字段、引用结构和
  图片 media 读取。

历史证据不能外推为新的 forced-QR 生命周期已经现场通过。

### 未验证

- 全新 runtime 在 CFserver 上完成“SSH 显示 QR -> 手机扫码/确认 -> API 就绪 ->
  worker 放行”的真实闭环；
- Debian 启动到人工运行脚本之前，外部 `wechat-worker` 持续停止的 boot/restart gate；
- forced-QR 模式的 legacy 首次迁移、mixed layout、失败 cleanup 和重复归档现场行为；
- 新模式的长期稳定性、停机窗口消息补拉、图片发送和文件发送。

### 后续规划

1. 将 forced-QR 实现整合到经批准的生产代码提交，并保留可追溯版本。
2. 按 [验证总览](docs/validation.md) 在 CFserver 完成脱敏实机验收。
3. 由外部运维策略确定归档容量监控、保存期限、访问控制和审批删除流程。

## 目标生产流程

```text
Debian 启动
  -> SSH 登录 CFserver
  -> start-qr-login.sh 停止并确认 wechat-worker
  -> 归档旧 runtime，创建全新 data/wechat-home
  -> 启动 cf-agent-wechat
  -> SSH 终端显示全新二维码
  -> 手机扫码和确认
  -> 验证 WeChat 进程、auth、chats、messages
  -> 全部通过后启动 wechat-worker
```

Gateway 通过外部 Docker 网络 `cf-internal` 调用：

```text
http://cf-agent-wechat:6174
```

容器内生产链路使用 `DISPLAY=:99`、Xvfb `1280x800x24` 和 `ENABLE_VNC=0`。
VNC、noVNC、x11vnc、websockify、宿主 X11、XFCE 和 RDP 都不属于目标生产方案。

## 快速部署入口

1. 先确认批准代码具备 forced-QR 入口；任一检查失败都停止部署：

   ```bash
   cd /opt/cf-agent-wechat
   test -x scripts/start-qr-login.sh
   test -x scripts/stop-qr-runtime.sh
   test -f scripts/qr-runtime-common.sh
   grep -q 'on-failure:3' docker/compose.cfserver.yaml
   grep -q 'CF_AGENT_WECHAT_RUNTIME_ROOT' docker/compose.cfserver.yaml
   ```

2. 全新主机按 [新设备部署引导](docs/deployment/new-device-bootstrap.md) 准备 Docker、
   目录、Token、环境输入和调用方控制边界。

3. 部署前预览；dry run 不应修改容器、worker、runtime、归档或锁：

   ```bash
   ./scripts/start-qr-login.sh --dry-run
   ```

4. 在维护窗口正式启动并扫描 SSH 终端中的最新二维码：

   ```bash
   ./scripts/start-qr-login.sh
   ./scripts/status.sh
   ```

5. 停止入口时使用：

   ```bash
   ./scripts/stop-qr-runtime.sh
   ```

不要用裸 `docker compose up`、`restart` 或 `down` 代替生命周期脚本。完整契约见
[CFserver 正式部署](docs/deployment/cfserver-production.md)。

## 文档入口

- [文档索引](docs/README.md)
- [项目说明](docs/00_项目说明.md)
- [架构设计](docs/01_架构设计.md)
- [新设备部署引导](docs/deployment/new-device-bootstrap.md)
- [CFserver 正式部署](docs/deployment/cfserver-production.md)
- [微信登录管理](docs/login-management.md)
- [API 边界](docs/api.md)
- [生产运维](docs/operations.md)
- [故障排查与常见问题](docs/troubleshooting.md)
- [验证总览](docs/validation.md)
