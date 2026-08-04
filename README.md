# CF_agent-wechat

## 项目介绍

CF_agent-wechat 是企业 AI 自动化系统的微信入口层。本仓库负责固化
agent-wechat 的部署基线、验证结论和企业集成边界，不包含上游源码，也不承载
AI 推理或企业业务逻辑。

> 当前状态：V1 技术验证已完成。本文中的 `Verified` 仅表示指定测试环境和固定
> 镜像基线已通过验证，不表示生产可用。

## 架构定位

```text
员工微信
    ↓
agent-wechat
    ↓
CF Gateway
    ↓
Hermes Agent
    ↓
Skills（后续阶段）
    ↓
企业系统
```

agent-wechat 负责微信账号运行、消息收发、联系人和聊天管理、图片或文件入口，
以及微信事件转发。它不负责 AI 推理、Skill 执行、ERP 操作或企业业务逻辑。
V1 Staging 已由 CF Gateway 接通微信文本消息、Hermes 调用和微信回复回传；Skills
及企业系统执行仍属于后续阶段。

## 环境要求

已验证基线：

| 项目 | 基线 |
| --- | --- |
| 虚拟化 | VMware Workstation |
| 操作系统 | Debian 13 Trixie |
| Linux kernel | 6.12 |
| 容器运行时 | Docker CE / Docker Engine 29.x |
| Compose | Docker Compose v2 |
| agent-wechat 镜像 | `ghcr.io/thisnick/agent-wechat:0.11.15` |
| 镜像固定方式 | `ghcr.io/thisnick/agent-wechat@sha256:<verified-digest>` |

建议至少提供 2 CPU、2 GB RAM 和 10 GB 可用磁盘。端口、权限和持久化要求见
[Docker 部署手册](docker/README.md)。

## 快速部署

以下命令用于新的 Debian 部署目录。不要把真实 token、`.env` 或运行数据提交到
Git；已有数据恢复时，必须同时恢复 `data/` 和 `secrets/auth-token`，不要生成
新 token。

```bash
cd docker
cp -n .env.example .env
mkdir -p data wechat-home secrets backups
test -z "$(find data -mindepth 1 -print -quit)" && \
  (umask 077; set -o noclobber; openssl rand -hex 32 > secrets/auth-token)

docker pull ghcr.io/thisnick/agent-wechat:0.11.15
docker image inspect --format '{{index .RepoDigests 0}}' \
  ghcr.io/thisnick/agent-wechat:0.11.15
```

将输出的完整 digest 写入 `.env` 的 `AGENT_WECHAT_IMAGE`，然后执行：

```bash
chmod 700 data wechat-home secrets backups
chmod 600 secrets/auth-token
chmod 755 preflight.sh
./preflight.sh
docker compose --env-file .env config
docker compose --env-file .env up -d
```

仓库 Compose 基线仍使用 `restart: "no"`。验证环境的自动恢复结论来自
`restart: unless-stopped`；两者差异和 VNC 修复依赖见
[验证记录](docs/validation.md#运行时配置差异)。

## 验证方式

```bash
docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:6174/health

TOKEN="$(cat secrets/auth-token)"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:6174/api/status/auth
unset TOKEN
```

微信 GUI 登录不等于 agent-wechat 初始化完成。首次初始化必须连接
`/api/ws/login`，完成 login flow，等待 `login_success` 并取得 `userId`；之后才将
联系人、聊天和消息 API 判定为可用。Docker 重启后微信客户端需要重新登录，并应
通过 `/api/status/auth` 复核 `status=logged_in`。完整步骤见
[API 文档](docs/api.md)。

## 当前状态

### Verified

- Debian 13 环境部署、Docker/Compose 启动、镜像 digest 固定和容器健康检查。
- auth-token 配置及 Bearer 认证。
- 宿主机重启后容器、agent-wechat 和 VNC 恢复（验证环境配置）。
- `/api/status/auth` 登录状态查询。
- 按 `chatId` 发送文本，以及包含发送者、内容和时间等字段的消息读取。
- agent-wechat 入口侧 `txt`、`zip` 文件消息识别和 Base64 获取。
- 群消息、发送者、群文件以及文本/文件引用上下文读取。
- 群聊合并转发消息的外层识别、发送者识别和标题读取；内部解析待增强。
- V1 Staging 通过 Gateway Polling 完成“微信文本消息 → 身份与权限准入 → AIThread
  → Hermes → 微信文本回复”闭环。
- Gateway 调用 `POST /api/messages/send` 使用 `{"chatId":"...","text":"..."}`，
  并在 Polling 层过滤自身消息、推进 checkpoint，避免回复回环。

### Pending

- 图片理解、图片附件传递、文件消息端到端处理、OCR 和压缩包内容解析。
- 图片发送与通过 API 发送文件。
- `/api/ws/events` 实时消息事件；连接已建立，但未观察到新消息推送。
- 企业知识库、Skill 自动执行和生产环境自动部署。

agent-wechat 单体能够识别并获取部分文件消息，不表示 Gateway 已完成附件传递、文件
处理或压缩包解析。

### Known Issue

- 默认 VNC 启动状态不稳定，验证环境依赖 `docker/fix-vnc.sh` 和
  `cf-wechat-vnc-fix.service` 恢复 interactive x11vnc。
- 上述 VNC 运维资产尚未纳入当前仓库；重建环境前必须从受控部署记录取得。
- 仓库 Compose 的重启策略与已验证环境存在差异，不能直接据此声明自动恢复。
- Docker 重启后微信客户端需要重新登录。
- 群聊目标上下文应按 `bot + group + sender` 隔离；Gateway V1 当前仍按 whole-room
  聚合，是已知实现偏差，不代表最终上下文模型。

## Roadmap

1. 将 VNC 修复脚本、systemd unit 和 `unless-stopped` 策略纳入正式变更评审。
2. 验证图片/API 文件发送，并调查 WebSocket 未推送新消息事件的问题。
3. 收口 CF Gateway 群聊上下文键、消息契约、幂等、重试和审计边界。
4. 完成备份恢复演练、版本升级回退演练和长期稳定性验证。
5. 在已接通 Hermes 文本链路的基础上逐步建设 Skills，并保持企业业务逻辑在入口层
   之外。

## 文档

- [文档索引](docs/README.md)
- [架构设计](docs/01_架构设计.md)
- [部署记录](docs/02_部署记录.md)
- [V1 验证结果](docs/05_V1验证结果.md)
- [V1 回归矩阵](docs/validation.md)
- [API 文档](docs/api.md)
- [故障排查](docs/troubleshooting.md)
- [运维与交接](docs/operations.md)

上游项目：<https://github.com/thisnick/agent-wechat>。上游源码不属于本仓库；使用
前应独立确认其许可证和授权条件。
