# 登录观察与 WAL 读取最小候选

本记录仅覆盖独立微信修复线，不表示已部署或已完成真实账号登录验收。

## 代码和范围

- 分支：`codex/fix-live-login-observation`，base `codex/feat-login-expected-account@5a5387c1b921782c077434f558d28b174d2e689c`。
- Draft PR：<https://github.com/Tangbohu09527/CF_agent-wechat/pull/14>。
- 默认 overlay 直接用于干净官方 `96c2e90c497d999bf5189a134a9b3b293731f42e`，只改四个源文件；源码/包校验拒绝额外改动。
- 默认包不包含 expected-account 守卫、文件名、媒体发送或安装器改动。`--with-expected-account` 是单独显式组合，不能把该选项的测试结果当成默认包具有的能力。
- 本线未连接 CFserver、未替换核心镜像或二进制、未启停微信、扫码、切号、发送、清理 runtime/session/keys/checkpoint。

## 失败复现和修复边界

固定源码的 saved-account 识别与按钮动作不包含 **Enter Weixin**；本次认证观察未识别主窗口时，会保留旧 context 的 `is_logged_in=true`。最小修复为精确同义按钮选择，并要求当前观察属于实际能证明认证阶段的主窗口状态。未知树、未知状态 ID、错误 FSM、网络代理设置页都不能借旧 ChatOpen 证明在线。

认证未知响应为：

```json
{
  "status": "unknown",
  "error": "observation_unrecognized",
  "reason": "auth_observation_unrecognized",
  "identityVerified": false,
  "observedAt": "本次UTC检查的RFC3339时间"
}
```

`loggedInUser` 如存在仅为原已存资料；此错误路径不保存沿用的 context，不更新身份或凭据。

原数据库 reader 用 `immutable=1`，不能据此声称会看到仍在 WAL 中的新提交。修复使用短连接 `mode=ro`、`query_only=ON`、1 秒 busy timeout；不发 checkpoint、不改 writer journal mode、不持有跨请求事务。

WAL 原生回归使用真实加密 SQLCipher 数据库和固定合成密钥：先将基线放入主文件，关闭自动 checkpoint，保持 writer 打开，再提交 WAL-only 消息和 session 时间；调用的是实际 `query_wechat_db`。另验证读后 DELETE/WAL writer 可继续、写入 SQL 被拒绝、原 WAL 模式保留。

本地 Python 固定源 RED 为 3 个预期失败；修复及继承组合共 8 项 GREEN。首次 native CI 的 RED 为 3 通过、7 个行为断言失败；其 GREEN 错误复用了同名 crate 的 RED 二进制，未计为产品验证。之后切换源码前仅清理根 crate 构建产物，保留依赖编译，避免 mtime 缓存污染。

## 本次实际 CI 与制品

- 已测试代码 head：`180a11cfa32c5d58378c355776bc4687654acaba`。
- PR CI：<https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/39755928451>，2026-10-22 09:37:17 UTC 完成成功。
- PR merge 构建 SHA：`70d0546b34d038b7b5e6928659ad39c49b50a3bc`。下载后再次计算当前代码的四个转换输出，全部等于 release-proof 的源码摘要；不能把 merge SHA 写成 PR head。
- 原生 RED：11 项中 3 通过、8 个预期行为断言失败；同一原生 GREEN：11 项通过。显式守卫组合：8 项 expected-account 通过，再跑同组 11 项通过。
- Ubuntu 22.04 / Rust 1.93.0 / 官方未改 Cargo.lock：`9f553183024da0fbbdaea7eb7adc49831f9d058921f17b064d4145fa9501736c`。
- 单二进制镜像构建、原 runtime config 保留、仅一个替换层、ELF loader 检查均通过。CI 候选 image ID：`sha256:ed9f315fcbc5ffe0f24c2a473f2862d17dc09f9cb75c24189a786eef9712abcc`。
- Artifact ID：`12416078159`；名称：`live-observation-70d0546b34d038b7b5e6928659ad39c49b50a3bc`，14 天保留。artifact 传输 digest：`sha256:bb1d508f295ebc857a76bd44bd11c0d7b6cb981796b48daca43c0bf8f3f0a167`。
- `live-release/context/agent-server`：10,689,936 字节，64-bit Linux x86_64 ELF，SHA256 `5330f4b2fe69f3deb6a2070aabf93b3a02a63f8ff15ec375c71777dd9c7db4ce`。
- `live-release/live-observation-overlay.tar.gz` SHA256：`356a1072acbb8f098e4e74ffeccce229c00c9361a93cf4b1f0c42b1c81426a20`。
- 包内 `release-proof.json`、`runtime-loader.txt`、`context/SHA256SUMS` 与 `live-observation/*` 原生日志可独立核验；不包含真实资料、二维码或凭据。
- 本分支同内容重复 push native CI `39755922396` 已取消，仅保留以上 PR CI，不取消其他任务。

