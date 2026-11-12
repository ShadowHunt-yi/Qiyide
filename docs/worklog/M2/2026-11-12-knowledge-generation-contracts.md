# 知识生成绑定输入版本，完整模块聚合与正常跳过

- 日期：2026-11-12（Asia/Shanghai）
- 类型：fix / refactor
- 里程碑：M2 · 知识生成正确性合同
- 依据：2026-11-11 的知识建设审查，以及用户在 2026-11-12 的“调整”。

> **同日后续纠正**：本记录的累计额度设计与旧状态预览在用户历史任务中暴露了“无法续跑、已处理显示 0”的缺陷。已另行改为每次明确启动的独立有限额度，并保留旧指标/观察/模块摘要，拆开文件理解与模块输出。详细证据和修复见 [建档预算续跑修复](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/worklog/M2/2026-11-12-curation-budget-resume.md)。本文件其余部分保留首次实现和验证的历史描述。

## What（改了什么）

1. **来源属于读取时的版本。** 用实际输入字节的 SHA-256 生成凭据，再从同一批字节摘录模型输入。模型返回后不再用当前 mtime/size 给旧结果盖章。缓存同时绑定内容、协议、端点、模型、温度、提示词、提取器与脱敏策略版本；不保存密钥。旧缓存可读，但缺少版本凭据时视为未命中。
2. **追加和替换有不同语义。** append 合并新旧来源和关系；replace 使用新版本的完整来源和关系，清除过期依赖及旧 AI 补充。人工编辑或确认过的原文仍不会被 AI 覆盖，只生成绑定原版本的更新建议。接受建议时再次校验输入和基线，原文留在 revisions。
3. **规范化文本与稳定定位。** 正文、Markdown 序列化、解析与摘要使用同一规范化函数。生成凭据使用排序键编码。更新优先使用稳定条目 ID；目标不存在或模型返回未知动作时，不兜底创建。
4. **只重读变化文件，但聚合完整模块。** 模块选择不再先删掉已处理文件；完整有效缓存与新观察共同参与模块生成。模块检查点绑定文件、目录成员、静态依赖、领域模型与有效人工知识。模块摘要缺少相应版本时不能进入跨轮上下文。
5. **合法的无产出。** 单条和模块支持 skip。无新判断不重试、不写占位条目。空文件可明确跳过；整模块均无可观察实现时无需再请求模块模型。跳过原因随版本保存，输入未变不重复调用；输入变化后重新入队。
6. **严格响应与统一脱敏。** 响应路径必须来自请求范围且唯一；缺失项记为部分失败，保留有效文件，模块输入不完整就不替换旧知识。所有生成入口共用脱敏。限制字段类型、长度和 frontmatter 单行值，拒绝越界或不可规范化的路径。
7. **按真实请求预留预算。** 每次初次请求与重试都在同一串行入口校验调用数、时长和模型策略，先持久化再发送。并发不能突破硬上限；缓存命中不计请求。缓存/检查点保存失败显式中止，不宣告完成，也不静默覆盖损坏文件。
8. **范围与文件证据分离。** 领域包路径进入 scopePaths；sources 只列实际文件。无法解析的包别名保留为范围提示，不伪装成文件来源。路径检索可带入相关领域的有效、无代码来源的人工约定，但不把它当成实现证明。
9. **确认与反馈。** 未编辑的生成稿首次确认时仍要验证生成来源，不能把旧稿直接绑定到更新后的源码。已有人工知识可以在复核后重新确认。整体进度更名为“处理覆盖（含无需沉淀项）”，不是知识正确率。单条整理先显示忙碌状态，再在后台读文件与 Git；重复点击有入口防护。

## Why（为什么改）

文件缓存仍会在本地读取来源以核验摘要，“只重读变化文件”指只重新请求变化文件的模型理解，不是免除本地 I/O。历史提交与审查缓存补丁按输入文本摘要追踪，并标为历史观察；当前路径快照只约束关联范围，不证明历史补丁就是当前源码。逐行历史证据仍在后续范围。

原实现把“文件被读过”“模块说明已生成”“业务判断成立”混在了同一个完成口径中。审查探针复现了旧结果被当作新鲜缓存、追加漏来源、替换保留过期来源、局部输入覆盖完整模块、响应缺项被算成功、强制占位和错误的首次确认冲突。

