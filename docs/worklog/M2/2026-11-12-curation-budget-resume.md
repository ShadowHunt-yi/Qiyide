# 修复建档预算锁死续跑与旧记录显示为零

- 日期：2026-11-12（Asia/Shanghai）
- 类型：fix
- 里程碑：M2
- 用户现象：截图里“已处理 0、50 轮、2362 次请求”，提示达到 800 上限后“下次继续”，实际不能再次启动。

## What（改了什么）

1. **800 只限制本次明确启动。** 新增 `lastRun`，独立保存本次请求使用数、上限、时间窗与暂停原因。`callsUsed` 仍长期累计，但不再参与本次额度门槛。点击继续会开新 run / 新额度，不自动循环补额度，也不清空历史成本。每次真实尝试（含重试）仍先持久化预留，并发共用同一闸门。
2. **正常额度暂停有明确原因。** 区分请求额度、时长、主动暂停/取消、无进展。额度耗尽后按钮为“继续建档（新额度）”；预算中断不再算作模型失败。没有新的用户启动动作就不会继续发请求。
3. **文件理解与模块输出拆开。** 分别显示当前版本的文件观察、完整模块草稿/更新建议/无需沉淀，以及已有知识条目、旧观察待升级、历史轮次与历史请求。每批缓存可靠落盘后马上更新理解进度，不等下一轮；完整输出也在落盘后更新。
4. **旧数据不被假装清零或反向背书。** 预览不改旧检查点的 `filesDone/filesTotal`。升级前保存 `legacyProgress`；旧模块摘要保存到 `legacyModuleNotes`，不因重新分组直接丢掉。没有读取时摘要的旧观察不参与当前缓存命中；替换前保存在 `legacyRecords`，被删除路径的旧观察也先归档。
5. **界面与控件信息一致。** 本次/上次/下次额度明确区分，历史累计旁有口径提示。额度与时长可以编辑，当前/下一次额度直接可见；阶段日志收纳，文件与模块两条进度优先展示。扫描中显示核验状态，不以临时零数冒充实际统计。
6. **隔离复现工具。** 新增只读实际状态核对与本地响应的真实组件预览。不运行真实模型，不重置用户任务，不在用户业务仓库写修复脚本。

## Why（为什么改）

前一版把历史累计成本当成整个任务永久上限，且界面没有修改这个上限的有效入口，所以“下次继续”的承诺不成立。单轮 1/2 次的预算测试不能覆盖“已有 2362 次历史请求后再次启动”。

只读检查还确认，旧任务确实保存了 2627 / 2654 个文件的历史完成数、2629 份文件观察，但没有新版模块版本检查点。旧观察也没有读取时内容摘要。新版将这些历史指标隐藏，只展示新的完整模块数，于是看起来像全部工作归零。

正确做法不是把历史成本删成 0，也不是给旧结论补盖当前文件摘要，而是保留历史、展示迁移边界，并让新的一次运行拥有可执行的有限预算。

## Impact（影响范围）

- 影响知识库建档的开始/继续/暂停/取消、请求预算、检查点、阶段统计与控制面板。
- `Options.maxCallsTotal` 改名为 `maxCallsPerRun`；它是内部、未持久化的参数，所有调用方和回归测试已同步。
- JSON 新增 optional 字段，旧任务与旧缓存可读。旧版观测不能伪装成新鲜缓存；历史归档不是新的 AI 权威来源。
- 首次升级仍可能需要重新理解未能绑定旧来源版本的文件，这不是“恢复了全部当前完成度”；不会虚标 2627 个当前文件已处理。
- 已有人工知识、确认记录、来源核验和更新建议保护不变。
- 请求计数是发送前的持久化预留，不是供应商账单；历史部分沿用旧版口径，取消/崩溃的极短竞态可能保守计数。
- 本次仅改本工作区源码与开发产物，不提交/推送，不向真实模型发送项目代码，不在实际用户任务中自动运行建档。
- 修复后的开发包单独交付，安装 App 不自动关闭或替换；需要新的明确安装动作才能生效。

## 验证

- Red：3 个新场景在前一版复现 10 个失败断言，包含 2362 次历史后无法启动、额度暂停后无法续跑，以及预览抹掉旧计数。
- 新增回归覆盖独立 run 预算、并发额度、时长续跑、跨进程恢复、缓存复用、分阶段进度、旧指标/观察/摘要归档、不自动补额度，以及正常预算暂停不污染模型失败队列。
- 轻量 Wiki：158 项相关测试通过，12 个套件；完整 App 模块：161 项相关测试通过，13 个套件。并非全仓 XCTest 或真实模型/业务系统回归。
- 真实组件隔离预览：4 张截图，包含旧记录保留、额度暂停、深色模式和成功续跑。两条进度及可见预算控件已检查。
- `codesign --verify --deep --strict` 通过，本地 ad-hoc 开发签名；不是正式公证。
- 修复 ZIP：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-curation-resume.zip`。
- 压缩包 SHA-256：`87932fea32cc0f40b3ac09bd628550274ebc16640b099a7ec443db1ee19f8720`。
- 安装版可执行文件摘要保持 `49c98449e7b7a12c9cbaebd687d73ca42b448a2e0c4c9bfa7b21fa410079bc0f`，本次没有关闭或替换安装 App。
- 任务知识/状态 14 个文件内容摘要与检查前一致，没有迁移或重置实际任务。
- 完整验证清单：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-curation-resume.manifest.json`。
- 实际任务只读核对：历史请求 2362、旧完成 2627 / 2654、旧观察 2629、当前已有知识 9。当前扫描为 2885 个源码文件，截图曾为 2887；以每次扫描的当前范围为准，不硬编码旧分母。
- 只读核对前后任务和缓存字节一致，真实模型请求 0。实际任务尚未发请求验证真实模型产出。

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiCurationProgress.swift` — 独立 run、暂停原因与分阶段覆盖。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift` — 本次额度闸门、复用续跑、可靠落盘后刷新进度。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationJob.swift` — optional run、旧计数及旧模块摘要保留。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiInsightStore.swift` — 旧观察替换/裁剪前归档，不允许归档命中新缓存。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModelClient.swift` — 预算/取消的类型化停止原因。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiIngestSheet.swift` — 两条进度、历史兼容说明与可操作的新额度。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationResumeVerification.swift` — 只读状态核对、隔离真实组件预览。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Wiki/WikiCurationResumeTests.swift` — 历史大额请求后的续跑合同回归。