当前主机没有安装系统 Rust；原生行为及 Linux 包验证在一次性 CI runner 执行。尚未执行真实微信界面的持续健康/登录、正式 WAL 新消息和端到端页面延迟验收，不能由 CI 成功推断现场已恢复。

## 固定官方启动与登录契约（仅源码核对）

以下行号属于官方固定 `96c2e90…`，未操作现场进程：

| 源码 | 实际行为 | 对变更的含义 |
| --- | --- | --- |
| `docker/entrypoint.sh:183` | 容器入口执行 `launch-wechat &` | recreate 会重启微信/Xvfb/D-Bus，属于另一个明确中断边界 |
| `docker/entrypoint.sh:200-216` | `while true` 运行 agent-server 并 wait，退出 0 后一秒再启动 | 可以只重载 agent，不需要主动停止微信；该 loop 在 `set -e` 下对非 0 退出不能保证继续 |
| `scripts/dev-deploy.sh:80-94` | 官方开发部署复制 agent 二进制后 `pkill -f '/opt/agent-server/agent-server'` | 证明官方有独立二进制重载路径；本轮未执行此开发脚本 |
| `src/main.rs:77-96` | 捕获 SIGTERM 后让 HTTP graceful shutdown 返回 | 若另行批准，可针对精确 agent PID 发 TERM 并检查新 PID；不能假设 SIGKILL/崩溃也安全重载 |
| `src/main.rs:44`、`router/voice.rs:362` | 启动时把未完 voice job 标失败或需人工核对，不重派 | 重载前需确认没有在途语音发送；不能把重载称为没有任何运行状态副作用 |
| `sessions/manager.rs:111` | 现有 default 的 display 为 `:99` 时直接返回；其他 display 删该 session 行后重建 | 另行批准重载前必须定向核对并满足 `:99`，不能盲目假设会话保留 |
| `sessions/health_monitor.rs:157-165` | 与认证共用 `identify_states`；main_window 存在就刷新健康计时，否则 60 秒后 kill | Enter Weixin fixture 识别为 login_account 即进入不 kill 的正常分支；真实持续运行观察仍需部署后验收 |
| `plans/login.rs:159` | `newAccount=false` 在 saved-account 页选择 click_login；true 会选择 Switch Account | 只有保留账号分支才符合目标；不能放开任意 newAccount |
| `plans/login.rs:259-266` | 探测账号与已存账号不同时会 clear_session_data，再写入新账号 | 最小观察包不修复这条原路径，不能把原完整登录 plan 当作账号守卫 |
| `plans/login.rs:307`、`router/status.rs:338` | 存在未确认身份也回 login_success 的兜底 | 收到该字符串不足以证明账号正确或全部就绪 |

默认原生登录 plan 没有调用 logout/fresh-QR，也没有主动清 runtime；但它含上述 mismatch 清理和身份兜底，因此本包不自动启用 Gateway 完整登录。只读状态/二维码读取可用于观察。要通过受控管理链调用完整登录，需单独明确批准 PR13 守卫组合，或由真人完成保留旧账号操作后重新验证；本轮不暗中启用。

