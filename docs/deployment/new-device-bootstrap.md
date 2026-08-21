# 新设备部署引导

本路径为兼容旧链接保留。V1 Beta 新 Debian 主机的一次初始化、变量、目录权限、
Compose 启动和自动验证请使用 [Deployment Guide](../deployment-guide.md)。

当前生产基线保留 `data`、`wechat-home` 和 `auth-token`，重启后优先恢复原微信会话。
不要执行旧文档中的 runtime 轮换或 forced-QR 生命周期命令。
