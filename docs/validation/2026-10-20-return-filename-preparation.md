# 微信原文件名候选现场准备（2026-10-20）

状态：**候选已复用并完成隔离核对，待独立授权后的现场实收验收**。本轮没有协议切换、微信登录、扫码、消息发送或生产连接。没有修改文件名实现，也没有重建仍有效的候选。

## 固定来源与兼容范围

| 对象 | 准确身份与结论 |
| --- | --- |
| 文件名候选 | PR9，`codex/fix-wechat-return-filename`，`7bd42b623d405956080a13481bbf4de21aa3477a`；2026-10-20 实时核对仍为 OPEN/Draft |
| 本轮准备分支 | `codex/docs-wechat-filename-prep-20261020`，base 为上述 PR9；仅新增本报告与脱敏证据，不混入安装器改动 |
| 后续管理组件 | PR11 `e56c7e4b606f1614e54210a391906f4be7440f5e`，是 PR9 后代；差异仅 9 个时区/准备入口/对应测试文档文件；文件名 overlay、packager、锁、原生探针及测试文件零差异 |
| 协议上游 | `thisnick/agent-wechat@96c2e90c497d999bf5189a134a9b3b293731f42e`；overlay 仍拒绝其他 revision、污染的 checkout 或错误输入摘要 |
| 固定运行基础镜像 | `ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43` |
| 基础 config / image ID | `sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e` |

总文档最后运行报告选择上述 upstream digest，管理源码含 PR9 不代表该运行镜像已启用原名修复。**本轮没有取得当前生产镜像/二进制身份，因此不宣称候选可以直接覆盖当前生产。** 不接管旧 forced-QR 暂存改动，不复用其旧操作要求。