## 可审阅运行包与后续许可边界

包基于现已锁定的 64 位 manifest digest：

`ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43`

配置 ID：`sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e`。
沟通记录里曾把 `856228f` 转录成多一个 2 的 `8562228f`；构建使用仓库锁文件的合法 64 位 digest 并要求拉取后 config ID 一致。

单层镜像只 COPY `/opt/agent-server/agent-server`。保留其他文件和全部运行配置，验证 ELF/glibc loader；CI 不启动微信、不挂实际数据。制品带源码 receipt、二进制 SHA、镜像 ID 和合成测试日志。

若申请正式核心切换，应明确选择并记录其中一种：

1. **仅 agent 二进制重载**：先保存原二进制、校验值/权限和当前容器身份，确认无在途 voice job、default display 为 `:99`，原子放入经核验的新二进制，只对精确 agent PID TERM，确认新 PID、API/fresh auth/WAL 与微信 PID未被主动重启。失败时恢复原字节并按同一路径重载。若优雅退出或 restart loop 不符合源码契约，停止，不扩大成杀容器/重建微信。
2. **固定镜像 recreate**：先保留原镜像引用、Compose 配置和持久化数据边界，另行明确允许微信短暂中断；仅替换该服务镜像，保留同一数据挂载、端口、Token及账号。失败恢复原镜像引用和容器配置，不回滚/清除账号数据或 checkpoint。

以上都不是本线已执行的操作。PR13 守卫、文件名切换、正式 AI 派发、Delivery、权限迁移均不随这次最小包自动启用。

## 后续现场部署观察（2026-10-22，UTC+08:00）

本节补记主线在上述候选验证完成后的实际操作与观察，前文“未部署”描述保留为当时的历史边界。

- 17:48:08—17:48:11，经本轮另行明确许可，仅原子替换 API 二进制并向精确 API 进程发送 TERM，随后重载成功。部署字节核验为上述 SHA256 `5330f4b2fe69f3deb6a2070aabf93b3a02a63f8ff15ec375c71777dd9c7db4ce`；API PID 从 `96` 变为 `1828076`，微信 PID `1827824` 及容器身份保持不变，原加密 session 保留。
- 运行镜像仍是前述 config ID `sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e` / manifest digest `sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43`。本次是容器可写层中的二进制热替换，不是新镜像部署；recreate 会丢失该补丁，不能依靠旧镜像重建来保留修复。
- 新鲜认证观察已能将当前 saved-account 页面识别为 `LoginAccount / logged_out`。17:49:54 的后续观察未见补丁后再次 kill 微信；这是有限时段的现场观察，不是所有未知状态下均不终止进程的保证。17:52:14，实际 Edge 候选页面显示 `offline / logged_out`，采集虽已启用但处于 `blocked`，不能写成已登录或实时采集恢复。
- 加密 snapshot 完整性检查通过，原二进制已备份；未执行回退演练，不能记为回退验证通过。此次没有清理 runtime/session、切换账号、迁移正式权限或开启 AI 派发/发送。

用户要求明日通过手机扫码完成登录，本轮不点击 **Enter Weixin** 或 **Switch Account**，不发起登录。固定官方路由 `POST /api/status/login` 仅截图并解码当前屏幕上的二维码，不会导航到二维码页；当前 saved-account 页面没有二维码，因此不能靠该路由产生二维码。`GET /api/ws/login` 会启动完整 `LoginPlan`，其中仍有账号不符时清理 session 数据及改写已存身份的分支，本轮不使用。安全二维码展示/控制路径尚未接通，需明确保留账号与资料的控制边界后再继续；不把当前没有二维码记为扫码流程已经验收。

本次部署后，真实消息 A—F 的采集、入库与页面自动显示验收均未通过，延迟没有有效实测值。CI `39755928451` 的隔离原生验证结论继续有效，但不替代现场登录或消息验收；本节仅为文档补记，不为此重跑无关测试。
