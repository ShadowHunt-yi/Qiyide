# 知识版本、更新建议与业务审查联动

- 日期：2026-11-11
- 类型：feat / fix
- 里程碑：M0（知识可信度基础及审查联动）
- 状态：源码与测试完成；不是完整的业务验收系统。

## What（改了什么）

### 默认先看能否作为依据，而不是图谱规模

知识库默认打开「知识」视图。按待我核对、规则与术语、决策与边界、实现参考查看。保留导图、结构、图谱和架构入口。

列表、详情和审查引用展示同一套核验状态。窄窗口使用受容器宽度约束的内容与菜单筛选，避免横向裁切。

### 确认和来源版本分开管理

- 新条目、缺失或非法 status 默认草稿。
- 旧 confirmed 条目没有确认记录时，保持可读但标为历史待核验。
- 确认记录绑定正文、标题、类型、业务范围、来源及关系等内容摘要，并记录来源文件摘要与时间。
- 正文或范围变化后撤销有效确认；来源内容变化后提示重新核对。
- 无代码来源的规则、决策与术语可作为人工约定，但不能表示代码已实现。
- 空正文不能确认或进入上下文。
- 来源目录、业务包别名、越界路径、缺失文件和超预算内容不自动核验通过。

### AI 更新不直接覆盖人工内容

已确认、人工修改或无法核验生成版本的条目，收到 AI 更新时保存为独立候选。

候选保存原文版本指纹。界面展示原文摘要和拟更新内容。接受时检查原文与候选是否被外部修改；冲突时停止，不覆盖。接受后将旧版及候选归档到知识目录的 revisions 子目录。

未被人修改的 AI 草稿仍可以原位刷新，避免每轮建档制造一套重复条目。生成内容摘要和人工保护标记用于区分这两种路径。

人工编辑或确认过的内容不能使用「丢弃未编辑草稿」删除，必须走明确的删除确认入口。

### 人看到、导出与 AI 使用同一个知识筛选逻辑

新增知识快照：预览、复制、提交说明和知识维护共用内容与来源校验。使用前重读磁盘，模型生成完成后再次核对知识指纹，防止迟到结果被标成当前解释。

快照与缓存纳入仓库身份、知识内容、确认与来源版本；审查界面可以展开本轮依据。草稿摘要不再作为已确认内容交给知识维护模型，原条目标题仅用于去重和更新定位。

审查服务及相关知识统一到传入的仓库管理器根目录；查看相关条目时定位到同一仓库的对应知识。

### 结构项不再代表业务验收

结构结论区分未决定、待修改和已接受。违规项保留在展开列表和地图标记中，不再收成看似完成的状态。

结构提示可关联已通过知识筛选的业务参考，但明确表示“不是本次实现已符合的证明”。测试文件数量仍只是数量，不会转换为执行结果。

## Why（为什么改）

原实现主要围绕代码归档、领域建模和结构变化。它能回答“代码放在哪里、依赖如何变化”，但难以回答“这是业务约定还是 AI 猜测、原来确认的知识现在还适用吗”。

缺失状态默认 confirmed、AI 原位覆盖已确认条目、只检查来源是否存在，以及把结构决定当作分支审完，会放大用户对结果的确信。

此次先建立可追溯的知识基础，让用户与 AI 使用一致、有限度的依据；完整任务与业务验收随后接入，而不是先写更肯定的描述。

## Impact（影响范围）

### 数据兼容

仍读取原有 Markdown。新增确认记录、候选基线、生成摘要和人工保护元数据。

不批量迁移旧库。仅在用户编辑、确认或生成/接受候选时写入对应文件。旧库可信度语义收紧是有意变化：没有记录不等于已经确认。

关联文件匹配改为完整相对路径或目录边界，不再通过任意字符串后缀匹配同名文件。

### 运行边界

- 来源普通文件：每文件最多 2 MiB，一轮来源读取预算 32 MiB。
- 上下文知识加载：最多 2000 个顶层 Markdown 文件，单文件最多 1 MiB，总内容读取预算 16 MiB。
- 正文上下文按字符预算摘取，显示截断、未纳入与读取缺口。
- 这些是读取时快照，不是冻结整个工作区的原子事务；持续变化后应重新校验。
- 确认记录存在可编辑文件中，不是防篡改签名或权限系统。
- 未接入真实模型、执行器或测试平台验证业务效果。当前知识不得视为历史提交当时已满足需求的证明。

