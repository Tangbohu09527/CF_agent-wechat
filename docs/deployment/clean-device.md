# 干净 Debian 13 amd64 安装与验收

本入口把主机依赖、固定代码和 WeChat 配置准备变成可重复执行的仓库资产。
它不是全栈上线按钮。当前 Gateway 固定版本仍有首次部署缺口，详见
[Gateway 配套修复范围](gateway-clean-install-gaps.md)；未解决该门禁前不能声明新设备文本闭环通过。

首个验收基线是干净 Debian 13（trixie）amd64。其他平台尚未验证。
`system-packages` 可以在真实 Debian 13 容器验证包安装，但容器结果不证明
systemd、宿主内核、Docker daemon 或 Host reboot 已验收。

## 必要输入

| 输入 | 要求与来源 |
| --- | --- |
| 管理脚本提交 | 本次修复 PR 的最终完整 Git SHA；合并后可选择对应已审查提交，不使用浮动 main 代替记录 |
| 新主机 | Debian 13 amd64，systemd，初始 root/管理员访问；足够的镜像和 Runtime/Archive 空间 |
| 管理账户 | 任意合法非 root 用户名；不属于 root/docker 组；交互 sudo 授权、密码和 SSH 公钥由设备管理员配置 |
| 上游镜像 | 可从 registry 获取的完整 `@sha256:` 引用；需要 registry 认证时单独配置 Docker 凭据，不放进 WeChat `.env` |
| 容器服务 UID/GID | 根据批准镜像验证后显式提供，与管理用户 UID/GID 独立；当前候选是 1000:1000 |
| Gateway | 固定源码提交、正式可执行安装/构建资产、配置版本；当前审计 SHA 为 `4f13039b86c60bc94340edb5468f0102d62d2dff` |
| 外部服务 | Gateway 负责的 PostgreSQL 连接/凭据、数据库迁移、Hermes 地址/认证、消息路由配置 |
| 网络 | Debian APT、Docker APT、GitHub、GHCR/PyPI、微信及外部 Hermes 的可达性；WeChat/Gateway 共享 `cf-internal` |
| 人工验收 | 受控 TTY、真实微信人工扫码、测试聊天、真实 Hermes 回复权限及可控重启窗口 |

WeChat API Token 不属于人工粘贴输入：Bootstrap 安全生成或复用固定受保护文件。
不得把数据库、旧 Token、Session 或 Archive 从旧设备复制成“干净设备”前提。

## 1. 获取审核过的安装器，准备系统

以下命令只在新设备执行。本任务没有连接 CFserver 或 AI 主机。
初始 root 会话先设置本次完整提交和管理用户名，再取得同一提交的安装器：

```bash
# root on the new Debian host; replace the commit with the reviewed final SHA.
WECHAT_COMMIT=REPLACE_WITH_REVIEWED_40_HEX_COMMIT
MANAGER=cfoperator
[[ "$WECHAT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 1
apt-get update
apt-get install --yes --no-install-recommends ca-certificates git
SOURCE_DIR=$(mktemp -d /root/cf-wechat-source.XXXXXXXX)
git -c core.hooksPath=/dev/null init "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin https://github.com/Tangbohu09527/CF_agent-wechat.git
git -C "$SOURCE_DIR" fetch --depth 1 origin "$WECHAT_COMMIT"
git -C "$SOURCE_DIR" -c core.hooksPath=/dev/null checkout --detach FETCH_HEAD
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$WECHAT_COMMIT"
bash "$SOURCE_DIR/scripts/prepare-clean-host.sh" system --manager "$MANAGER"
```

