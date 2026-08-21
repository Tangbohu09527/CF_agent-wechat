# 微信登录管理

本路径为兼容旧链接保留。首次扫码、重启后会话判定和重新登录流程请使用
[QR Login Guide](qr-login-guide.md)。

当前生产策略是优先恢复持久会话。`scripts/status.sh` 返回需要登录后才运行
`scripts/login.sh`；不要在每次重启时强制生成新二维码。
