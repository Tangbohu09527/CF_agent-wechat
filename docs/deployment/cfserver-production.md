# CFserver 正式部署

本路径为兼容旧链接保留。当前权威部署说明是
[Deployment Guide](../deployment-guide.md)，恢复说明是
[Recovery Guide](../recovery-guide.md)。

生产 Compose 为 `docker/compose.cfserver.yaml`，恢复策略为 `unless-stopped`。持久化
`data` 和 `wechat-home` 后，容器或主机重启应先尝试恢复会话；只有 `logged_out` 才运行
`scripts/login.sh`。
