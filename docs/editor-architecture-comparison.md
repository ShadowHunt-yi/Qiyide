# 编辑器架构与行业前沿对比

> 对象：本项目（CodeEdit / Qiyide，原生 macOS）vs VS Code (Monaco)、Zed、JetBrains Platform
> 方法：先读本项目三个包的实现（`CodeEdit` / `CodeEditTextView` / `CodeEditSourceEditor`），
> 再对照各家公开的架构与默认参数。结论只写能对上源码或官方文档的部分。

---

## 0. 一句话定位

本项目是**原生 macOS 轻量编辑器**：文本层用 `NSTextStorage`、行索引是手写红黑树、
高亮用 tree-sitter + 视口查询、语言智能走 LSP。
它不属于"下一代架构"（没有 CRDT、没有 GPU 渲染、没有 Wasm 扩展），
但在**文本输入与排版**这条链路上是原生实现，且有若干局部设计达到了前沿水平（后述）。

---

## 1. 十二维度对比

| # | 维度 | 本项目 | VS Code (Monaco) | Zed | JetBrains |
|---|---|---|---|---|---|
| 1 | 运行形态 | 原生 Swift/AppKit | TypeScript + Electron（DOM 渲染） | Rust + GPUI，GPU 直绘（Metal/Vulkan/D3D） | JVM + Swing/JCEF |
| 2 | 文本缓冲 | `NSTextStorage`（`NSAttributedString`，全文驻留） | `PieceTreeTextBuffer`（piece table，编辑 O(log n)） | Rope + `MultiBuffer` + CRDT | `CharSequence` + PSI 树 |
| 3 | 行索引 | 手写**红黑树**（`TextLineStorage`，用 `Unmanaged` 换掉 ARC 开销，实测 −15%） | 行号映射 + 增量 token 缓存 | SumTree（计入子树计数） | 索引（stub tree） |
| 4 | 排版 | 自绘 `TextLayoutManager` + `TextLine/LineFragment`，行级布局 | 逐行 DOM + FastDom 批处理 | GPU 文本管线 | Swing 绘制 + 文本布局 |
| 5 | 视口虚拟化 | ✅ 只布局/绘制视口附近行，`LineFragmentView` 复用队列 | ✅ 只渲染视口行 | ✅ 脏矩形 + 增量 | ✅ |
| 6 | 语法高亮 | tree-sitter（解析 + 查询），LSP 语义 token 叠加 | TextMate/Monarch 词法 + Semantic Tokens，跑在 Web Worker | tree-sitter 增量解析，AST 级复用 | 增量 lexer（restartable）+ PSI |
| 7 | 增量粒度 | 编辑经 `applyEdit` 进队列，查询按 4096 字符分块、只查视口 ∩ 失效区 | 按行 tokenize，超长行跳过 | AST 节点级 | 词法状态（lexer state）级 |
| 8 | 大文件策略 | 解析按 100 万字符分流同步/异步（本次新增）；blame 行级标注按 20 万字符闸门；>200 万字符关 minimap | `largeFileOptimizations`（默认 true，50MB 触发）+ `maxTokenizationLineLength`（默认 20000） | 默认强，依赖 rope/CRDT | `idea.max.intellisense.filesize` 等阈值 |
| 9 | 折叠 | ❌ 只有 ribbon 视图与开关，**无折叠引擎** | ✅ 按缩进/区域 | ✅ | ✅ 基于 PSI |
| 10 | 查找替换 | ❌ 转发给 `NSTextView.performFindPanelAction`，自绘 TextView 未实现 → 菜单不可用 | ✅ 全功能 + 正则 + 全仓 | ✅ | ✅ 索引级 |
| 11 | 多光标 / 列选 | ✅（`Cursors` 模块、列选择） | ✅ | ✅ | ✅ |
| 12 | 语言智能 | ✅ LSP（`LanguageClient` + 语义 token + 诊断），文件内符号（JumpBar） | ✅ LSP，独立进程 | ✅ LSP + tree-sitter | ❌ 不用 LSP，走自研 PSI/索引 |
| 13 | 全局索引 | ❌ 无（只有文件内符号） | ✅ 全文搜索 + 符号索引 | ✅ | ✅ 索引驱动重构 |
| 14 | 协作 | ❌ | Live Share（插件，非内建 CRDT） | ✅ 原生 CRDT，延迟 <50ms | Code With Me |
| 15 | 扩展模型 | ❌ 无插件体系 | Node.js 扩展（可任意系统调用） | WASM 沙箱（600+） | JVM 插件 + 扩展点 |
| 16 | AI | 面板式（AIReview、知识库建档），**无内联补全** | Copilot 等扩展 | 原生 Agent 面板 + 内联 | AI Assistant |

---

## 2. 逐项差距分析

### 2.1 文本缓冲：最大的结构性差距

我们是 `NSTextStorage`（一段 `NSAttributedString` 全文驻留）。对比：

- **piece table（VS Code）**：原文只读 + 追加缓冲，编辑是"切片组合"，撤销栈天然轻量；
  百万行文件的插入仍是 O(log n)，且不复制正文。
- **rope（Zed / Neovim / Helix）**：树状字符串，按块共享，适合大文件与多缓冲（MultiBuffer）。
- **我们**：`NSTextStorage` 的编辑是 `NSMutableAttributedString` 的替换，
  好处是**与 AppKit 文本系统（输入法、辅助功能、拼写检查、系统查找）零摩擦**；
  代价是大文件每次结构变更都可能触碰整段存储，且属性（高亮）也挂在同一棵树上。

