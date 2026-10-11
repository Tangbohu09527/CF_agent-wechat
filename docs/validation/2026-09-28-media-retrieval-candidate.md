# 微信附件取件：固定上游升级候选

2026-09-28 核验结论：历史镜像的媒体 GET **只读缓存，不触发文件下载**；图片先取缩略图。
修复位置在上游 `agent-wechat`，不在本项目生命周期脚本。采用已有修复的固定完整
制品作为升级候选，在隔离环境验证。该候选任务没有部署、合并、修改生产配置或运行生产容器，
没有连接 CFserver、读取聊天/凭据、扫码、重派历史任务或改变历史失败记录。

> **2026-10-11 文档状态补记**：本页对应 `codex/fix-wechat-original-media` 的固定
> 候选基线 `9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a`，不是现场升级记录。
> `main@81d21f451adc61df71077ca3035adeddeca4621f` 已有功能与未合并媒体候选须分开。
> 用户确认在 Gateway d9 新 plan 通过后执行了 CFserver reboot；微信容器、登录、API
> 及 Poll/Delivery Gate 尚未复验。2026-09-03 的 production online 是历史验收，
> Gateway plan 或隔离 CI 通过都不能替代 WeChat 入站 PDF/原图验收。
> 状态、精确 CI 来源及待验收矩阵见[生产状态](../production-status.md)。

## 工作树和证据范围

- 工作树：本项目 `a949/CF_agent-wechat`；初始 detached HEAD 为
  `81d21f451adc61df71077ca3035adeddeca4621f`，无本地修改。
- 先检查工作树、分支、HEAD、修改，再 fetch；`origin/main` 仍为上述提交。
  从该完整基线建立 `codex/fix-wechat-original-media`，没有回退或删除已有内容。
