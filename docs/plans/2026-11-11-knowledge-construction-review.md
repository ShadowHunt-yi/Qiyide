# 知识生成与整仓建档：正确性审查与改进方案

- 日期：2026-11-11（Asia/Shanghai）。
- 范围：当前工作区的知识生成、领域草稿、整仓建档、来源核验与 AI 消费逻辑。
- 状态：审查与方案，**本轮未修改 App 源码、开发包或安装版**。
- 这里的“生产”按知识生成理解，不涉及生产环境部署或业务数据库。

> **2026-11-12 实施更新**：用户已批准调整。本文件下文保留的是 **2026-11-11 的审查快照**，包括当时的缺陷、探针和行号，不代表当前实现仍存在全部缺陷。确定性的版本缓存、来源合并、完整模块聚合、skip、预算及确认合同已调整。业务工作台和逐命题证据体系未声称完成。详情见 [2026-11-12 开发记录](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/worklog/M2/2026-11-12-knowledge-generation-contracts.md)。

## 1. 直接结论

**整体方向对，但还不能说逻辑完整正确。**

现有实现适合建立“代码理解索引＋待审模块说明”。作为可长期使用、可供 AI 依赖的业务知识库，还有来源版本、增量更新、生成结果校验和正常无产出的缺口。

不能把三件事混成同一个“建档完成”：

1. 代码文件被扫描或模型读过。
2. 根据这些代码写出了一份说明。
3. 一条业务判断有可靠来源，经过核对，仍适用于当前版本。

上一轮改造主要解决交互、任务生命周期、架构保存和进度。编译与相关回归通过，**不等于知识生成的全部语义边界也正确**。这轮新增的隔离探针确实复现了此前未覆盖的情况。

建议保留已有人工知识保护，先修来源与增量更新，再改成：

> **轻量事实索引 → 面向业务问题的原子知识候选 → 人工核对 → 版本化增量维护。**

不是先花大量模型调用给所有文件都写一遍说明，之后再把这些说明统称为业务知识。

## 2. 当前实际上有三种“生成”

| 入口 | 实际行为 | 判断 | 建议定位 |
|---|---|---|---|
| 领域模型 → 生成缺失知识 | 根据域名称、规模、包、负责人和判定依据拼模板，设计意图留空 | 作为骨架合理；不是完整业务知识生成 | 生成领域档案草稿 |
| 整个仓库建档 | 扫描 → 分批理解文件 → 用文件摘要推断模块职责/取舍/规则 → 落成模块草稿 | 作为代码理解有用；增量语义与证据契约仍有缺陷 | 构建代码事实索引与模块说明 |
| 从改动沉淀知识 | 读取 diff 与有效知识上下文 → 生成一条候选或更新建议 | 最接近业务知识维护；仍缺正常 skip 与完整来源绑定 | 从任务/变更提炼可复用判断 |

