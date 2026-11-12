# 来源校验反馈与领域简称来源修复

- 日期：2026-11-12（Asia/Shanghai）
- 类型：fix / feat
- 里程碑：M2
- 用户现象：点击“校验来源”没有明显反馈，0 可作参考 / 0 待确认 / 9 需核对。

## What（改了什么）

1. **校验成为可观察任务。** 保存本次状态、条目进度、当前来源路径、开始与完成时间、完成摘要。手动重复点击复用正在执行的任务；内容变化会取消旧输入重新校验。取消/失败不会把部分报告标成已完成，迟到的进度和结果不能覆盖新任务。
2. **保留完成结果而非只更新一个时间。** 按钮显示“校验中”，有进度与取消；完成后持续显示可作参考、待确认、需处理数量及来源/范围检查项数。报告列出具体问题和下一步，未改变状态也解释为什么。
3. **具体问题分型。** 区分正文或来源版本变化、缺少人工确认、范围无完整基线、实际文件未绑定、来源无法读取/超过预算。范围无法读取不再被错误当成“范围一定变化”。
4. **业务简称还原到真实路径。** 领域扫描已经提供 Java 源码根、公共包前缀；用它唯一还原 `agent/suggest` 等简称，不再直接拼仓库根。实际完整路径优先。多源码模块同名或不存在时拒绝猜测，保留需核对信息。新领域模板绑定真实文件，重复子范围合并，未解决项仍明确警告。
5. **旧内容受保护。** 对未绑定实际文件的旧条目，用户可点击“解析真实来源并生成更新建议”。只生成来源/范围建议，原文及原确认不被自动改写。用户对照并接受后才记录新的确认；接受前再次检查来源、范围及原版本。正文来源/范围可手动编辑，避免多义路径无法处理。
6. **校验不是重新确认。** 不把“按钮点击成功”当作依据已成立。没有实际来源或确认基线时仍不可引用；不事后给旧模型结果补盖当前摘要，也不自动使 9 条全部变绿。

## Why（为什么改）

只读检查确认，9 条都是已确认的领域模板，但 **sources 都为空**，136 份 scopeSnapshots 都没有 digest，只记录“范围无法核验”。其中 `agent/suggest` 等 scopePaths 是领域扫描去掉 Maven/Java 公共前缀后的业务简称，不是仓库根的物理路径。

原生成流程没有把简称还原，导致保存的文件来源为 0；原确认流程允许记录人工核对，但不会把无法核验的范围变成有效证据。因此重复校验仍应为 unverifiable。之前的按钮反馈只禁用、更新时间和数量，没展示完成结果、阻塞路径或处理动作，让正确的“仍不可引用”看起来像按钮没有执行。

## Impact（影响范围）

- 影响知识概览、单条依据详情、条目编辑、来源校验、领域模板生成与来源更新建议。
- 现有 Markdown、确认记录与正文摘要格式保留。增加的任务/报告字段属于运行时，不写用户知识文件。
- 新领域模板使用唯一还原的真实路径；旧条目不会在本次检查中自动迁移。
- 解析来源不是推断业务规则，不使用模型。来源存在/未变和业务正确性依然是两个维度。
- 未绑定来源的旧内容只产生独立建议；修改来源/范围会触发重新核对，人工原文和 revisions 保护不变。
- 读取仍有单文件与总量预算，未读完的来源不能被虚标 current；校验取消或失败不会引用旧状态。
- 没有自动替换安装 App、没有确认或改写实际用户知识，没有提交/推送，没有模型调用。
- 开发包包含本工作区既有的建档续跑与主题崩溃修复，不回退前面的改动。

## 只读实际状态核对

- 原 9 条仍为来源无法核验，136 份范围基线缺失，0 条可引用。
- 当前源码范围中，5 条的声明范围可以唯一还原；4 条存在同名模块或缺失目录，不适合自动选择。仅生成内存映射候选，**未在实际任务中生成或接受建议**。
- 原知识、缓存和任务状态的 14 个文件内容摘要在本次前后一致。
- 安装版可执行文件摘要保持不变；源校验修复版需要新的明确安装动作。

## 验证

- Red：3 个新回归在前一版复现 5 个失败断言，覆盖缺少具体路径、Java 业务简称读空和重复校验创建新 worker。
- 新增 15 项回归，包含任务开始/完成、取消后迟到结果、错误、部分报告、内容更新、具体来源问题、唯一/多义范围、来源绑定建议保留原文与接受前冲突。
- 轻量 Wiki：173 项相关测试通过，13 个套件。完整 App 模块：186 项相关测试通过，15 个套件。
- 来源校验真实组件隔离预览 4 张：运行中、完成但有阻塞、具体路径报告、显式人工接受绑定后的可核验状态。
- 既有知识预览 4 张与交互预览 10 张也回归通过；知识消费仍为 2 条可引用、4 条排除。
- 实际开发包 18 个内置主题与源文件逐项一致；签名 `codesign --verify --deep --strict` 通过（本地 ad-hoc，非公证）。
- 开发包：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev.app`；ZIP：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-source-check-fix.zip`。
- ZIP SHA-256：`976f77c6a0a08b26634f9dcf142c76cdb5ad3e879bca5773c143788e814b6825`。
- 安装版可执行文件摘要仍为 `49c98449e7b7a12c9cbaebd687d73ca42b448a2e0c4c9bfa7b21fa410079bc0f`，本次未替换。
- 验证清单：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-source-check-fix.manifest.json`。
- 修改/新增 Wiki 源文件与已测试 App 模块中的源码副本逐项一致。
- 测试不是全仓 XCTest、真实模型调用或独立业务验收。

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiKnowledgeCheck.swift` — 校验任务、进度、原因与结果统计。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiKnowledgeReview.swift` — 来源与范围的具体问题、取消和分项进度。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore+KnowledgeReview.swift` — 可取消、去重、拒绝迟到结果的任务入口。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiSourceScopeResolver.swift` — 真实 Java 源码范围还原、人工来源绑定建议。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiDomainSeeding.swift` — 新模板真实来源绑定。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiSourceCheckViews.swift` — 任务反馈与具体路径报告。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiKnowledgeOverview.swift` — 来源按钮和持续结果反馈。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiEntryEditor.swift` — 完整文件来源与范围编辑。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Wiki/WikiSourceCheckTests.swift` — 源校验与来源绑定合同回归。

## 本地证据

- 实际只读报告：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-source-check-feedback-2026-11-12/actual-check-report.json`。
- 原知识文件不变：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-source-check-feedback-2026-11-12/user-state-after.json`。
- 组件预览：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/source-check-2026-11-12`。
- 完整 App 测试日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-spm/test.log`。