这不是"落后"，是**取舍**：原生输入体验是我们最大的优势，也是最大的约束。
真要换 piece table，等于重写 `TextView` 的存储层，并放弃 `NSTextStorage` 带来的系统集成。

### 2.2 折叠与查找：不是性能问题，是功能缺位

**折叠**：`GutterView` 里有 `foldingRibbon` 视图、配置里也有 `showFoldingRibbon` 开关，
但 `CodeEditTextView` 中**不存在 `foldedRanges` / `FoldingModel` 一类的结构**——
ribbon 目前只是画在 gutter 上的一个视图，背后没有折叠引擎，点了不会收起任何行。

**查找**：`FindCommands` 的实现是把动作转发给 first responder 的
`NSTextView.performFindPanelAction(_:)`（还先用 `responds(to:)` 判断了一次）。
但我们的 `TextView` 是 `NSView` 子类、自绘文本，**没有实现这个方法**，
也没有 `NSTextFinder` / `usesFindBar`。结果是查找菜单基本不可用——
不是"弱"，是这条路压根没接上。

这两项在 VS Code / Zed / JetBrains 都是**默认能力**，属于日常使用频次最高的功能之一。

### 2.3 高亮与解析：局部已到前沿

- tree-sitter 本身是 Zed 作者的作品，广泛用于 Neovim/Helix/Zed/Emacs；
  我们用它 + LSP 语义 token 叠加，方案与 VS Code（TextMate + Semantic）同级。
- 增量编辑走 `applyEdit` 队列，查询只查"视口 ∩ 失效区"，每块 4096 字符——
  与 VS Code 的 view-based tokenization 思路一致。
- 本次刚修的两处，正好对应行业的两条默认策略：
  - **初始解析按文档大小分流异步**（对应 VS Code 的 worker 化 tokenization）
  - **查询范围受视口约束**（对应 `maxTokenizationLineLength` + viewport 渲染）

仍缺的一条：**超长行跳过**。VS Code 默认 20000 字符，我们没有等价物，
minified JSON / 单行日志仍会进 tree-sitter。

### 2.4 语言智能：LSP 与 PSI 是两条路

- VS Code / 我们：LSP（跨编辑器复用，能力取决于语言服务器）
- JetBrains：PSI + 索引（重构、查找引用等能力更强，但每种语言都要写前端）

我们选了 LSP 是合理的（轻量、多语言成本低），代价是**没有项目级索引**：
"查找引用/重命名/全局符号"这类能力，LSP 能给一部分，但跨文件的体验弱于 JetBrains。

### 2.5 协作与扩展：目前是 0

Zed 把 CRDT 做进缓冲层，协作是"架构原生"；VS Code 走扩展（Live Share）。
我们没有协作，也没有扩展体系——这意味着**能力上限由我们自己写多少决定**。

### 2.6 AI：有功能，但没有"编辑器内"的位置

现有 AI 是面板式（AIReview 评审、知识库建档），属于"围绕代码的 AI"。
前沿编辑器（Zed / Cursor / VS Code+Copilot）已经把 AI 放进**编辑流**：
内联补全（inline completion）、行内 diff、Agent 直接改文件。
我们缺的是最贴近输入的那一层。

---

## 3. 相对优势（别只盯差距）

| 优势 | 说明 |
|---|---|
| 原生输入与无障碍 | `NSTextStorage` 让输入法、辅助功能、系统查找、拼写检查天然可用；Electron 系编辑器长期在这上面踩坑 |
| 自绘排版可控 | 行级 `LineFragment` + 红黑树行索引，中文/混合字体/行高都能自己调，不受 DOM 排版限制 |
| 双通道高亮 | tree-sitter（结构）+ LSP（语义 token）+ XML 专用词法，按语言选路 |
| 代码量小 | 三个包合计约数万行，改动成本远低于 VS Code（数百万行）；本次两轮性能修复都在一天内完成 |
| 原生性能基线 | 无 Electron 运行时，启动与常驻内存基线优于 Web 系（Debug 构建实测空载约 268MB 物理内存，Release 会更低） |

---

## 4. 建议的优先级

### P0（功能缺位，日常必用）

1. **折叠引擎**：`FoldingModel`（按缩进 + 语言规则产出 foldable range）+
   `TextLayoutManager` 跳过折叠区间 + 点击 ribbon 切换。
2. **查找替换面板**：会话式（当前文件/选中/全仓），正则、大小写、整词；
   底层的行索引已经支持按行定位，成本主要在 UI 与状态机。

### P1（性能与架构）

3. **超长行跳过**（对应 `maxTokenizationLineLength`）：
   在 `queryLayerHighlights` 前按行判断长度，超限直接返回空。
4. **属性应用的最小化**：`setLanguage`/主题切换会 `setAttributes` 覆盖全文，
   大文件上这是 O(n) 主线程操作；可按视口 + 增量失效替代。
5. **LSP 大文件保护**：`didOpen` 全文同步可考虑按阈值降级为增量/延迟。

### P2（追前沿）

6. 项目级索引（符号/引用）——决定重构类能力上限
7. 内联补全（AI 进入编辑流）
8. 扩展机制（即便只是脚本级 hook）

---

## 5. 一句话总结

架构代际上我们落后一代（无 rope/piece table、无 CRDT、无 GPU 渲染、无索引），
但**问题不在于追赶这些**：真正影响日常使用的是折叠与查找的缺位（P0），
其次是属性应用与超长行这类"局部 O(n)"（P1）。
高亮与解析这条线，在本次修复后已经和主流方案同构。