关键入口：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiDomainSeeding.swift:35–85`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:350–633`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurator.swift:98–131`

## 3. 值得保留的逻辑

### 3.1 AI 不直接覆盖人工知识

当前 `applyDraft` 会检查原条目。人工修改或确认过的内容，不再被模型直接重建替换，而是生成对应原版本的更新建议。接受建议前再次检查原版本，且保留原文归档。

这是正确方向，不应因为其他缺陷而关闭这层保护。

证据：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore.swift:643–651`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore+KnowledgeReview.swift:102–133`
- 本轮隔离探针 `protectsManualAndConfirmedKnowledgeIsStillCorrect`。

### 3.2 草稿、过期来源不会自动成为业务依据

确认记录包含内容摘要与来源摘要。使用知识前重新核验；草稿、未核对或来源变化的条目不能作为当前业务约定进入 AI 上下文。

“人工约定”与“代码已实现/测试通过”也已明确区分。这层安全边界是合理的。

证据：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiKnowledgeReview.swift:108–148`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiKnowledgeContext.swift:74–89`
- 本轮隔离探针 `draftsAndChangedSourcesAreExcludedFromAIReference`。

### 3.3 静态证据、有限并发、缓存和可续跑有价值

把依赖分析与模型说明分开，限制在飞请求，缓存文件理解，保留检查点，都是应该保留的工程基础。

但静态分析是启发式代码证据，不是业务要求的证明；缓存存在与文件被引用，也不是知识正确的证明。

## 4. 已发现的问题：哪些是确定缺陷，哪些仍需验证

### K01 · P1：旧结论可能被标成“当前代码的新鲜缓存”

`WikiInsightStore.record` 在模型返回后读取文件**此时**的 mtime/size，而不是记录发出请求时读到的版本。

可复现路径：

1. 读取版本 A，开始推断。
2. 用户把代码改为版本 B。
3. A 的结果返回，按 B 的元数据保存。
4. 后续缓存命中，认为 A 的判断适用于 B。

本轮隔离探针已复现：旧结果被命中，同时文件覆盖统计为“新鲜”。还复现了同大小、恢复 mtime 的内容修改会漏检。

此外，缓存只看模型名称，没有内容摘要、提示词版本、提取器版本、范围或脱敏策略版本。相同模型名背后路由变化，也不保证同一判断策略。

**更好的做法**：以读取时的内容摘要绑定请求；缓存键包含输入内容与处理版本；写回前检查输入是否仍一致，变化则保留过期候选而不发布当前结果。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiInsightStore.swift:74–104`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:647–655`

### K02 · P1：来源列表的增量语义不正确

当前存在两个相反问题：

- `append`：已有 sources 非空时，新增正文对应的新文件没有被合入来源。
- `replace`：始终并集旧来源，已删除或不再有关的来源无法退出当前版本。

**已复现的实质影响**：一条 AI 草稿追加了 B 文件的规则，但 sources 仍只有 A；确认后再修改 B，系统仍可判为 `current`。重建只保留 A 时，已删除 B 仍被留下，导致条目长期不可核验。

**更好的做法**：来源应属于每条判断及每个版本，而不是只是一份不断增长的路径集合。追加合并本次真实证据；替换按本版证据重建来源，旧证据保留在历史。

源码：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore.swift:654–686`。

### K03 · P1：输入是模块的局部变化，输出却替换整个模块

整仓扫描先把已完成文件从 `pendingModules` 中剔除。`resolved` 只为本轮选中待处理文件准备；模块推断也只收到这些文件的摘要。

与此同时，`knownModuleContext(excluding:)` 明确排除当前模块旧摘要，随后 `.replace` 整块替换当前模块说明。正文列出“模块全部文件”并不表示模型看到了全部文件；旧文件甚至会出现在关键文件列表里但职责为空。

例如，一个模块原本既处理创建，也处理取消。本轮只改取消相关文件，重建时就可能退化为只描述取消职责。

**这是源码确认的上下文缺口**，尚未通过真实模型测试量化丢失程度，不能说每次一定丢失。

**更好的做法**：只重新理解变化文件，但聚合时使用模块全部有效摘要、已有知识、当前规则及本次变更。对人工知识产生差异建议，对机器模块说明重建可追溯投影。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:395–474`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:541–554`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:583–590、769–803`

### K04 · P1：模型输出没有与输入范围严格对账

文件理解响应只检查非空 path/purpose，没有核对 path 是否属于请求、是否重复、是否覆盖全部请求文件。

本轮本地合成响应：输入只有 `Allowed.swift`，响应重复返回 `NeverRequested.swift`。当前实现接受两条结果且将批次判为成功。

这不证明真实模型已经发生过这种问题，但证明系统缺少防线。

**更好的做法**：严格校验路径成员、唯一性、缺失、字段长度与逐条证据引用。缺失为部分失败，未知路径拒绝接收。合法 JSON 不等于合法业务结果。

源码：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModelClient.swift:155–168`。

### K05 · P1：整仓发送路径没有复用既有脱敏层

单条改动提炼会对最终提示词调用脱敏；整仓 `prepareJobs` 把原代码片段直接拼入请求。

本轮使用**假的示例密钥**验证：代码中的示例值留在整仓请求中，调用已有 redactor 后可去除。这个探针未向网络发送该示例值，没有读取真实凭据。

**更好的做法**：所有发往模型的出口使用统一 scope/排除/脱敏策略；提示用户实际发送范围。不能因请求入口不同而改变隐私边界。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiRepoIngest.swift:370–390`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurator.swift:202–215`

### K06 · P2：没有“无可复用知识”的正常结果