- 只查看本项目 Git 元数据；没有访问另外三个项目的活动工作树。
- [Gateway Issue 13](https://github.com/Tangbohu09527/CF_agent-gateway/issues/13)
  是本轮现场证据来源，其开发状态文字为历史快照。PDF/图片都已入 Gateway 且分别
  派发；不重复修空正文 guard，不重做队列、Hermes 桥接或 FileBridge 下载器。
- 原 PDF 两次相隔约 10 分钟均为 HTTP 200、`pending`、无 data/url；图片取得 JPEG，
  与源样本大小/摘要不同。无需重新发送这两份样本来证明已知问题。

## 固定制品与源码

完整摘要、镜像/源码校验值见
[media-retrieval.lock.json](../../upstream/media-retrieval.lock.json)。锁文件仅用于隔离
验收，没有被生产 Compose 或安装脚本读取。候选版本按该锁文件 `release=0.15.1`
描述，不称为当前最新版本或生产现用版本。

| 项目 | 历史现场引用 | 升级候选（仅 linux/amd64 已审计） |
| --- | --- | --- |
| 版本 | v0.11.15 | v0.15.1 |
| OCI index digest | `sha256:31a4e351c191bcbfc75e5c10be51e207d22a3eedd97f3ff56ad579fcce717b24` | `sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43` |
| amd64 manifest | `sha256:b5e92047e28ce67e34576e574d8ccf00f8619f485597109f7342a137300285c0` | `sha256:51b6d9ccfae344dd2fb60d9c37d3a089f884658f3d818fcd37a51eef48a63658` |
| provenance source revision | `3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616` | `96c2e90c497d999bf5189a134a9b3b293731f42e` |
| media-download.py / .js | 工具层不存在 | 存在，逐字节匹配固定源码 |

通过匿名公开 OCI registry 下载并核对 index、子 manifest、config、provenance 和相关
layer 的 SHA-256。源码 revision 来自 BuildKit provenance 的
`predicate.runDetails.metadata.buildkit_metadata.vcs.revision`，不是浮动标签推测。
历史 config 没有 source/revision label，因此没有把 Ubuntu label 当应用版本。
历史 server 字符串中的媒体源文件/行号也与固定源码吻合。相关上游构建记录：
[历史构建](https://github.com/thisnick/agent-wechat/actions/runs/23874698754)、
[候选构建](https://github.com/thisnick/agent-wechat/actions/runs/36276886277)。

候选 `/opt/wechat/wechat` ELF Build ID 为
`ce28c3471d532eeb1f136482eeb4d0bdfd59c06e`，在该制品原生 helper 的允许列表中。
已静态核对二进制、helper 和 Build ID；这不证明已登录客户端的原生调用成功。
不把 amd64 核验外推到 arm64，也不把固定公开制品核验当作再次检查了运行容器。

## 实际根因与取件路径

历史固定源码：
[router/messages.rs](https://github.com/thisnick/agent-wechat/blob/3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616/packages/agent-server-rust/src/router/messages.rs#L82)
的 `get_media` 只加载 keys，再调用
[wechat_media.rs](https://github.com/thisnick/agent-wechat/blob/3b7de890eb1fd3a16cf9cf26dbe1c20e0f88a616/packages/agent-server-rust/src/tools/wechat_media.rs#L867)
的缓存读取。普通文件为 `local_type=(6<<32)|49`，读取路径为：

```text
/home/wechat/xwechat_files/<account>/msg/file/YYYY-MM/<XML title>
/home/wechat/Documents/xwechat_files/<account>/msg/file/YYYY-MM/<XML title>
```

月份来自消息 `create_time`。文件存在且可读才 base64 返回；缺失或读取失败均返回
`pending`。该状态没有 download queued 的含义。继续 GET 只重复查同一缓存，不会
启动下载；这解释了现场长时间 pending。没有现场文件系统证据时，不能进一步断言
是完全没落盘、路径不匹配还是不可读。

历史图片首先返回 cached JPEG thumbnail；resource DB 的备用查找仅尝试普通 `.dat`
和 `_t.dat`，没有 `_h.dat` 原图选择或质量标签。因此接口能给 JPEG 不代表源原图。
具体现场 JPEG 属于哪一层仍未知，摘要不同不能单独区分发送转换、标准图和预览图。

候选固定源码的完整链路：

1. [router/messages.rs](https://github.com/thisnick/agent-wechat/blob/96c2e90c497d999bf5189a134a9b3b293731f42e/packages/agent-server-rust/src/router/messages.rs#L126)
   先查缓存，无可用字节时从消息数据库提取完成消息的原生元数据。
2. [download_metadata](https://github.com/thisnick/agent-wechat/blob/96c2e90c497d999bf5189a134a9b3b293731f42e/packages/agent-server-rust/src/tools/wechat_media.rs#L103)
   校验类型、账号/发送者、title、totallen、MD5；缺少合格元数据不会伪造任务。
3. [media_download.rs](https://github.com/thisnick/agent-wechat/blob/96c2e90c497d999bf5189a134a9b3b293731f42e/packages/agent-server-rust/src/tools/media_download.rs#L35)
   绑定当前账号、PID、进程启动标识，通过 Python/Frida helper 提交；校验完整 Build ID。
   普通文件使用原生 resource 103，PDF/Office 共用这一条路径。
4. WeChat 原生服务下载并写入本地缓存。server 持有提交任务；HTTP 断开不取消提交，
   同一消息有 300 秒提交去重。提交成功不等于取得字节。
5. [get_file_attachment](https://github.com/thisnick/agent-wechat/blob/96c2e90c497d999bf5189a134a9b3b293731f42e/packages/agent-server-rust/src/tools/wechat_media.rs#L1068)
   重新读取实际文件，检查消息声明长度和 MD5，匹配才原样 base64。无字节或不匹配
   继续不可用。这里没有 PDF/Office 内容解析。

上游本身仍有诊断限制：元数据缺失、原生进程不匹配或 helper 拒绝可能仍表现为
pending/无 data，不能仅凭 HTTP 响应区分失败原因。未伪造 ready，也未增大超时。

| 证据层级 | 所需观察 | 不成立的替代证据 |
| --- | --- | --- |
| 附件元数据 | 消息类型/ID、title、声明长度/摘要；按私密数据处理 | 文件名、卡片或文字回复不等于取得文件 |
| 下载触发 | 固定候选的合格元数据与 native 提交/拒绝结果 | 历史 GET、HTTP 200、`pending` 均不证明正在下载 |
| 缓存命中 | 实际缓存路径可读；候选普通文件与消息声明长度/MD5 匹配 | 已有缓存不证明本次触发过 native 下载 |
| 完整字节取得 | Base64 解码或实际取回 url 的字节，核对大小/摘要 | 返回字段存在或请求成功，不等于完整内容可读 |
| 发送前原件一致 | 与发送前样本逐字节比较或核对大小/SHA-256，记录转码 | 消息声明 MD5、图片 full 层级、扩展名不单独证明发送前原件一致 |

这几层必须分别记结果。候选 GET 在条件满足时可能提交下载并写入缓存；历史 GET
仅重复查询缓存，因此不能把二者一概视为只读查询，也不能把 pending 当成进度状态。

## 最小修复选择

选定完整固定候选，而不把原生 offsets 回填旧微信客户端：原生 helper 对完整
Build ID 有严格限制，只替换旧容器 binary/helper 无法证明兼容。本仓库新增来源锁、
离线校验、针对真实上游函数的隔离回归和本记录，不修改现有生产镜像配置。

上游相关修复提交：`93cdb048`（质量和文件身份校验）、`641367c3`（原生 DM 下载）、
`286f21af`（群/发出消息）、`a71cf8b6`（图片分级）、`9f524a5b`（默认 best）、
`b6c30da2`（非图片兼容）。固定候选包含这些修改。

完整版本升级还包含语音等无关变化及 `V3__voice_jobs.sql` migration，因此这是
**待现场验收的固定升级方案**，不是可无条件滚动升级的热补丁。没有运行生产 migration。
后续任何上线须另行授权，并遵循本项目 fresh QR 生命周期。2026-09-28 未操作已有
登录；该历史事实不代表 2026-10-11 reboot 后登录仍有效。保持 `restart: "no"`，
Archive 不得恢复活动 Session；automatic boot stop gate 未被证明，重启后必须显式
stop/confirm，不能承诺 Gate 自动关闭。

## 图片及格式状态

聊天展示用默认/显式 `quality=best`：选择 full、standard、thumbnail 中可用最高层并
报告质量，可以展示预览，不要求用户改成文件卡片重发，也不自动入正式文件库。
资料存取用严格 `quality=full`；缺 `_h.dat` 时不能用标准图或预览图满足原图请求。

必须同时记录请求质量、响应质量和实际字节证据：候选显式 full/standard/thumbnail
的响应 `quality` 通常缺失（None 被序列化时省略，也应兼容 null）；显式 full 未取得时
也可能 `type=image` 而 data/url 缺失或为 null。必须实际解码 data 或取回 url 字节；
只有字段、HTTP 200、文件名或 `supported=true` 不算取件成功。
`quality=full` 仅代表原图缓存层级；WXGF 会转成
JPEG/GIF，仍需对比源样本 SHA-256 才能称逐字节原件；转码结果必须标注。
未发送 Original 的普通图，其标准图依赖微信已缓存内容；media GET 不选择聊天。

| 候选图片层级 | 固定选择规则 | 不可外推的结论 |
| --- | --- | --- |
| `best` | 按 full → standard → thumbnail 选择可用最高层 | 允许预览降级，不保证 full 已取得 |
| `full` | 只选 `_h.dat` | 原图缓存层不保证与发送前文件逐字节一致；可能发生 WXGF 转码 |
| `standard` | 只选普通 `.dat` | 标准图不能作为 full 验收 |
| `thumbnail` | 只选 `_t.dat` | 缩略图不能作为 standard 或 full 验收 |

| 格式 | 原始字节取得状态 | 内容解析状态 |
| --- | --- | --- |
| PDF | 2026-09-28 记录的现场失败保留；候选通用取件路径，待现场验证 | 未验证；文件名/文字回复不算解析 |
| Word `.docx` | 候选通用取件路径；待现场验证 | 本服务不解析；现有下游能力另验 |
| Excel `.xlsx` | 同上 | 同上 |
| PPT `.pptx` | 同上 | 同上 |
| 旧 Office `.doc/.xls/.ppt` | 同一通用字节路径，不按扩展名静默拒绝；待现场验证 | 本服务不提供旧 Office 解析器；下游未验证 |
| 其他普通文件 subtype 6 | 同一字节路径；待现场验证 | 未支持/未验证须明确报告 |
| 其他 appmsg subtype、表情等 | 不保证通用原件路径支持；需明确 unsupported/不可用 | 未验证，不静默丢弃 |
| 图片聊天展示 | 2026-08-14 历史样本取得 5712 字节 JPEG；层级未知；候选 best 分级待现场验证 | 可解码展示不等于视觉/OCR 已解析 |
| 图片原图 | 现场未证明；strict full 及 SHA-256/转码核对后才能确认 | 未验证 |
| 图片标准图/预览图 | 候选区分层级；不能冒充原图 | 未验证 |

本仓只负责通道与上游适配；上述通用字节路径不实现 PDF/Office 内容理解、分类或
Gateway 队列。Gateway d9 新 plan 通过只能作为其自身版本的证据，不能填平此矩阵的
微信入站取件和下游解析空白，也不能把早期 Gateway 缺口写成所有版本的永久现状。

## 隔离验证

[工作流](../../.github/workflows/media-retrieval-candidate.yml) 固定源码提交、镜像 digest，
下载并创建停止的容器抽取 binary/helpers/client，校验摘要和 Build ID；不运行镜像
入口，不挂生产数据。另一个无网络、只读、无登录数据的临时容器仅检查运行依赖。

- 2026-09-28 本地记录：固定源码身份校验通过；Python 媒体 helper 11 项、Node 调度
  4 项通过。2026-10-11 文档任务未重新运行这些功能测试。
- CI：`cargo test --locked` 执行上游测试，并加入
  [6 项缓存契约测试](../../tests/upstream/media_cache_contract.rs)，直接调用上游
  `get_file_attachment`。两根目录、8 类扩展名、中文/空格、月份、缺文件/截断/错摘要、
  路径边界、重复读取及图片质量后缀均覆盖。
- fixture 是合成二进制；正确数据落盘后 Base64 逐字节相等，只证明真实缓存读取函数，
  **不证明原生下载已在微信完成，也不证明 PDF/Office 内容解析**。
- 2026-10-11 核对的候选 CI：head SHA
  `9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a` 的 push
  [run 36403240631 / attempt 1](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36403240631/attempts/1)
  为 `completed/success`；[job 108865816205](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/36403240631/job/108865816205)
  的固定身份、helper 和合成缓存检查成功。制品为
  `media-candidate-9b997ac92d653380a01ac93e0ac65e4a0e3a4c0a`（artifact ID `10961287330`）；
  本次只核对远端元数据，未下载或重新执行制品。
- 其他检查的状态独立记录在[生产状态](../production-status.md)；该 run 成功不代表
  分支所有检查“全绿”，不证明已登录微信 native 取件、发送前原件一致或现场升级。

## 一次交给操作者的最小现场检查

以下尚未执行；涉及已登录微信/私密标识的检查由操作者授权执行。无需重新发送原
PDF/图片来证明故障。仅限指定样本和必要状态，禁止列全部聊天、打印 Token/XML、
重新扫码、重派历史任务或改变历史失败记录。

1. **身份**：记录运行 Image ID/RepoDigest、server 摘要、微信 ELF Build ID、helper
   是否存在。原因：确认实际实例是否仍为历史制品，避免把候选 API 契约套到旧版。
2. **既有样本**：在操作者本机保留原 PDF/图片的 chat/local/server ID 映射，对外用
   样本代号。记录消息类型、创建月份、声明长度/摘要是否齐全，不输出正文/XML/凭据。
   原消息 GET 只作限定复核，不能重派。
3. **四个断点**：对限定文件记录缓存存在/可读 → native 是否提交/拒绝 → 实际写入
   路径和长度 → GET Base64 解码字节。候选 GET 会触发下载并改变微信缓存，操作者
   授权需包含这一副作用；上游日志可能含标识，不直接上传原始日志。
4. **完整性及图片**：解码到受控临时目录，记录类型/大小/SHA-256 与原样本是否匹配。
   图分别检查 best/full/standard/thumbnail 的请求、响应质量、可解码性和转码状态；
   只给预览时聊天可展示，原图状态仍未满足，不自动归档。
5. **扩展格式**：用已有 Word/Excel/PPT/旧 Office 样本复用同一文件步骤，无样本写
   “待验证”。内容解析独立记录支持/不支持/未验证，不能用字节成功替代解析结果。

新制品的真实 native 下载须在另行授权的隔离已登录验收环境完成；不得挂载生产
Runtime/Archive/Token，不得现场覆盖 binary、盲拉 latest 或重启现有生产实例。
若没有可用的隔离已登录环境，就保留“待现场验收”，不以模拟 pending→ready 代替。