本批先修确定性的输入、写入和状态合同，保留既有人工保护。代码片段和目录结构仍只是观察，不自动升级为业务意图或独立验收。

## Impact（影响范围）

- 影响整仓建档、单条 AI 整理、审查页“沉淀为知识”、领域模板、确认/更新建议、知识上下文检索及建档面板。
- 旧 Markdown、确认记录及 JSON 状态保持可读；新增字段为空时不改变旧内容摘要。旧缓存和无版本模块摘要不再作为可信命中，会触发重新分析，但不删除人工知识。
- 新生成条目增加可选 scope-paths 与 generation-provenance。后者是本地编码的版本元数据，不是签名、真实性认证或模型推断正确性证明。
- 继续支持人工重新核对后的确认；AI 仍不能确认业务知识。
- 输入范围或模型策略变化时拒绝旧候选；当前原文和已经可靠落盘的批次保留。
- 轮内文件数是完整模块调度目标，大模块可独占一轮；真实请求数和时长在每次请求前检查。截止时间后不发新请求，已经在飞的请求仍由 HTTP 超时或取消收尾。累计请求额度不会因重启自动清零，耗尽后必须显式扩大预算。
- 没有提交、推送、部署或真实模型联调。测试只改临时样例与本工作区产物；不修改用户业务仓库或同级源码包。
- 不关闭、不替换 `/Applications/QiyideDev.app`；dev 包单独交付。

## 尚未实施（不把方案写成已完成）

- 原子知识的符号/行段级 evidence spans 与逐命题证据验证。
- 以 PRD/TRD、核心业务问题和独立测试为中心的完整建设工作台。
- GraphRAG / 向量召回、语义去重、自动矛盾合并与业务正确性评测。
- 供应商在相同模型别名背后切换真实模型的自动识别。
- 将被拒绝的每份旧模型响应单独持久化成可比较的过期候选。
- 删除整个模块或重新分组时自动清理旧条目：当前重排任务，但不擅自删除可能含人工内容的历史条目。

## 验证

- Red：4 个新合同测试在旧实现记录 6 个失败断言。
- 轻量 Wiki 模块：144 项测试通过，11 个套件。日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/knowledge-final-tests.log`。
- 完整 App 模块：147 项相关测试通过，12 个套件。日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-spm/test.log`。使用 `--build-only --test`，未启动或关闭 App。
- 知识组件预览：4 张真实组件截图；6 条样例中 2 条可引用、4 条排除。
- 架构/长任务组件预览：10 张截图；空知识库、共享任务、跨视图反馈、取消、静态生成和旧结果保护校验通过。
- 开发包：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev.app`。ZIP：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-knowledge-contracts.zip`。
- `codesign --verify --deep --strict` 通过。签名是本地 ad-hoc 签名，不是公证或正式发布认证。
- `/Applications/QiyideDev.app` 的 423 个文件内容摘要与操作前一致，原进程 PID 82247 保持运行。安装版整包摘要：`9d52129e0c6101948ece0353568b5d8c86e4eaa7e0e660f5dff2b2a40ca0986d`。
- 二进制、ZIP 与安装版哈希清单：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-knowledge-contracts.manifest.json`。
- 所有本轮模型生成回归都使用本地注入响应，真实模型调用为 0。
- 请求计数记录发送前的可靠预留，不是服务商账单；取消或崩溃的极短竞态下可能保守计数一次，以避免超发。
- 测试的完整 App 模块不等于全仓 XCTest 或真实业务系统回归。

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiGeneration.swift` — 输入凭据、策略键、范围与版本校验。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiEntry.swift` — 规范化正文与可选生成元数据。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiInsightStore.swift` — 内容版本缓存及显式保存错误。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModuleEvidence.swift` — 完整模块输入和处理版本。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift` — 调度、全量聚合、跳过、预算和检查点。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModelClient.swift` — 路径/部分响应验证、真实重试记账和本地模型注入。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurator.swift` — 单条生成、稳定目标、skip 与来源校验。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore.swift` — 来源合并、生成稿确认和持久化后的内存一致性。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore+KnowledgeReview.swift` — 更新建议、原文归档和接受前版本校验。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiKnowledgeContext.swift` — 领域人工约定与同一消费快照。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Wiki/WikiPipelineContractTests.swift` — 42 个新回归测试与本地假模型。