提示词要求判断是否值得沉淀，但协议只有 `create/update`。空 body 被当错误并重试；未知 action 默认成为 `create`。

本轮复现：`{"action":"skip","reason":"只有格式调整"}` 解析失败；带占位 title/body 的 `skip` 会被默认解释为新建。

**更好的做法**：`skip/noop` 是正常终态，允许记录“已检查，无可复用判断”，不消耗额外重试，也不制造知识卡片。

源码：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurator.swift:114–131、157–161、227–234`。

### K07 · P2：调用预算不是严格的真实请求预算

`callJSON` 一次任务内部可能尝试多个请求，外层只按 `usedModel` 或模块 outcome 加一。上限又只在每轮开始时检查。

本轮仅在 loopback 合成服务里验证：**两个 HTTP 请求形成一个 `usedModel=true` 的 outcome**。没有执行真实全仓预算超限试验，超限数量仍取决于轮内规模和重试。

**更好的做法**：每个真实请求，包括重试，先预留预算再发送；区分逻辑任务数、HTTP 请求数、失败数与实际费用数据。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModelClient.swift:227–253`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift:235–242、572、642`

### K08 · P2：缓存/检查点保存失败不可见，摘要恢复缺版本

`.insights.json`、`.ingest-job.json` 保存忽略错误。隔离探针将 `.qiyide` 设置为普通文件后，保存调用无异常，但回读缓存和调用数归零。

跨轮 `moduleNotes` 只有模块名与一句职责，没有相应源码、模型和提示词版本。恢复任务时不能保证这些摘要仍有效。

**更好的做法**：显式持久化结果和失败日志；源版本绑定检查点；成功状态只有可靠提交后才成立。保留已经落盘内容，重跑有明确失败队列。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiInsightStore.swift:54–69`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationJob.swift:44–70、93–100`

### K09 · P2：领域档案的“范围”被误当成“证据”

领域草稿 sources 用包/目录路径；当前来源检查器只支持仓库内普通文件。这个接口契约不一致。

本轮复现：域范围为 `Sources/Order`，生成与确认后仍判为 `unverifiable`，不能成为当前代码依据。

**更好的做法**：`scopePaths` 存目录、域与符号范围，`evidenceSpans` 存具体代码或文档片段；目录范围使用清单摘要，不能直接冒充一个文件来源。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiDomainSeeding.swift:68–101`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiKnowledgeReview.swift:123–148、181–185`

### K10 · P2：域级人工约定不能被路径相关检索正确使用

无文件来源的人工约定可以是有效 agreement。但当前路径筛选只接收“无 sources 且无 domains”的全局 agreement；带域的规则不进入相关路径上下文。

探针确认此行为。它是有待设计补齐的作用域映射，不应简单改为“所有人工规则都塞给所有项目”。

**更好的做法**：路径/符号 → 域范围 → 有效约定的映射；对域级意图标明“未证明代码已经实现”。

源码：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiKnowledgeContext.swift:57–68`。

### K11 · P1：刚生成领域草稿就确认，可能假报外部修改

领域模板保留正文末尾换行；解析 Markdown 时会 trim；内容摘要对两种形式不一致。于是内存草稿与回读文件不同，即使没有外部修改也可触发 `changedOnDisk`。

本轮先观察到该异常，再验证：刷新后确认可继续，但目录来源问题仍独立存在。

**更好的做法**：写入、解析、摘要使用同一规范化形式；不通过跳过版本检查来绕过误报。