### 构建脚本的副作用与修复

执行旧脚本时触发了它原有的按名 pkill，关闭了正在运行的安装版 QiyideDev。已及时向用户说明；安装目录未替换，未保存文档状态未经核验。

现已移除自动关应用逻辑。只在精确匹配本次输出包正在运行时拒绝替换；新增 `--build-only`，不组装、不关闭、不启动应用。还修复了 macOS Bash 空数组与 Xcode/CommandLineTools 测试路径兼容问题，并让测试命令返回真实退出状态。

### 保留的用户改动

未修改原有的编辑器折叠验证改动和三个 memory 文件。未创建提交、推送或安装替换。

## 验证

| 项目 | 结果 |
| --- | --- |
| 改造前独立测试 | 43 项通过 |
| 改造后独立知识库测试 | 81 项、8 个测试集通过 |
| 完整 App SwiftPM 编译 | 通过 |
| 完整 App 模块下的同组测试 | 81 项通过 |
| 开发包组装与签名检查 | 通过；未安装、未自动启动 |
| 静态差异空白检查 | git diff --check 通过 |
| 打包保护 | 3 个隔离的进程匹配场景、2 个不兼容参数场景通过 |
| 离屏界面 | 知识概览宽/窄窗口、候选对照、结构引用四张截图 |
| 上下文样例 | 6 条知识，2 条可引用，4 条被排除 |
| 新警告 | 知识库独立构建仅有原有 ViewProjector 的未变 var 警告 |

主要回归场景：非法状态、旧确认记录、正文与范围变化、来源修改/缺失、越界符号链接、空内容、候选基线冲突、已编辑草稿保护、共享上下文与截断、仓库隔离、违规不能变成完成。

本轮执行：

```sh
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/run.sh test
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/package-dev-spm.sh --test
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/run.sh knowledge-preview
```

测试日志：
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/knowledge-upgrade-test-final.log`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/full-app-knowledge-tests-final.log`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/knowledge-preview-final.log`

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiEntry.swift` — 兼容元数据、草稿默认值及人工内容保护。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiKnowledgeReview.swift` — 内容/来源摘要与状态判定。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiKnowledgeContext.swift` — 有界、可追溯的共享知识输入。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore.swift` — 保存、确认、草稿刷新和批量操作。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore+KnowledgeReview.swift` — 候选更新、冲突检测、归档与核验调度。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiKnowledgeOverview.swift` — 面向业务依据的默认概览。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiKnowledgeContextSheet.swift` — 人可查看和复制的知识快照。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/Structure/StructureKnowledgeReferences.swift` — 结构变化关联业务知识。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/AIReview/Service/AIReviewService.swift` — 同仓库上下文、缓存与生成期间的版本检查。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/AIReview/Service/AINarrativePrompt.swift` — 区分当前知识参考与历史实现事实。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Wiki/WikiKnowledgeReviewTests.swift` — 38 项新增回归测试。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/KnowledgePreview.swift` — 隔离样例的实际 SwiftUI 截图。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/package-dev-spm.sh` — 安全构建与真实测试退出结果。

## 后续

任务契约、行为级变更解释、执行证据、结构决定的版本失效、多项目注意事项仍未完成。不要把本轮的知识可信度层称为完整业务验收。

## 界面预览（隔离测试数据）

这些截图来自真实 SwiftUI 组件，但内容是隔离样例，不是业务项目当前状态。

![知识概览](/Users/ext.liangzhenqi1/.codex/visualizations/2026/11/11/01a1c92d-37a8-7233-9188-520e443f2252/knowledge-review/overview-wide.png)

![原文与更新建议](/Users/ext.liangzhenqi1/.codex/visualizations/2026/11/11/01a1c92d-37a8-7233-9188-520e443f2252/knowledge-review/update-proposal.png)

开发包：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev.app`。签名检查日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/package-signature-check.log`。
