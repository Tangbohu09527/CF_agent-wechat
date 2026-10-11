# Gateway 首次部署资产：历史审计与版本对照

原记录是 WeChat 权限修复的跨仓库只读审计，检查时间为 2026-09-06。没有连接
CFserver、AI 主机或读取现场配置；没有修改 Gateway 或总文档仓库。它不是干净 Debian
全栈安装通过的证明，也不替代真实扫码和真实 Hermes 回复验收。

## 2026-10-11 版本核对与当前证据边界

本次通过 GitHub API 只读核对 Gateway 远端 main，固定为
[`7963bc0db5a01e38099e021959feabf648db7ede`](https://github.com/Tangbohu09527/CF_agent-gateway/commit/7963bc0db5a01e38099e021959feabf648db7ede)，
递归 tree 返回 `truncated: false`，并读取下表对应文件。没有执行 Gateway 安装、
构建或测试，没有连接服务器。下文 `4f13039b…` 的缺口均为旧版本事实，不能沿用为
这个已核对版本仍永久缺失的结论。

| 项目 | 2026-09-06 `4f13039b…` 历史发现 | 2026-10-11 固定 `7963bc0d…` 源码证据 | 仍需独立证明 |
| --- | --- | --- | --- |
| 空白设备正式入口 | 缺完整安装/Controller 准备入口 | 已有 [install-clean-device.sh](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/deploy/install-clean-device.sh)、[prepare-clean-host.py](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/deploy/prepare-clean-host.py) 及 [安装指南](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/docs/deployment/clean-device.md) | 指定设备实际完成哪些阶段；不能由文件存在推定现场已安装 |
| 跨组件网络和地址 | production Compose 缺共享网络，示例地址不可用 | [正式 Compose](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/docker-compose.prod.yml) 声明 default external `cf-internal`；安装器渲染 enabled WeChat `http://cf-agent-wechat:6174` 和批准 Hermes URL | 实际容器网络、端点和认证；`config/production.yaml` 仍是 disabled 示例，须区分模板与正式渲染结果 |
| 镜像来源和依赖记录 | 示例 registry 不可部署；固定 Git SHA 不保证可复现构建 | 正式 `build` 阶段记录基础镜像 digest、Gateway SHA、依赖解析结果及实际 Image ID，配置使用该 Image ID | 指定设备的实际记录；不承诺逐字节可复现，也不推断已有公开发布镜像 |
| PostgreSQL/首次迁移 | 外部依赖与空库流程未形成完整安装资产 | 已有 [独立 PostgreSQL Compose](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/deploy/postgres/compose.yml)、managed/external 输入与 database/migrate/start 阶段 | 实际 DB/迁移/readiness，真实 Hermes 与 WeChat 验收分别记录 |
| 开机组合 Gate | 历史 reboot 不能保证 Worker 保持停止 | [core unit](https://github.com/Tangbohu09527/CF_agent-gateway/blob/7963bc0db5a01e38099e021959feabf648db7ede/deploy/systemd/cf-agent-gateway-core.service) 在 Docker ready 后 `ExecStartPre` 调用 Controller stop | Docker 启动到 stop 之间仍有调度窗口；automatic boot stop gate 未证明，boot 后仍须显式确认/关闭 Gate |

上述首次安装资产的引入提交为
[`997e1c42e91a6bfac4c0a8e013ef283f00d30bbd`](https://github.com/Tangbohu09527/CF_agent-gateway/commit/997e1c42e91a6bfac4c0a8e013ef283f00d30bbd)
（2026-09-06）；本轮只读核对的是上述固定 main 内容，不宣称其所有 CI 或现场验收通过。

用户报告 2026-10-11 Gateway d9 新 plan 通过后执行了 CFserver reboot。该报告与
GitHub 源码核对属于不同证据，不能据此认定现场部署了 `7963bc0d…`，也不能代替
重启后的微信容器、登录、API、Poll/Delivery Gate，以及入站 PDF/原图验收。
这些现场项目本轮均未复验；本仓库负责微信通道与上游适配，不实现 Gateway 队列、
文件理解或分类。

## 2026-09-06 固定来源与已执行检查（历史）

GitHub API 查询 `branches/main`、完整递归 Git tree、固定提交的文件和 Releases：

| 仓库 | 当时固定 main | Git tree | 可见性 |
| --- | --- | --- | --- |
| Gateway | [`4f13039b86c60bc94340edb5468f0102d62d2dff`](https://github.com/Tangbohu09527/CF_agent-gateway/commit/4f13039b86c60bc94340edb5468f0102d62d2dff) | `d0c83ea8842d97ada066abbfb975f4c05c8a7d9b` | public |
| 总文档 | [`8f51cd095c6967f806701b703281b08e5144296f`](https://github.com/Tangbohu09527/CF_ecommerce-automation-docs/commit/8f51cd095c6967f806701b703281b08e5144296f) | `1ff9fab6ba5867eee7520a48daae75e11abf7659` | public |

两个 tree 均返回 `truncated: false`，两个仓库的 Releases API 均返回空列表。
这说明没有 GitHub Release 附件，不等于证明所有外部 registry 均没有镜像。

已匿名读取固定 Gateway Controller 原文件，HTTP 200，21580 字节。原文件身份：

- Git blob SHA-1：`3039481583437d95e512925fcfdc3c0b51944d08`。
- SHA-256：`c28d9a97157b7551d91b6ee8e29396fd6b7807670c85b470a0b522f7d4b0c7f6`。

本机 Python 3.12 用 `-I`、空子进程环境、只包含原 Controller 文件的临时目录执行
`contract`，退出码为 0，stderr 为空，输出为：

```json
{"contract_version": 1, "delivery_worker_service": "delivery-worker", "dispatch_worker_service": "dispatch-worker", "poll_worker_service": "worker", "token_container_path": "/run/secrets/cf-agent-wechat-auth-token", "token_mode": "file"}
```

这项已执行检查证明静态 contract 不需要 `.env`、Token、Docker、PostgreSQL 或运行中
Gateway。它在 Windows 本机执行，不证明 Linux 文件权限、Compose 网络或容器就绪；
Linux 权限和安装验收必须记录各自的实际结果。

## 首次部署顺序应分开处理

真实 Controller 的 [`_contract()` 与 action 分发](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/deploy/wechat-runtime-control#L589-L627)
直接返回常量，不调用 Docker。Gateway 的[公开契约说明](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/wechat-runtime-contract.md#L21-L49)
也明确区分静态查询和需要 Docker、受保护配置及 Token 权限的生命周期查询。

因此首次部署可以按以下依赖关系组织：

1. 安装主机依赖和固定提交代码，按正式属主与权限安装 Controller 文件。
2. 普通管理用户完成 sudo 授权，受控读取静态 contract；不要求 `ready: true`。
3. 准备网络和 WeChat 配置，通过 WeChat Bootstrap 安全创建或验证 Token 与目录。
4. 按 Gateway 所有权准备配置、独立 PostgreSQL、构建镜像、迁移并启动 Gateway/Dispatch。
5. 检查普通管理用户 dry-run，确认 Controller 能关闭 Poll/Delivery Gate。
6. 交互式 fresh QR、认证和 API 检查，确认外部 Hermes 可达，再按现有流程打开组合 Gate。
7. 验收文本闭环、正常停止/再次启动、Host reboot 后 fresh-QR 恢复。

这是一份依赖顺序说明，具体执行入口见本仓库安装说明。下述 Gateway 历史缺口与后续
资产进展须按前述版本对照阅读；不能把准备步骤的静态 contract 成功写成 Worker 已经 ready。

总文档[现有顺序 4.4/4.5](https://github.com/Tangbohu09527/CF_ecommerce-automation-docs/blob/8f51cd095c6967f806701b703281b08e5144296f/deployment/deployment-guide.md#L49-L63)
先要求 Controller ready/Token contract，后执行 WeChat Bootstrap。它基于已准备的
生产依赖，不能作为空白设备首次安装顺序。首次安装必须将“安装文件/静态 contract”
与“Token 校验/运行时 ready”拆开，不得造一个 ready Controller 绕过顺序问题。

## Gateway `4f13039b…` 历史缺口与复现证据

以下四项保留 2026-09-06 审计原始发现和当时提出的修复范围，所有链接固定到旧版本；
其现在是否适用须看实际选定版本，不能仅凭这些历史段落推断当前 main 或现场状态。

### 1. 生产 Compose 尚未提供跨组件网络配置

Gateway [`docker-compose.prod.yml` 全文件](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docker-compose.prod.yml#L1-L237)
没有 `networks` 定义，使用 Compose 默认项目网络；WeChat 使用 external `cf-internal`。
默认 Gateway 容器因此没有加入 WeChat 网络。Gateway 的[示例配置](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/config/production.yaml#L32-L42)
还将 WeChat、Hermes 设为 disabled，WeChat 地址为容器自身的 `127.0.0.1:6174`。
只运行两仓库原版 Compose 不会自动形成可用的跨容器地址与网络。

Controller [固定生产 Compose 路径](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/deploy/wechat-runtime-control#L35-L36)，并在
[`_compose()`](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/deploy/wechat-runtime-control#L166-L187)
显式传入单个 `--file`。仅用进程 `COMPOSE_FILE` 环境变量或另一个命令的 overlay，
不能使 Controller 使用同一份叠加配置；其 `start` 会按固定文件重新创建受控容器。

Gateway 配套修复应在自身正式部署资产中声明/校验 external 网络及容器地址，保证
安装、迁移、Gateway/Dispatch 和 Controller 全部使用同一份有效配置。不得在 WeChat
复制 Gateway Compose，或依靠部署后的 `docker network connect` 隐藏补丁。

### 2. 缺少针对空白主机的生产准备入口

完整 tree 中 `deploy/` 仅有 Controller 和两个 systemd unit。
当时的[生产 runbook](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/production.md#L39-L105)
假定批准的管理身份、证据目录、代码、受保护 `.env` 和渲染配置已经存在；
[pre-deployment gate](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/production.md#L111-L131)
还要求先前 Release、数据库 revision 与备份。唯一含首次安装步骤的 Debian 文档已
[明确归档且禁止用于当前生产变更](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/staging-debian.md#L1-L14)。

Gateway 应新增幂等的生产准备入口及验收，负责自己的固定代码/Controller 安装、
配置模板渲染、独立 API/Admin Secret 生成/验证、权限校验与阶段错误。必须拒绝危险
symlink 或已有配置冲突，保留已有有效 Secret 和业务数据。管理用户 UID/GID 不能与
容器服务身份混淆；现有[容器身份](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docker-compose.prod.yml#L3-L9)
及 [Token 文件身份](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/wechat-runtime-contract.md#L88-L101)
为 `10001:10001`，不能通过授予管理用户 root/docker 组来解决。

### 3. 有源码构建资产，缺少可直接取用的正式镜像引用

[`.env.example`](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/.env.example#L27-L30)
的 `CF_GATEWAY_IMAGE` 是 `registry.example.com` 占位符，不能部署。
[历史生产记录](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/production-status.md#L19-L31)
只有本地 tag、裸 digest 及历史源码快照；[离线归档路径](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/production-status.md#L96-L127)
指向旧主机，不能作为新设备下载来源。

仓库已有可执行的 [`docker/Dockerfile`](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docker/Dockerfile#L1-L27)，
固定 Gateway 提交的干净源码可以用 `docker build --file docker/Dockerfile ...` 本地构建，
无需旧 daemon 的 tag。该路径仍须在实际验收中执行并记录生成的 Image ID。基础镜像
是浮动 `python:3.12-slim`，而 [`pyproject.toml`](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/pyproject.toml#L1-L19)
采用依赖版本区间；完整 tree 未提供依赖锁文件。固定 Git SHA 因而不保证字节一致的
镜像构建。Gateway 配套入口应锁定或记录基础镜像 digest、依赖解析版本、构建提交及
结果 Image ID，或提供可获取的 registry 完整 digest 引用。

本审计没有执行 Docker build/pull，不声称历史生产裸 digest 可公开拉取，也没有
发布镜像、创建 Tag 或从旧机器导出镜像。

### 4. PostgreSQL、Hermes 输入应明确，不能藏成现场前置资产

Gateway [正式边界](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/production.md#L25-L37)
将 PostgreSQL 和 Hermes 作为外部组件，这是应保留的所有权边界。
其[必要配置](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/production.md#L80-L96)
包括 PostgreSQL URL、两个独立 HTTP Secret、Hermes endpoint/API key、WeChat endpoint
和 Token 文件。首次安装入口必须验证配置解析、容器网络可达性、空数据库迁移及
Gateway/Dispatch readiness，不能只要求“恢复旧数据库 readiness”。

如首次部署基线选择自建 PostgreSQL，应由拥有该组件的独立部署资产明确版本/digest、
初始化用户/数据库、安全配置、持久化及启动入口；不能在 WeChat 仓库复制实现。
如使用外部已供应 PostgreSQL，必要输入必须写清数据库端点、独立凭据、TLS/网络规则及
迁移权限。Hermes 必须提供批准的端点、认证和实际调用能力，不需要本任务登录其主机。

Gateway 的[容器 E2E](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/tests/container/docker-compose.e2e.yml#L1-L74)
已有真实 PostgreSQL 和应用容器，但 WeChat 为 synthetic fixture；
[测试 runner](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/tests/container/run_compose_e2e.py#L834-L888)
直接准备测试 Token、配置和构建环境。它可证明容器契约，不能替代正式安装入口的
空白主机验收或真实微信/Hermes 验收。

## 可重复的历史来源检查

下面保留 2026-09-06 的复现入口：读取公开 GitHub、向临时目录保存旧版本快照，
并执行旧 Controller 的静态 contract；不修改任何部署或仓库。本轮文档更新未执行它，
其 `networks=absent` 断言仅适用于代码中固定的 `4f13039b…`。
需要 Python 3，网络可匿名访问 `api.github.com` 和 `raw.githubusercontent.com`。

```bash
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

repo = "Tangbohu09527/CF_agent-gateway"
commit = "4f13039b86c60bc94340edb5468f0102d62d2dff"
raw = f"https://raw.githubusercontent.com/{repo}/{commit}/"
api = f"https://api.github.com/repos/{repo}/"

def get(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()

tree = json.loads(get(api + f"git/trees/{commit}?recursive=1"))
assert tree["truncated"] is False
print("gateway_commit=" + commit)
print("deploy_files=" + ",".join(
    entry["path"] for entry in tree["tree"]
    if entry["type"] == "blob" and entry["path"].startswith("deploy/")
))
source = get(raw + "deploy/wechat-runtime-control")
assert hashlib.sha256(source).hexdigest() == (
    "c28d9a97157b7551d91b6ee8e29396fd6b7807670c85b470a0b522f7d4b0c7f6"
)
with tempfile.TemporaryDirectory(prefix="gateway-source-audit-") as temporary:
    controller = Path(temporary) / "deploy" / "wechat-runtime-control"
    controller.parent.mkdir()
    controller.write_bytes(source)
    result = subprocess.run(
        [sys.executable, "-I", str(controller), "contract"], cwd=temporary,
        env={}, capture_output=True, text=True, timeout=5, check=True,
    )
    assert not result.stderr
    assert json.loads(result.stdout) == {
        "contract_version": 1, "delivery_worker_service": "delivery-worker",
        "dispatch_worker_service": "dispatch-worker", "poll_worker_service": "worker",
        "token_container_path": "/run/secrets/cf-agent-wechat-auth-token",
        "token_mode": "file",
    }
    print("original_controller_static_contract=pass")

compose = get(raw + "docker-compose.prod.yml").decode()
assert not any(line.lstrip().startswith("networks:") for line in compose.splitlines())
print("gateway_production_compose_explicit_networks=absent")
assert "registry.example.com" in get(raw + ".env.example").decode()
print("gateway_example_image=placeholder")
PY
```

## Gateway 配套变更的独立验收范围

配套 Gateway 变更在自己的分支/PR 中完成，本 WeChat 文档 PR 不修改其仓库。
下列是独立验收范围，不表示 2026-10-11 本轮已执行或通过：

- 干净 Debian 13 amd64，从固定源码执行正式准备/构建入口，安装 root:root 0750
  Gateway 根目录及 root:root 0755 deploy/Controller；非 root、非 docker 管理用户可
  通过受控 sudo 在 Secret/DB/Docker 启动之前读取静态 contract。
- 幂等准备自己的配置/Secret；重复运行和中途失败重试不覆盖有效 Secret、Token、
  Session 或业务数据。安装前后记录配置版本、依赖版本及镜像实际来源。
- 真实 Controller 与所有 Gateway 服务使用同一份包含正式 external 网络的配置；
  实际从容器验证 PostgreSQL、WeChat 和 Hermes 端点。无需手工网络连接或现场 overlay。
- 空数据库经正式 migration 到单一 head，Gateway/Dispatch 可以在 Poll/Delivery
  Gate 关闭时启动；Controller 仅管理 worker/delivery-worker，不启动 Dispatch。
- 与 WeChat 正式 Bootstrap/dry-run/fresh-QR 流程协同；自动化可使用明确标注的模拟
  微信/Hermes，但真实微信扫码、真实 Hermes 文本回复、停止/再次启动及 Host reboot
  恢复必须逐项记录。未执行的真实项目写“待人工验收”。

2026-09-06 审计定位的跨库缺口与 2026-10-11 核对的后续资产分别保留，没有把它们
当成 WeChat 管理脚本权限修复通过的前提或结果。任何 A（代码/回归）、B（干净 Linux
安装）、C（真实扫码/Hermes）报告都应分别说明执行范围，不能将静态源码核对或历史
生产记录代替 B/C，更不能代替真实微信入站 PDF/原图字节验收。
