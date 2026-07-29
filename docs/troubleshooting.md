# 故障排查

## 排查顺序

先确认容器健康，再确认 agent-wechat session，最后确认具体业务 API。VNC 只用于
登录和诊断，不能代替 API 状态判断。

```bash
docker compose --env-file .env ps
curl --fail --silent --show-error http://127.0.0.1:6174/health
docker compose --env-file .env logs --tail=200 agent-wechat
```

## 1. GUI 已登录，但 API 显示 logged_out

### 现象

微信 GUI 已经登录，但 `/api/status/auth` 显示 `logged_out`。

### 原因

微信 GUI 状态和 agent-wechat session 状态不是同一个状态源。GUI 登录成功不代表
agent-wechat 已完成自己的登录初始化和用户绑定。

### 处理

1. 连接 `/api/ws/login`。
2. 执行完整 login flow。
3. 等待 `login_success`。
4. 取得 `userId`。
5. 复核联系人、聊天和消息 API。

未收到 `login_success` 前，不要通过反复重启容器或重新扫码掩盖 session
初始化问题。

### 结果判定

收到 `login_success`，取得 `userId`，且业务 API 可用。

## 2. Docker 启动后 VNC 无法交互

### 现象

容器和 6174 端口正常，但 noVNC 页面无法正常进行鼠标键盘交互。

### 原因

默认 x11vnc 启动状态不稳定，端口可访问不表示 interactive x11vnc 已恢复。

### 处理

验证环境由 `docker/fix-vnc.sh` 自动修复，并通过
`cf-wechat-vnc-fix.service` 在 systemd 中执行。

```bash
systemctl status cf-wechat-vnc-fix.service
journalctl -u cf-wechat-vnc-fix.service -n 100 --no-pager
sudo systemctl restart cf-wechat-vnc-fix.service
```

### 结果判定

systemd unit 执行成功，noVNC 页面可见且鼠标键盘可以交互。

### Known Issue

修复脚本和 unit 当前未包含在仓库中。新环境缺少它们时不能只凭上述服务名恢复，
需要从受控部署记录取得实际文件。

## 3. Debian 13 无法直接 pip install

### 现象

在 Debian 13 系统 Python 中执行 `pip install` 被拒绝，并提示 externally managed
environment。

### 原因

Debian 13 遵循 PEP 668，将系统 Python 标记为外部管理环境，防止 pip 覆盖由
操作系统包管理器维护的 Python 包。

### 处理

优先使用系统包；必须安装 Python 工具时使用 venv：

```bash
sudo apt install python3-venv
python3 -m venv .venv
. .venv/bin/activate
python -m pip install <package>
```

不要使用 `--break-system-packages` 作为常规解决方案。本项目的容器部署本身不
要求在 Debian 系统 Python 中安装 agent-wechat 依赖。

## 提交故障信息前

保留系统版本、Docker/Compose 版本、镜像 digest、时间点和去敏后的错误日志。
不得附带 auth-token、二维码、联系人、聊天正文、媒体文件或私有主机地址。
