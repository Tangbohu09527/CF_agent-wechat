# 保留既有账号的受控登录候选

独立候选基于 `codex/fix-wechat-return-filename@7bd42b623d405956080a13481bbf4de21aa3477a`，原生上游固定 `thisnick/agent-wechat@96c2e90c497d999bf5189a134a9b3b293731f42e`。不接管旧 forced-QR 未提交材料。此候选尚未部署，不构成正式镜像切换授权。

## 修复范围

原生登录计划检测到不同账号时会清 `wechat_keys`、`sync_state` 并替换 session 身份；检测十次失败仍可能发无身份的成功事件。保留账号流程不能使用这些行为。

本 overlay 要求 `/api/ws/login` 显式提供 `expectedAccount`，且与已经保存的 session 账号逐字相等；缺失、未知、不同账号及 `newAccount=true` 均拒绝。初次无已存账号的注册不属于该契约，不会猜测账号，也不从昵称绑定。登录过程中再次检查已存身份；检测账号、提交 PID/登录状态、提取密钥前后及写入密钥前分别核对。未知、多账号 fd、身份变化、密钥提取失败均返回失败。没有清 session、切号、删除 runtime 或重置 checkpoint 动作。

账号标识沿用上游 account directory 身份，不称作可自行猜测的 wxid。上游原函数只取第一个数据库 fd；本登录分支要求进程 fd 中只有一个可辨识账号，多个账号或读取失败拒绝继续。它不保证恢复手机历史，也不代替登录后的联系人/接口读取验收。扫码者选择错误账号仍可能使微信自身进入另一个账号；候选的承诺是拒绝接管、保留项目 session/keys/checkpoint，不对微信客户端自动退出、切回或清理。

认证后的 `/api/status` 和 `/api/status/auth` 由编译进守卫的同一模块返回：

```json
{"loginCapabilities":{"contract":"expected-account-v1","required":true,"preservesSessionOnMismatch":true}}
```

接口须经过原上游认证。能力声明不由环境 flag 或操作者字符串生成。Gateway 必须观察到新鲜、三个字段精确匹配的响应，再结合受控来源允许配置才开放该动作；仅配置 flag 不代表目标已支持。`auth` 发现实际账号无法核验或不符时返回未知与脱敏错误，不用已存账号伪造在线身份。

登录循环不记录选中 action 的完整内容，避免 QR 字符串或消息内容进入 debug 日志。此改动保留动作执行、等待与超时机制。

## 离线复现

只对全新、干净、准确固定上游 checkout 执行；脚本先核对 HEAD、未提交状态及原文件摘要，失败前不写文件：

```sh
export CF_LOGIN_SOURCE="$PWD/agent-wechat/login-candidate"
python3 -m unittest discover -s tests -p test_login_expected_account_overlay.py -v
python3 scripts/apply-login-expected-account.py --source "$CF_LOGIN_SOURCE" --with-return-filename
cargo test --locked --manifest-path "$CF_LOGIN_SOURCE/packages/agent-server-rust/Cargo.toml" expected_account_ -- --nocapture
```

`--with-return-filename` 从同一干净源码组合已固定的 PR9 原文件名补丁，保留文件发送生命周期队列；不盲目合并安装器。仅需要登录补丁时可省略该参数。已修改源码不会被重复覆盖；重新验证使用另一份干净副本，不 reset/clean 旧材料。

当前本机没有 Rust 工具链，未安装系统 Rust。Python 离线身份/组合检查 3 项通过；原生 Rust 编译、真实 SQLite 及认证 HTTP/WS 拒绝测试由新增 `login-expected-account.yml` 在一次性 Linux runner 使用锁定依赖执行。CI 最终状态另行补记，未执行或失败不得算通过。测试没有扫码、真实账号、上游 Token、真实微信发送或模型调用。

## 后续现场许可边界

本轮只交付源码 overlay、测试和 Draft PR。尚未构建/签认正式运行镜像，也未核对目标运行二进制是否含本守卫；Gateway 对旧核心仍应禁用扫码动作。正式核心镜像切换需要单独确认准确候选镜像、原镜像备份、停止/替换范围及回退流程，保留 runtime 和正式 Poll/Dispatch/Delivery 原状态。真实扫码、账号一致性、登录后资料读取与二维码过期验收均未执行。