源码：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiDomainSeeding.swift:168–176`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiEntry.swift:223`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore+KnowledgeReview.swift:57–65`

### K12 · 设计风险：两层摘要没有足够证据来证明业务意图

大文件主要给模型头部和声明摘要。下一层主要收到文件职责/要点，然后推断“设计取舍”“必须遵守的约定”。这有用，但缺逐条代码/文档/测试依据。

代码可以说明“现在做了什么”，不独立证明“业务应该这样做”或“当初为什么这样设计”。“不要编造”提示词不能替代来源类型与证据约束。

这是设计层判断，**未通过真实业务语料测出幻觉率**，也不是说现有每条知识都错误。

## 5. 更好的建设模式

### 5.1 把事实索引、知识和视图分开

| 层 | 保存什么 | 谁负责确认 | 如何更新 |
|---|---|---|---|
| 事实索引 | 文件、符号、依赖、API、配置、测试位置、源版本 | 确定性提取＋可解释局限 | 文件变化即增量重建 |
| 知识条目 | 一条规则、设计决定、风险、边界或例外 | AI 提候选，人核对；独立证据说明验证范围 | 命题/证据变化生成新版本或更新建议 |
| 知识视图 | 模块档案、领域概览、系统架构、关系图 | 展示聚合，不冒充新的事实来源 | 从事实与有效知识重建投影 |

首建不必先让模型阅读整个仓库。先能定位文件、符号、关系，再按重要业务问题补知识。

### 5.2 用业务问题和工作流驱动，而不是一文件一条知识

优先问：

- 核心用户流程有哪些，输入、状态、失败和降级是什么？
- 哪些数据范围、幂等、权限或状态规则必须保持？
- 哪些边界是人确认的设计决定？代码是否已经实现？
- 改一个功能会影响哪些流程和规则？需要哪些独立验证？

输入按来源区分：

- PRD/用户确认：业务意图，未必已经实现。
- TRD/ADR/设计讨论：设计决定，未必与当前代码一致。
- 代码：当前实现观察，可能包含缺陷。
- 测试/执行报告：仅证明该版本、该输入、该范围下的行为。
- AI 摘要：辅助解释，不能因为反复生成就升级成依据。

### 5.3 一条知识只表达一个可核对判断

建议的结构草图（尚未实现）：

```text
KnowledgeItem
  id                 稳定 ID，不以标题充当唯一键
  kind               rule / decision / risk / boundary / behavior
  statement          一个可核对的判断
  scope              项目、领域、流程、符号
  basis              人工意图 / 实现观察 / 待验证推断 / 执行证据
  evidence[]         文件或文档片段、符号、内容摘要、来源版本
  generatedFrom      输入摘要、提取器版本、提示词版本、模型策略版本
  state              draft / accepted / stale / superseded
  validation[]       验证版本、用例、输入范围、结果，不是一个无解释的 true
  previousVersion    旧判断与旧证据
```

模块说明可以汇总这些条目，但不要把模块里的每句摘要都当成新的业务规则。

### 5.4 一个具体例子

下面仅是说明，不是当前业务项目的缺陷结论：

- 代码 `return []`：证明当前分支返回空列表。
- “画像缺失就应返回空列表”：这是业务要求，代码本身不能证明。
- PRD 规定“画像缺失仍返回基础建议”：这是已确认意图。
- 对应版本的测试实际覆盖该分支：是有范围的实现验证。

如果代码与要求不同，知识库应该展示差异和待核对项，而不是根据代码反向把缺陷写成规则。

### 5.5 增量维护流程

```text
任务意图 / 文件变更 / 文档变更
  → 固定输入范围与内容版本
  → 统一发送/脱敏策略
  → 更新受影响的事实索引
  → 检索相关规则、决定、旧版本与证据
  → 提炼原子候选，允许 skip
  → 严格校验引用、作用域、重复与矛盾
  → 人工对照确认；需要时绑定执行验证
  → 原子提交并保存历史
  → 相关视图刷新，受影响旧知识标记 stale
