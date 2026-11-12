# 架构生成与长任务的常驻反馈

- 日期：2026-11-11
- 类型：feat / fix
- 里程碑：M1（并实施部分 M2 的任务与建档修复）
- 对应设计：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/plans/2026-11-11-interaction-design.md`

## What（改了什么）

### 架构首建与任务反馈

- 识别、锚定、生成知识和审核入口按当前数据与任务状态启用；不会让缺少前提的操作静默无效。
- 删除“有架构就自动离开空领域模型”的旧跳转，用户选择的视角不会被抢走。
- 把五个视角的导航移到内容区外。读取中、空知识库或某类数据失败都不会再让导航消失。
- 系统架构、代码结构不依赖先创建知识条目。架构视角使用独立空态，不保留两边空知识栏。
- 新增项目级架构执行器与任务快照。相同项目的多个窗口共享一份任务；重复启动会显示已有任务详情。
- 常驻任务条显示阶段、真实计数、模型尝试、耗时、取消、详情和终态。切到其他视角仍能找到任务。
- 生成完成不强行跳走。用户在其他视角时可以点击“查看结果”。
- 模型未配置先解释原因，提供 AI 设置路由与“仅静态分析”；不先做耗时扫描再发现配置问题。
- 静态分析标明实际来源。无效模型结构不能被静默包装成成功；遗漏分组作为警告与待核对域展示。
- 重建不清空旧图。架构域选择与详情用同一份 Binding；关闭详情不会留下错误的选中状态。

### 可取消计算与可靠保存

- 扫描代码、依赖分析与来源核对移到明确传播取消的后台任务。
- 按文件内容计算完整输入摘要，提交前重新核对；新增、删除或修改代码都能使旧候选失效。
- 核对生成期间 AI 配置是否变化；版本签名只在内存中使用，不写入产物或日志。
- 把“准备候选”和“提交结果”分开。写入失败保留候选，可重试保存而不再次请求模型。
- 架构写盘改为抛错。先写暂存文件、读回验证，再同目录原子替换；不先删除旧文件。
- `cancelling` 持续到工作真正退出。短暂的原子保存阶段明确禁用取消，不把已经提交的结果冒充已取消。
- 扫描/依赖计数节流更新，避免大仓库产生大量主线程刷新；耗时每秒更新。
- `generation` 是可选 JSON 字段，旧架构文件仍可读。损坏架构文件给独立读取错误，并保留最后可读的架构。

### 其他已确认问题

- 错误/成功提示的关闭动作各自独立，不再清除其他消息或留下无法关闭的架构任务错误。
- 大纲和模型导出不再忽略编码/写盘错误；成功提示给出文件位置，保存面板取消仍是正常退出。
- 暂停/恢复使用明确的状态能力：只有 stopped 才能恢复；信号成功后才改变状态，信号失败写到任务输出。
- 对接现有 ActivityViewer，按规范化项目路径隔离；从已知进度切到等待模型时能清除旧百分比。
- 整仓建档分开显示实际知识覆盖与阶段进度。已理解缓存不等于已生成知识，部分完成不报全部成功。
- 建档范围预览异步执行；取消预览不会把另一个项目的统计写回。
- 建档停止不再提前释放任务。跨运行、跨轮次的迟到回调被隔离，取消后不提交新草稿。
- 建档面板允许收起后继续运行。另一个项目正忙时不展示错误作用域的取消按钮。
- 建档面板内容可滚动，底部操作保持可见；加入隔离的真实 SwiftUI 渲染入口。

## Why（为什么改）

“生成架构视图”无可感知反应首先来自状态边界错误，而不是模型一定没运行：空知识/领域数据会隐藏架构的内容和唯一加载指示。

只补小转圈不能解决重复启动、关闭重开、失败、取消与旧图保护。因此选择用户确认的“常驻任务条”，让视图只订阅项目级任务，保留现有 AI、领域分析与活动通知执行器。

进度只来源于实际阶段、计数与尝试。模型等待没有可信分母，不显示假百分比或未经统计的完成时间。

## Impact（影响范围）

- 主要影响知识与架构窗口、架构生成、整仓建档、活动显示和任务暂停/恢复。
- 架构文件新增可选来源信息，无数据迁移要求，旧 JSON 仍可读取。
- `WikiArchitecture.save(root:)` 现在会抛错；相关调用和测试已适配。
- `WikiCurationRunner.preview` 现在是异步函数；界面与验证入口已适配。
- 新执行器的状态按项目共享，但整仓建档仍沿用原单例，不宣称支持多项目同时建档。
- 保留之前未提交的知识可信度、更新建议和业务审查改动。未提交或推送 Git。
- 只重新构建工作区开发包；不自动退出、覆盖或重启 `/Applications/QiyideDev.app`。

## 验证与证据

- 完整 App：编译通过；针对真实 App 模块的 105 项相关测试在 10 个 suite 中全部通过，不代表运行了全项目所有 XCTest。
- 轻量 Wiki/AI：102 项测试在 9 个 suite 中全部通过。
- 真实 SwiftUI：10 张隔离界面截图完成渲染与检查。
- 开发包：重新组装 `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev.app`，深度/严格签名验证通过。
- 已安装版本：打包前后 `/Applications/QiyideDev.app` 的可执行文件摘要一致，未退出或替换它。

- 针对真实 App 模块执行 Swift Testing，包含架构生命周期、模型结构校验、来源变化、可靠保存、取消、进度分层与活动/恢复能力回归。
- 轻量 Wiki/AI 模块测试包含相同业务源码与测试，不代替完整 App 的编译/测试。
- `interaction-preview` 使用临时项目和真实 SwiftUI 组件。等待与保存失败是隔离替身；静态生成、写盘、空知识库读取和取消实际执行。
- 已渲染并检查：900pt 首建/未配置、1280pt 运行/完成/保存失败/域详情、深色跨视角和建档面板。
- 没有向真实模型发送项目代码，没有执行远程 Git、用户项目删除或生产测试。
- 尚未动态验证：真实代理故障/长时间无响应、真实运行进程的暂停恢复、整仓多轮真实模型调用。恢复状态策略有测试；信号执行未操纵用户进程。
- 不宣称 M3 的 Git 长操作、LSP、编辑表单、全部批量/撤销交互已经统一改造。

验证命令：

```bash
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/package-dev-spm.sh --test
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/run.sh test
bash /Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/run.sh interaction-preview /Users/ext.liangzhenqi1/.codex/visualizations/2026/11/11/01a1c9ef-49ef-7680-835d-dc3c608c6b9a/interaction-implementation
```

日志与图片：

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-spm/interaction-full-test.log`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-spm/test.log`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/interaction-tests.log`
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/interaction-preview.log`
- `/Users/ext.liangzhenqi1/.codex/visualizations/2026/11/11/01a1c9ef-49ef-7680-835d-dc3c608c6b9a/interaction-implementation/`

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiOperation.swift` — 任务快照、状态、阶段和可信进度。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Models/WikiArchitecture.swift` — 可选来源元数据、严格读取和可靠保存。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiArchitectureInput.swift` — 内容摘要与可取消后台工作。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiArchitectureBuilder.swift` — 候选与提交拆分、来源/配置核对。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiArchitectureRunner.swift` — 按项目共享、去重、取消与保存重试。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiArchitecturePlanner.swift` — 静态来源、模型尝试与结构有效性。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiModelClient.swift` — 可观察重试与取消传播。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiDependencyGraph.swift` — 解析计数、节流与取消检查。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiOperationViews.swift` — 常驻任务条、阶段视图与任务详情。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiWindow+Operations.swift` — 永久导航、任务适配和架构域详情。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiWindow.swift` — 视角空态隔离、任务订阅与消息关闭。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiWindow+Center.swift` — 局部操作、静态替代、结果选择。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiWindow+Toolbar.swift` — 当前视角的筛选与导出反馈。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiArchitectureView.swift` — 同源选择、来源标识。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiStore.swift` — 架构读取失败不冒充空态。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Service/WikiCurationRunner.swift` — 异步预览、覆盖统计与取消/轮次隔离。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Wiki/Views/WikiIngestSheet.swift` — 分层进度、项目作用域与后台收起。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/ActivityViewer/Notifications/TaskNotificationHandler.swift` — 项目隔离和未知进度恢复。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Tasks/Models/CETaskStatus.swift` — 暂停/恢复能力。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Tasks/Models/CEActiveTask.swift` — 恢复判断与信号失败反馈。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Wiki/WikiOperationTests.swift` — 隔离回归。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/InteractionPreview.swift` — 真界面与临时项目验证。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/run.sh`、`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/main.swift`、`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/wiki-dev/Stubs.swift` — 渲染入口和设置路由替身。