系统阶段使用 Docker 官方 Debian APT 仓库、固定签名 key 指纹和 `signed-by`，
只安装缺失的依赖，选择 Compose v2，并记录精确安装版本。已有冲突 Docker 包会报错，
不会自动卸载；已有 daemon 配置不改写。首次部署运行 Docker daemon 是系统依赖准备，
不会启用 WeChat 自启动。依据：[Docker Debian 安装说明](https://docs.docker.com/engine/install/debian/)。

新建的管理用户密码默认锁定。设备管理员须设置其登录/交互 sudo 密码并按组织政策
配置 SSH 公钥；安装器不会生成密码或添加 NOPASSWD。已存在账户的权限不自动扩大。
例如在 root 控制台执行 `passwd "$MANAGER"`，然后以该用户登录并确认 `sudo -v`。

将审核过的安装器放到普通用户可读位置。已有文件必须先比较，不覆盖其他版本：

```bash
# same root session
install -d -o root -g root -m 755 /usr/local/libexec
INSTALLER=/usr/local/libexec/cf-agent-wechat-prepare
if test -e "$INSTALLER" || test -L "$INSTALLER"; then
  test ! -L "$INSTALLER" && cmp -s "$SOURCE_DIR/scripts/prepare-clean-host.sh" "$INSTALLER" || exit 1
else
  install -o root -g root -m 755 "$SOURCE_DIR/scripts/prepare-clean-host.sh" "$INSTALLER"
fi
```

## 2. 普通管理用户安装固定代码

切换到管理账户的真实登录会话，重新设置同一提交；不要把日常流程放到 root shell：

```bash
WECHAT_COMMIT=REPLACE_WITH_REVIEWED_40_HEX_COMMIT
MANAGER=$(id -un)
bash /usr/local/libexec/cf-agent-wechat-prepare checkout \
  --manager "$MANAGER" --commit "$WECHAT_COMMIT"
cd /opt/cf-agent-wechat
```

目标代码目录由管理用户持有。安装器从固定 GitHub URL 获取完整提交，校验 SHA 后安装；
现有目录的 origin、HEAD、修改和权限必须通过校验，否则保留目录并报告。
重试不会切换现有 checkout、清理修改或影响别的工作树。

## 3. 准备镜像、配置和 Python venv

下列引用是本次通过公开 registry 元数据查到的 `0.11.15` linux/amd64 manifest。
元数据可获取不等于镜像已拉取、已运行或已通过扫码验收：

```bash
WECHAT_IMAGE=ghcr.io/thisnick/agent-wechat@sha256:b5e92047e28ce67e34576e574d8ccf00f8619f485597109f7342a137300285c0
./scripts/prepare-clean-host.sh configure \
  --manager "$MANAGER" --commit "$WECHAT_COMMIT" \
  --image "$WECHAT_IMAGE" --runtime-uid 1000 --runtime-gid 1000
```

`configure` 拒绝远端/rootless Docker，实际从 registry 拉取不可变引用，记录
`docker image inspect` 的 OS/架构/Image ID，随后用无网络、无宿主挂载、绕过上游 entrypoint
的临时 `id` 容器核对服务 UID/GID 并清理该容器，使用 `scripts/requirements.txt` 创建
普通用户 venv。失败停在有名称的阶段；修复网络或权限后可重新运行。

首次原子创建管理用户持有的 `docker/.env`（0600），重复执行按键值比较且不覆盖。
默认 loopback 6174、无代理、`RUST_LOG=info`、Runtime 0700。若需要非默认端口/无认证代理，
从 `.env.example` 创建受保护的 `.env` 并按 Bootstrap 契约审查；自动 configure 遇到
不同配置会停止并保留原文件，不能用重跑覆盖已有配置。

需要独立复核时，可在干净环境验证批准镜像的服务用户（仅一次性执行 `id`，不执行上游 entrypoint，
无网络、无业务 bind、无 Session；这不是 WeChat 生命周期 dry-run）：

```bash
sudo docker --context default run --rm --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --entrypoint /usr/bin/id "$WECHAT_IMAGE" wechat
```

结果的 UID/GID 必须与受控 `.env` 配置一致。容器服务账户与管理账户可具有不同 UID。
`CF_AGENT_WECHAT_RUNTIME_MODE` 是缺失目录的新建默认值。日常 fresh-QR 流程继续保留
已有目录经安全检查后的各自 mode；Bootstrap 对已有目录仍要求 mode 与配置一致。
因此已有部署若 mode 不一致，Bootstrap 会保留现场并停止，须单独审查，不能靠本安装器重跑改权限。
镜像升级必须重新核对；不得依据管理用户恰好 UID=1000 推断服务身份。

安装记录位于 `/var/lib/cf-agent-wechat-install/system-packages.txt` 和管理用户的
`~/.local/share/cf-agent-wechat/install/{sources.txt,python-packages.txt}`，包括管理仓库
Git SHA、配置版本、不可变镜像引用、实际 Image ID、Runtime 身份及依赖版本。
Gateway 来源明确记录为由 Gateway 单独安装，需在最终验收记录补上其固定提交/构建来源。
这些记录不包含 Token。

## 4. Gateway 静态文件、Bootstrap 与外部依赖门禁

必须按以下顺序协调组件，不能要求先有完整运行中的 Gateway 才能创建 WeChat Token：

1. 从固定 Gateway 源码安装真实 Controller：Gateway 根目录 `root:root 0750`，
   `deploy` 和普通非 symlink `wechat-runtime-control` 为 `root:root 0755`。
   保持固定路径 `/opt/cf-agent-gateway/deploy/wechat-runtime-control`。
2. 完成 sudo 授权后读取静态 `contract`。此动作不需要 Token、DB、Gateway ready，
   不启动/停止 Worker。不要用模拟 Controller 或修改目录权限代替。
3. 以管理用户运行 `./scripts/bootstrap-cfserver.sh`：准备 storage、Archive、Token、
   external network 并审查 Compose；不创建 Runtime、Session 或启动容器。
4. 使用 Gateway 自己的正式入口准备配置、PostgreSQL/migration、镜像、共享网络，
   启动 Gateway/Dispatch，Poll/Delivery 维持 gated。
5. 管理用户运行 `./scripts/start-qr-login.sh --dry-run`，检查正式输入和受控 Controller。
   dry-run 不启停容器、不创建 Session、不归档 Runtime。

当前审计发现步骤 1 缺少正式完整安装入口，步骤 4 的 Gateway production Compose
缺 `cf-internal`，生产模板没有可用 WeChat/Hermes 地址，外部 DB/首次迁移链也未形成
可重复的生产部署资产。具体文件、固定 SHA、原始 Controller 证明和所需配套 PR 范围
见 [Gateway 审计](gateway-clean-install-gaps.md)。

因此这些步骤中可证明的静态 contract 和 WeChat Bootstrap 可以独立验收，步骤 4/5
仍须等待 Gateway 配套资产与真实 Docker/PostgreSQL 联调。不能用手工网络连接、临时
Compose overlay、假的 ready 或在 WeChat 复制 Gateway/PostgreSQL 实现填补该门禁。

## 5. 人工扫码、文本闭环和恢复

Gateway 安装门禁通过后，在受控 SSH TTY 以管理用户执行：

```bash
cd /opt/cf-agent-wechat
./scripts/start-qr-login.sh --dry-run
./scripts/start-qr-login.sh
./scripts/status.sh
# After a real WeChat message and real Hermes reply have been verified:
./scripts/stop-qr-runtime.sh
./scripts/start-qr-login.sh
./scripts/status.sh
```

每次 start 必须先通过 Controller stop/confirm 关闭组合 Gate，再进入 fresh QR；
扫码后才打开 Poll/Delivery。Dispatch 不归 Controller 管理。

重启验收单独记录：停止完成后在新设备的批准窗口 reboot，确认 Agent `restart=no`
保持停止，再运行上述 fresh-QR start/status；不自动恢复 Archive，重新扫码并重做文本
闭环。Gateway 自己的 reboot 状态也须记录，不能假设 Gate 自动关闭。

## 镜像来源证据与复现

2026-09-06 本次直接读取 GHCR，未访问旧 Docker daemon：

| 元数据 | 查询结果 |
| --- | --- |
| tag 查询入口 | `ghcr.io/thisnick/agent-wechat:0.11.15` |
| OCI index digest | `sha256:31a4e351c191bcbfc75e5c10be51e207d22a3eedd97f3ff56ad579fcce717b24` |
| linux/amd64 manifest | `sha256:b5e92047e28ce67e34576e574d8ccf00f8619f485597109f7342a137300285c0` |
| config digest（预期 Image ID） | `sha256:7ee0309980b7d03b747b40c6c04cbaeafe2d8fc01fc9429810cbc7571ebbf720` |
| image config created | `2026-04-01T22:55:40.702857446Z` |
| 上游源码 SHA | 镜像 labels 未提供，未证明；不能填写 WeChat 管理仓库 SHA |

config digest 不替代新机实际 `docker image inspect` 的 Image ID。
在有 Python 3 的设备可匿名复现元数据查询；临时 registry bearer 值只留在进程内，
不输出、不保存，不使用现场 Token：

```bash
python3 - <<'PY'
import json, urllib.request
base = 'https://ghcr.io/v2/thisnick/agent-wechat/'
with urllib.request.urlopen('https://ghcr.io/token?scope=repository:thisnick/agent-wechat:pull&service=ghcr.io', timeout=30) as response:
    bearer = json.load(response)['token']
def read(path, accept):
    request = urllib.request.Request(base + path, headers={
        'Authorization': 'Bearer ' + bearer, 'Accept': accept,
    })
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.headers.get('Docker-Content-Digest'), json.load(response)
index_digest, index = read('manifests/0.11.15', 'application/vnd.oci.image.index.v1+json')
manifest_digest = next(item['digest'] for item in index['manifests']
    if item.get('platform') == {'architecture': 'amd64', 'os': 'linux'})
_, manifest = read('manifests/' + manifest_digest, 'application/vnd.oci.image.manifest.v1+json')
_, config = read('blobs/' + manifest['config']['digest'], 'application/json')
print(json.dumps({'index_digest': index_digest, 'amd64_manifest': manifest_digest,
    'config_digest_expected_image_id': manifest['config']['digest'],
    'os': config['os'], 'architecture': config['architecture'],
    'upstream_source_sha': config.get('config', {}).get('Labels', {}).get('org.opencontainers.image.revision')}, indent=2))
PY
```

## 验收记录和旧设备替换

仓库验收入口为 [`tests/deployment/clean_host_prepare.sh`](../../tests/deployment/clean_host_prepare.sh)，
由 [Debian 13 CI](../../.github/workflows/clean-host-debian13.yml) 在一次性 Debian 容器运行。
它实际执行包/账户安装、GitHub 固定提交 checkout、自有 Docker daemon、镜像身份和
configure/venv；没有用容器结果替代宿主 systemd、Bootstrap 全栈或 reboot。

每次报告必须独立填写 A/B/C，附测试日志/CI 链接、输入 SHA 和依赖记录：

- A：仓库修复和自动化权限/生命周期回归；记录修复前失败、修复后通过。
- B：干净 Linux 安装；逐阶段记录系统/固定 checkout/镜像 pull/身份/configure/venv/
  Bootstrap/真实 Controller/真实 Docker/PostgreSQL/重启的实际执行结果。
  普通 Debian 容器的 `system-packages` 通过只算包阶段，未执行的系统步骤必须单列。
- C：真实微信扫码、真实 Hermes 文本回复、stop/start 和 reboot 后 fresh QR。
  本任务未执行的真实项目写“待人工验收”，不用历史现场记录代替。

已有 CFserver 应急补丁应在此 PR 审查/CI 完成、Gateway 配套缺口处理且新设备验收后，
由单独授权的维护任务升级到记录的正式提交。升级前核对现场 diff、保留有效 Secret/
Session/业务数据，再按正式 stop/部署/fresh-QR 顺序替换；不能直接覆盖现场未知修改。
本任务不执行 CFserver 更新、不获取现场数据，也不发布生产 Tag/镜像。