```

只有变化的文件重新理解，但模块/流程级推断仍须看到完整相关上下文。不能把“省输入”实现成“遗忘原模块语义”。

### 5.6 检索和 GraphRAG 怎么选

建议先使用项目路径、符号、域映射和关键词检索，分开召回“事实证据”和“已确认知识”。这能直接解决当前问题，不需要先引入新的向量数据库或全量模型知识图谱。

当确有跨模块全局问题、人工知识和证据已稳定时，再评估语义检索、分层汇总或 GraphRAG。图谱和向量是检索/聚合手段，不是正确性保障。

该选择是对当前代码库的建议，未作新框架性能/费用对比，不能把它描述为所有项目通用最优解。

## 6. 改造顺序：先改合同，不先重写所有功能

### 第一步：修确定问题

1. 统一正文规范化，修刚生成就确认的假冲突。
2. 修 append 新来源和 replace 旧来源的当前版本语义。
3. 模型请求绑定读取时内容摘要；写回前核对，不用当前 mtime 给旧结果“盖章”。
4. 所有出口脱敏，模型响应路径/唯一性/缺失严格验证。
5. 模块重建使用完整有效上下文，人工知识仍走更新建议。

### 第二步：可信增量与成本控制

1. 每次真实请求与重试预留预算并计数。
2. 增加 skip、部分失败与版本化失败队列。
3. 缓存、检查点和摘要恢复都有可靠保存和输入版本。
4. 范围与证据分开，域级规则进入正确业务上下文。

### 第三步：把“知识建设”升级成业务工作台

1. 从核心工作流和已确认需求出发，逐步补规则、边界、例外与验证。
2. 用原子条目减少重复和矛盾，保留模型、人工和历史的边界。
3. 让代码结构与架构图成为事实/知识的投影。
4. 建立可重放的质量用例，而不是用条目数或完成百分比衡量建设结果。

## 7. 怎样判断改进是真的有效

| 维度 | 要检查什么 |
|---|---|
| 来源真实性 | 每个判断的引用来自本次输入，能定位到具体文件/文档片段 |
| 来源完整性 | 新增依据不漏；删除依据不继续冒充当前来源 |
| 版本安全 | 生成期间改文件、换模型、改规则会使旧结果失效 |
| 增量完整性 | 只改模块一个文件，未变职责/边界不凭空丢失 |
| 人工保护 | 旧人工正文保留；更新建议基于正确旧版本 |
| 无用产出 | 纯格式/重命名等变化可以正常 skip，不硬凑规则 |
| 不确定性 | 推断、未覆盖、冲突和无法验证都明确展示 |
| 成本 | 真实请求数、重试、失败、预算预留可对账 |
| 使用效果 | 回答业务问题时引用正确；核对/纠错成本降低 |

本轮没有真实业务语料评估，不给虚构的准确率或节省比例。

## 8. 复现与验证边界

### 已执行

12 个隔离探针完成，包括当前风险现象和两个正确保护。**这些测试通过表示现象得到验证，不表示缺陷已经修复。**

- 旧输入结论被记录成当前缓存。
- 同大小、恢复 mtime 后缓存漏判。
- append 新来源遗漏，相关文件变更仍判 current。
- replace 保留已删除来源。
- skip 不被协议支持，未知 action 默认为 create。
- 整仓请求未走脱敏层（未发送合成示例密钥）。
- 缓存/检查点写失败无显式信号。
- 人工知识不被直接覆盖。
- 草稿和来源变化排除于当前 AI 依据。
- 领域草稿正文规范化假冲突，以及目录来源不能核验。
- 域级 agreement 被路径上下文排除。
- 两次本地合成 HTTP 请求只有一个逻辑 outcome，未请求/重复路径被接受。

### 未执行

- 没有让真实模型读取代码或业务知识。
- 没有检查用户业务项目中每条知识的正确性。
- 没有实测整个仓库的幻觉率、预算超限或新方案效率。
- 没有改 App 逻辑、重新打包或替换安装版。

### 证据文件

- [隔离测试源码](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/KnowledgePipelineAuditTests.swift)
- [最终测试日志](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/audit-tests-final.log)
- [问题、优先级与行号](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/explorations.json)
- [推荐与步骤](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/recommendations.json)
- [结论与验证范围](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/conclusions.json)

## 9. 外部资料与推断边界

已直接核验两个公开的一手资料，作为来源建模与索引/知识分离的设计参考：

- W3C PROV-DM：描述生成活动、来源实体、派生关系与责任主体，支持追踪数据来源。
- Microsoft GraphRAG 官方索引概览：描述从原文提取、关系、聚合和嵌入的索引流水线。

本方案不是要求采用这两个完整实现，也不声称它们能自动保证业务正确。

```text
https://www.w3.org/TR/prov-dm/
https://microsoft.github.io/graphrag/index/overview/
```

公开网页检索工具未返回可引用条目；一手网页已直接获取并保存在审查目录。不使用虚构的网络引文。

- [一手资料记录](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.analysis/ANL-knowledge-construction-2026-11-11/research.json)

**建议下一步**：先实施第一步的来源、版本和增量合同修复，再做业务问题驱动的原子知识建设。不要把“换更强模型”或“增加图谱/条目数量”当成这些问题的根本解决方案。
