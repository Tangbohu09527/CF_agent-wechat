# 运维与交接

## 适用基线

本手册适用于 Debian 13 Trixie、Docker Engine 29.x、Docker Compose v2 和
`ghcr.io/thisnick/agent-wechat:0.11.15` 的已验证 digest。任何基线变化都需要重新
执行 [V1 验证记录](validation.md) 中的回归检查。

## 日常检查

```bash
cd ~/docker/agent-wechat
docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:6174/health
docker compose --env-file .env logs --tail=200 agent-wechat
```

检查项：

- 容器为 `healthy`，没有持续重启。
- 6174 只绑定在预期地址，默认应为 `127.0.0.1`。
- 磁盘空间、`data/` 和 `wechat-home/` 增长处于可控范围。
- 日志没有数据库、微信进程、Xvfb 或 x11vnc 持续错误。
- API session 状态符合预期；GUI 状态不能替代 API 状态。
- 验证环境中 `cf-wechat-vnc-fix.service` 正常。

## 安全边界

- 6174 提供 HTTP/WebSocket，不包含 TLS；远程访问使用 SSH 隧道。
- auth-token 权限保持 `600`，父目录保持 `700`。
- Docker daemon 或 `docker` 组访问按宿主机 root 级权限管理。
- 日志、工单和提交不得包含 token、二维码、联系人、消息正文或媒体。
- `data/`、`wechat-home/` 和备份按企业敏感数据要求控制访问与保留期。

## 备份

### 备份单元

以下内容必须属于同一个有版本和时间点的备份集：

- `data/`
- `wechat-home/`
- `secrets/auth-token`
- 去敏后的部署元数据：镜像 tag、完整 digest、Compose 版本和备份时间

`data/` 与 `secrets/auth-token` 不能拆分恢复。token 同时用于 API 认证和数据库
加密，已有数据时不得随意重新生成。

### 建议流程

1. 记录容器、镜像 digest 和 session 状态。
2. 在批准的维护窗口停止容器，避免数据库和微信数据在复制过程中继续写入。
3. 以同一时间点复制三个备份对象。
4. 对备份加密、计算校验值并限制访问。
5. 启动容器，复核健康、session 和消息读取。
6. 定期在隔离环境执行恢复演练；未恢复验证的备份不能视为可用。

## 恢复

1. 确认目标镜像 digest 与备份元数据一致。
2. 停止容器并确认目标目录无并发写入。
3. 同时恢复 `data/`、`wechat-home/` 和原 `secrets/auth-token`。
4. 恢复正确属主与权限，不使用全局可写权限绕过。
5. 运行 `./preflight.sh` 和 `docker compose --env-file .env config`。
6. 启动后验证 `/health`、`/api/ws/login` session、联系人、聊天和消息。
7. 在验证环境配置下复核 VNC 修复服务。

不要在恢复失败时删除 `agent.db` 或生成新 token 后反复尝试；先保留现场并查看
容器日志。

## 重启与 VNC

已验证环境使用 `restart: unless-stopped`，并使用
`cf-wechat-vnc-fix.service` 调用 `docker/fix-vnc.sh`。仓库当前 Compose 和文件
清单没有完整包含这套运行逻辑，属于 `Known Issue`。

宿主机重启验收应同时检查：

```bash
docker ps
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' cf-agent-wechat-lab
systemctl status cf-wechat-vnc-fix.service
curl --fail --silent --show-error http://127.0.0.1:6174/health
```

随后实际访问 noVNC，确认画面和鼠标键盘交互。端口可达不能替代交互验收。

## 版本升级与回退

1. 阅读上游变更并确认授权、数据迁移和兼容性风险。
2. 在隔离环境拉取明确 tag，解析并记录 digest。
3. 备份当前数据、token、镜像 digest 和部署元数据。
4. 将候选 digest 写入测试环境，不使用 `latest`。
5. 执行完整 V1 回归，并单独验证 VNC 和宿主机重启。
6. 通过评审后再安排正式环境变更。
7. 回退必须同时考虑镜像和数据格式；不能只切换镜像而忽略数据库迁移。

## 事件处理

发生登录、消息或数据异常时：

1. 记录时间、镜像 digest、容器状态和去敏日志。
2. 避免多次重启、重新扫码或替换 token，以免破坏现场。
3. 按 [故障排查](troubleshooting.md) 区分容器、VNC、GUI 和 API session。
4. 涉及数据恢复时先制作现场副本，再执行恢复流程。
5. 事件关闭后更新验证记录和 Known Issue。

## 交接清单

- [ ] 私有部署记录含主机责任人、完整镜像 digest 和变更历史。
- [ ] auth-token 的保管、访问、备份和恢复责任人明确。
- [ ] 数据目录、备份位置、保留期和恢复演练结果明确。
- [ ] 6174 未暴露公网，远程访问方式已交接。
- [ ] `restart: unless-stopped` 与仓库 Compose 差异已说明。
- [ ] `docker/fix-vnc.sh` 和 `cf-wechat-vnc-fix.service` 的受控来源已说明。
- [ ] 微信账号登录、session 初始化和异常处置责任人明确。
- [ ] Pending 能力没有被写入对外承诺。
- [ ] CF Gateway / Hermes 尚未接入的边界已说明。
