# Gateway 首次部署资产审计

本记录是本次 WeChat 权限修复的跨仓库只读审计，检查时间为 2026-09-06。没有连接
CFserver、AI 主机或读取现场配置；没有修改 Gateway 或总文档仓库。它不是干净 Debian
全栈安装通过的证明，也不替代真实扫码和真实 Hermes 回复验收。

## 固定来源与已执行检查

GitHub API 查询 `branches/main`、完整递归 Git tree、固定提交的文件和 Releases：

| 仓库 | 本次固定 main | Git tree | 可见性 |
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

这是一份依赖顺序说明，具体执行入口见本仓库安装说明；下述 Gateway 缺口仍须由
Gateway 配套修复解决。不能把准备步骤的静态 contract 成功写成 Worker 已经 ready。

总文档[现有顺序 4.4/4.5](https://github.com/Tangbohu09527/CF_ecommerce-automation-docs/blob/8f51cd095c6967f806701b703281b08e5144296f/deployment/deployment-guide.md#L49-L63)
先要求 Controller ready/Token contract，后执行 WeChat Bootstrap。它基于已准备的
生产依赖，不能作为空白设备首次安装顺序。首次安装必须将“安装文件/静态 contract”
与“Token 校验/运行时 ready”拆开，不得造一个 ready Controller 绕过顺序问题。

## Gateway 配套缺口与复现证据

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
当前[生产 runbook](https://github.com/Tangbohu09527/CF_agent-gateway/blob/4f13039b86c60bc94340edb5468f0102d62d2dff/docs/deployment/production.md#L39-L105)
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

## 可重复的只读来源检查

下面命令只读取公开 GitHub，向新的临时目录保存审计快照；不修改任何部署或仓库。
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

## Gateway 配套修复的独立验收范围

配套 Gateway 变更应在自己的分支/PR 中完成，本 WeChat PR 不修改其仓库。验收至少包括：

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

本次审计已定位跨库缺口，没有把这些缺口当成 WeChat 管理脚本权限修复通过的前提或
结果。任何 A（代码/回归）、B（干净 Linux 安装）、C（真实扫码/Hermes）报告都应分别
说明执行范围，不能将当前静态审计或历史生产记录代替 B/C。