完整早期实现和限制见 [PR9 固定报告](https://github.com/Tangbohu09527/CF_agent-wechat/blob/7bd42b623d405956080a13481bbf4de21aa3477a/docs/validation/2026-10-18-return-filename-candidate.md)。本轮机器可读证据为 [preparation.json](./2026-10-20-return-filename-preparation.json)。

## 产物已保存，不需要重新构建

精确分支源码的 [push run 39122064383](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/39122064383) 和独立 [PR run 39122067866](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/39122067866) 仍为成功。2026-10-20 API 核对两个准确 head 产物未过期，并已下载到本轮目录；原生/镜像构建是 10 月 18 日已有证据，本轮没有把它写成新跑的 Linux 构建。

- release artifact：`return-filename-release-7bd42b623d405956080a13481bbf4de21aa3477a`，ID `12135116056`，8,631,490 字节，原 GitHub ZIP digest `sha256:1891ba2a86eb78325c0387e752ae075bb1b681c0371d42bb0fc4f3c5bfd0442c`；到期为 **2026-11-01 19:12:58 北京时间**。
- native artifact：`return-filename-7bd42b623d405956080a13481bbf4de21aa3477a`，ID `12134931583`，5,113 字节；到期为 **2026-11-01 19:12:24 北京时间**。
- 本机 release：`D:\Tangbohu09527\.cf-worktrees\wechat-filename-prep\artifacts\release-7bd42b6\release`。
- 本机 native 证据：`D:\Tangbohu09527\.cf-worktrees\wechat-filename-prep\artifacts\native-7bd42b6`。

本轮从下载文件重新计算并核对了下列摘要、包内全部四个成员与解包 context 字节一致、`SHA256SUMS` 全项一致。GitHub ZIP digest 是 API 元数据；重新核对的是下载后内层包和文件，不声称又核验了一份未保留的外层 ZIP。

| 文件 | SHA256 |
| --- | --- |
| `return-filename-overlay.tar.gz` | `a737b67ee4c4fa5733dd64f391b40c16ee3cc093b69207d94052e3925a370854` |
| `release-proof.json` | `a95314739a2ef0588a8f7d01e924a2e3f998bed5c90904da71ff2134b1791fbd` |
| `agent-server` | `98b3176d44bb5dd03b045591348fb51474f2208a1ac7fb595c11ad3fdd628408` |
| `paste-file` | `6f36f76b5c0194c990a49199f064e01a4bb87d48e93f876db02e7c5a54ad654d` |

这是 Linux amd64 的两文件 rebuild context，不是已经发布的 registry 镜像。已有 CI 镜像 ID 是 `sha256:1ae2c63e3fe57780cf9d7b64d55f2f473d212aa80cd26ce0abd33b0ee514face`；不能据此指定另一台机器重建后必须得到相同 ID。官方锁定 Cargo 依赖、Rust 1.93.0、Ubuntu 22.04.5 构建，实际最高 GLIBC 要求为 2.34，既有固定运行镜像 loader 已在 network=none/read-only 条件下解析全部依赖。没有执行微信 entrypoint，未验证服务健康和实际收件。

只替换 `/opt/agent-server/agent-server` 与 `/opt/tools/paste-file`。WeChat 可执行文件、原媒体工具、基础层及 entrypoint/command/env/user/volume/healthcheck 均由原 CI 比较保持；未来重建仍须重新检查。不得直接把 Windows checkout 中可能经过 CRLF 转换的 helper 拷进镜像，使用已核对的 artifact 字节或在受控 Linux runner 用固定源码重建。

## 本轮定向验证与复用证据

本轮在独立工作树、独立固定上游源码副本上重新运行：8 项 overlay 测试、6 项 release 包守卫全部通过，`apply-return-filename.py --check-only` 接受准确且干净的上游输入。另以 Git 原始 blob（消除 Windows 工作树换行转换）重算六个转换输出，全部与原生和 release proof 摘要一致。

本轮还核对实际发送目标关联：转换前后 `SendMessageParams` 构造块完全相同，`chat_id: input.chat_id` 不变；`SendMessagePlan` 在 File 阶段之前完全相同，保留 `open_chat(&params.chat_id, ...)`。这证明本次文件名 overlay 未改变目标参数和选群实现，**不代替微信 UI 正确选中会话和收件的现场证据**。

复用且读取了准确 head native log 的 9 项通过结果：

- 合法中文、空格、括号、重音、emoji 与 `%/#`；原 basename 和原字节保留，非法路径/控制符/过长名被拒绝。
- 24 个并发同名不同内容各用独立父目录，不覆盖、不串字节；只清理各自创建的文件及目录。
- 实际 `paste-file` 的 ASCII 百分号编码 UTF-8 URI 经真实 Qt 5.15.13 在 `LC_ALL=C` 解码；不同低权限 UID 读取原 basename 与原字节。
- 失败 paste 不按 Return；成功/失败、HTTP waiter 取消、排队取消/超时的文件生命周期测试。

剪贴板和按键均为测试替身，不是真实微信。Windows 本轮没有重跑 Linux Rust/Qt 或 Docker loader；以上 native 行为依据未变输入与下载的准确旧 CI 结果复用。图片代码的原有零差异检查保留；PNG 业务口径不重开。

本机可重新执行的只读检查：

```powershell
Set-Location 'D:\Tangbohu09527\.cf-worktrees\wechat-filename-prep\CF_agent-wechat'
$env:CF_FILENAME_SOURCE = Join-Path (Get-Location) 'agent-wechat\filename-source'
python -m unittest discover -s tests -p test_return_filename_overlay.py -v
python -m unittest discover -s tests -p test_return_filename_package.py -v
python scripts/apply-return-filename.py --source $env:CF_FILENAME_SOURCE --check-only
Get-FileHash '..\artifacts\release-7bd42b6\release\return-filename-overlay.tar.gz' -Algorithm SHA256
```

没有依赖安装、微信/模型替身或后台任务，本工作线不需要停止进程。

## 现场最短验收方案（本轮不执行）

合成样本已准备在 `D:\Tangbohu09527\.cf-worktrees\wechat-filename-prep\acceptance-samples`，不是企业文件；`manifest.json` 保存每个文件的准确 basename、大小、SHA256 和目标标签。两套使用同名不同内容，可识别跨目标/覆盖错误：

| 目标标签 | 文件 | 大小 | 内容标识 |
| --- | --- | --- | --- |
| `private` | `中文 报告 (1).txt` | 79 字节 | `PRIVATE-A` |
| `private` | `资料 包 (2).zip` | 325 字节 | 两个成员，`PRIVATE-A` |
| `group` | `中文 报告 (1).txt` | 77 字节 | `GROUP-B` |
| `group` | `资料 包 (2).zip` | 321 字节 | 两个成员，`GROUP-B` |

1. 用户另行授权小范围切换后，现场人员先取得当前部署的不可变镜像/二进制摘要、配置和可恢复的回退入口，确认其真实身份。候选只支持上表固定来源；遇到其他基础镜像、架构或摘要差异即停止，不对未知版本强套 overlay。保留现有登录；仅在确实离线且用户参与时扫码，不能默认强制新 QR。
2. 在已获准的隔离 Linux/Docker 环境先核对 `context/SHA256SUMS`，仅用固定 Dockerfile 和固定 base 重建，记录新 image ID，重新抽取两个替换文件、核对辅助文件/微信本体和运行配置，执行无网络 loader 检查。若原 artifact 已过期，本机保存包仍可使用；本机包缺失或摘要不符才从准确源码和官方锁定依赖必要重建，不换成最新源码。
3. 由用户明确指定**一个测试私聊和一个测试群**，分别确认真实来源账号及稳定聊天 ID，现场先核对微信显示目标。实际请求沿获准的正常 Gateway/Delivery 路径，每次只发一个样本；私聊发送 `private` 两件，群聊发送 `group` 两件。不得用显示名称或上一次打开的会话猜目标，不把 `success=true` 当用户实收。
4. 用户在各自聊天中核对显示名恰为上述 basename，无 `send_file_`、时间戳前缀或中文替换；分别保存到独立下载目录，按 manifest 比对大小、SHA256、TXT 内容以及 ZIP 成员。确认私聊只收到 `PRIVATE-A`、群只收到 `GROUP-B`，同名不同内容没有覆盖/混发。记录每件任务/投递标识和收件截图；真实聊天标识/截图留在获准私有证据处，不提交 Git。
5. 发现错目标、字节不符、文件名变形或不明确结果时停止新增发送，不自动重试结果不明消息。若确需回退，由现场人员按第 1 步保存的真实旧镜像及配置执行经授权回退，保留登录和历史，不清 runtime、不删除资料。不能把固定 upstream digest 擅自当当前生产回退镜像。

通过标准是四件样本正确实收、可打开、basename 与内容/目标一致；没有现场记录时状态保持“待现场验收”。本准备工作未解决 ZIP 入站、旧纯配置可信任务关联/返回链缺口，也没有扩大 PNG 原字节验收口径。
