# Controller 权限修复与干净设备部署验收记录

日期：2026-09-06。修复 PR：[WeChat #7](https://github.com/Tangbohu09527/CF_agent-wechat/pull/7)。
本任务没有连接 CFserver、AI 主机，没有读取现场 Token、Session、数据库或业务文件。
没有修改其他 worktree、Gateway/总文档仓库，没有创建生产 Tag、发布镜像或合并 PR。

**结论必须分开：A 是仓库代码及自动化回归；B 已验证干净 Debian 13 容器中的正式
WeChat 准备流程，但完整新设备部署仍受 Gateway 资产缺口和宿主验收限制；C 待人工验收。**
不能单凭 PR、CI 或 dry-run 宣称完整新设备部署通过。

## A. 仓库代码修复及自动化回归

### 分支、根因和修复范围

开始先执行 `git fetch origin --tags --prune`。当前任务工作树最初是干净的 detached
`02583fe76220916019ca961bb37dfa015640384e`；fetch 后 `origin/main` 为
`69f07702b6ee16d8e9700b3a53d5ebbb8ee875f8`，与用户提供的基线一致。
检查 branch、HEAD、remote、status、staged diff、worktree 和所有已有 PR 后，没有同任务分支或 PR。
从该 `origin/main` 创建 `fix/controller-precheck-clean-deploy`，全部修改、测试提交与普通 push
均在此分支进行；没有使用旧 feat/docs 分支，也没有改动 main checkout。

旧代码先以管理用户直接执行 `-L/-f/-x`，随后直接调用固定 Controller `contract`。
当 `/opt/cf-agent-gateway` 为 `root:root 0750` 时，非 root 管理用户无法穿越父目录，
正常 Controller 因此被误报为 unavailable。start/stop/status 的共享入口和 Bootstrap
复制的校验都受影响。sudo 执行整个日常入口会改变管理身份，不能作为修复方案。

正式生产修复首次提交为 `7caf040c4ab7c47e9a916f3a68df8a0778824c64`：

- `scripts/gateway-controller-common.sh`：固定路径及所有父目录的非 symlink、root 属主/组、
  安全权限检查；Controller 必须是可执行、单 hard-link 的普通文件。
- `scripts/qr-runtime-common.sh`：先明确 sudo 授权，再复用 privilege/timeout helper 执行
  文件检查和 contract；生命周期 Controller 调用也由特权 timeout supervisor 管理。
  Contract v1 JSON 的字段集合、类型和值检查保留，不输出外部错误或 Token。
- `scripts/bootstrap-cfserver.sh`：授权先于特权预检查，复用相同文件检查；不信任进程环境的
  `SUDO_UID/SUDO_USER` 来扩大可接受属主，仍只准备管理目录、Token 和网络。
- `scripts/status.sh`：配置/授权失败后不再继续探测 Docker。
- Runtime UID/GID/MODE 放入受保护的 `docker/.env`；不接受进程环境替换。
  管理用户与容器服务 UID 分开校验，不加入 root/docker 组。
- 新设备安装器、部署模板、两组 CI、真实权限回归和必要入口说明一起提交。
  Gateway/PostgreSQL 实现仍由其所属组件维护。

正常入口保持普通管理用户运行；不放宽 Gateway 目录、不恢复 VNC/公网 API、
不自动恢复 Archive、不改变 Dispatch 所有权，Agent 保持 `restart: "no"`。

### 先失败、再修复的固定证据

| 证据 | 固定运行 | 实际结果 |
| --- | --- | --- |
| 修复前真权限复现 | [run 34017449817](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34017449817)，测试提交 `5a1dd446e2517d90490dcdcea1e4b1363c1a826a` | Debian 13 amd64；`qrmanager` UID/GID 1101，仅自己的组；原始 `69f0770` 直接探测失败并输出同样 unavailable；真实 sudo 查询成功。此轮 Controller 行为是替身。 |
| 修复前真实 Controller 复现 | [run 34017490236](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34017490236)，测试提交 `0313e3298d53345831405d510fa17e8d569c2e6c` | 匿名获取固定 Gateway 原文件并校验 SHA-256；同样复现旧代码失败和真实 sudo 静态 contract 成功。生产修复尚未发生。 |
| 修复后真权限回归 | [run 34018072888 / job 101445382223](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018072888/job/101445382223)，提交 `7caf040` | 同样真实目录、sudo 和非 root 身份下读取原 Controller contract 成功；随后负面矩阵、Bootstrap、Runtime 权限、dry-run 和 Gate 检查通过。此运行其他旧 fixture 曾有红灯，不将整轮称为全部通过。 |

后续提交补齐真实控制终端中的普通 start/stop 拒绝授权、失效 sudo、伪造属主环境变量，
以及忽略 TERM 的 root Controller/子进程硬超时清理。最终 Head 的全部 CI 状态、远端 SHA
和 PR 状态记录在 PR 检查与最终交付消息；上表保留修复先后顺序的不可混淆证据。

原 Ubuntu runner 的 `/opt` 实际为 `root:root 0777`。旧 fixture 现先记录该元数据，
再在一次性 CI runner 内准备 `root:root 0755` 的安全父目录和 `0750` Gateway 根目录。
这是纠正测试环境，不是放宽生产检查。旧测试中“contract 不使用 sudo”的断言也已反转，
并保留先 `sudo -v`、后非交互 `sudo -n` 的审计。

### 测试边界与复现方式

新增测试覆盖真实用户、真实 sudo 策略的无授权/拒绝/失效，Controller 缺失、symlink、
hardlink、不可执行、属主/组/模式/父目录不安全，contract malformed JSON、错误版本、
类型/字段/值、超大输出、非零退出及超时。正式 Bootstrap 创建保护的 Token/Archive；
正式 fresh-start 创建服务 UID 1000 Runtime，管理 UID 1101 仍能管理。

真实权限测试的静态 contract 来自真实 Gateway；后半段 Docker/systemd、Agent API 和
生命周期 Controller 行为使用外部替身。完整模拟扫码成功、API 就绪、status 返回成功及
Worker 放行顺序由既有 Lifecycle 测试覆盖；这些都不是实际微信/Hermes 验收。

在无部署资产的一次性 Linux Docker 环境，从完整 Git checkout 执行：

```bash
docker run --rm --platform linux/amd64 \
  -e CF_CONTROLLER_PERMISSION_DISPOSABLE=1 \
  -v "$PWD:/src:ro" debian:13-slim /bin/bash -c '
    set -euo pipefail
    apt-get update
    apt-get install -y ca-certificates curl git sudo python3 python3-venv openssl systemd
    bash /src/tests/integration/controller_real_permissions.sh --full
  '
```

将 `--full` 改为 `--baseline-only` 可单独复现固定原始提交；测试拒绝已有固定部署路径。
不得在生产主机直接执行测试脚本。CI 记录 Debian 实际 digest/Image ID 和依赖版本，
并上传 `controller-baseline-debian13`、`controller-regression-debian13` 日志。

保留并执行的检查为 Unit、Static、Lifecycle、Bootstrap、Permissions、Compose render、
真实 Docker restart=no、ShellCheck、Python 编译、hygiene 和逐文件 `bash -n`。
工作流已修正旧的“一次 bash -n 后跟多个文件”错误；每个 Shell 文件单独检查。

## B. 干净 Linux 环境安装验证

### 已实际通过的范围

固定测试提交 `e91a82b5a76641f23e6ffd10c7ac90aa3ce966c9` 的
[push run 34018373955](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018373955)
和 [PR run 34018375231](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/34018375231)
均通过正式安装器测试；artifact ID 为 `9984686570`（push）。

测试从干净 Debian 13 amd64 容器开始，实际调用安装器完成 APT 依赖、locked 管理用户
`deploycheck` 创建、拒绝授权测试、真实 sudo 授权、指定 GitHub 提交独立 checkout，
以及独立空 Docker daemon 中的不可变镜像拉取、镜像服务身份检查、`.env` 和 venv 准备。
没有挂载宿主 Docker socket、旧用户 HOME、Token 或 Session，没有预造关键安装资产。

实际确认重复包/checkout/configure 步骤保留账户、组、HOME、配置 inode/内容和来源记录；
冲突 Runtime UID 输入失败并保留配置。安装过程不生成 WeChat Token、不建立 Runtime/Session，
也不调用上游默认入口；唯一镜像进程是无网络、无宿主挂载的 `/usr/bin/id` 身份探测。

| 来源类别 | 已取得证据 |
| --- | --- |
| WeChat 宿主管理代码 | 每次安装要求完整 Git SHA，独立从原 GitHub 仓库获取；不作为上游镜像源码 SHA |
| Gateway 静态 Controller | 固定 `4f13039b86c60bc94340edb5468f0102d62d2dff`；文件 SHA-256 `c28d9a97157b7551d91b6ee8e29396fd6b7807670c85b470a0b522f7d4b0c7f6` |
| 上游 amd64 镜像 | `ghcr.io/thisnick/agent-wechat@sha256:b5e92047e28ce67e34576e574d8ccf00f8619f485597109f7342a137300285c0`，实际由公开 registry 拉取 |
| 实际 Docker Image ID | `sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720`，本次 `docker image inspect` 取得 |
| 上游服务身份 | 本次镜像 `/usr/bin/id` 实际返回 `1000:1000`；与管理账户身份分开记录 |
| 本次依赖版本 | Docker CE 29.8.0、Compose 2.40.3、containerd 2.3.4、Python 3.13.5；Pillow 11.3.0、qrcode 8.2、websocket-client 1.8.0；完整 APT/pip 版本见 artifact |
| 部署配置版本 | 安装器来源记录 `configuration_version=1`；受保护 `.env` 不含 WeChat Token |

虽然实际 Image ID 与历史记录相同，本证据来自新的公开 registry 拉取，不使用旧 daemon
或 docker save。上游镜像 config 没有可证明的源码 SHA，不能把本仓库 SHA 冒充其源码。
Gateway 的完整应用镜像本次未构建/运行；其构建来源和依赖锁缺口见配套审计。

### 必要输入和按顺序执行的入口

完整可执行命令在[干净设备部署指南](../deployment/clean-device.md)：

1. Debian 13 amd64、管理员安装权限、可访问 GitHub/APT/GHCR/PyPI 的网络；获取审核过的完整 WeChat Git SHA。
2. `prepare-clean-host.sh system --manager USER` 安装依赖和账户；为新 locked 账户人工配置登录与 sudo 认证。
3. 普通管理用户执行 `prepare-clean-host.sh checkout --manager USER --commit FULL_SHA`。
4. 普通管理用户执行 `prepare-clean-host.sh configure`，明确 Git SHA、可获取的镜像 digest、服务 UID/GID；可选代理遵守模板约束。
5. 安装固定 Gateway 源码/Controller，读取静态 contract；此步骤不要求 Token 或 ready。完成 Gateway 配套资产修复后再继续全栈。
6. 普通管理用户执行 `bootstrap-cfserver.sh`，安全生成/复用 WeChat Token、管理目录和 `cf-internal`；它不扫码、不启动 Agent/Worker。
7. 按 Gateway 所有权准备 PostgreSQL 端点、数据库/迁移权限、独立认证 Secret、Hermes endpoint/认证，以及正式网络配置；启动 Gateway/Dispatch。
8. 普通管理用户 `start-qr-login.sh --dry-run`；随后在真实交互终端 fresh QR，查询 status 并完成文本闭环。
9. 正常 stop、再次 fresh QR、Host reboot 后按既定先关闭组合 Gate再 fresh QR 的流程验收；不恢复 Archive 登录状态。

WeChat Token 由 Bootstrap 生成，不是用户复制输入，保持固定保护文件契约；不进 `.env`、
Runtime、Archive 或日志。PostgreSQL/Hermes 是明确外部输入，不需要登录旧机器取配置。

### 尚未完成的完整新设备门禁

该 CI 使用 Ubuntu runner 内的 Debian 13 用户空间及独立 Docker，**不是启动了 Debian
内核/systemd 的全新设备**。systemd 服务启用、真正 Host reboot、真实 Gateway/PostgreSQL
全栈和真实微信/Hermes 没有在该测试执行。只验证这一基线，不声明其他平台已受支持。

[Gateway 配套缺口报告](../deployment/gateway-clean-install-gaps.md)提供固定来源、行号和
可复现审计：生产 Compose 未加入 WeChat 的 `cf-internal`，默认配置禁用 WeChat/Hermes，
生产镜像变量为占位符，缺空白主机幂等配置/安装入口。Controller 又固定读取该 Compose，
不能靠隐藏 overlay 或事后手工 network connect 解决。

需要 Gateway 独立修复自己的正式网络、配置/Secret 准备、Controller 安装、镜像来源和
PostgreSQL 首次迁移验收；不能在 WeChat 复制一套实现，也不能将此缺口藏为“用户自行准备”。
本任务仅被授权跨仓库只读核实，故没有修改 Gateway。

## C. 真实微信扫码与真实 Hermes 回复验收

**待人工验收。** 本次没有执行真实扫码、登录真实微信账户、发送真实文本或取得 Hermes 回复。
也未执行真实设备正常停止/再次登录及 reboot 后恢复，历史现场结果均不替代本次验收。
待 Gateway 配套修复和干净 Debian 主机就绪后，按部署指南逐项记录扫码、11 项 status、
文本闭环、停止/重启与 reboot 证据；人工扫码与外部 Hermes 配置仍是必要条件。

## 现场应急补丁的后续替换

本任务不操作 CFserver。后续单独批准的部署窗口中，先核对现场工作区和应急 diff，
保护未提交内容和所有数据；在新 release checkout 获取最终审核通过的固定仓库提交，
核对部署 `.env` 服务 UID/GID、Controller 及 Token 契约，再由普通管理用户执行 Bootstrap
与 dry-run。仓库的共享受控预检查会正式替代现场局部补丁，无须 root 执行整个登录入口。

真正切换、fresh QR、Hermes 文本与 reboot 验收必须另行执行并留证；本任务没有推断或
宣称现场已经部署此版本。PR 保持未合并，最终远端分支 SHA 与 CI 结果需一起核验。
