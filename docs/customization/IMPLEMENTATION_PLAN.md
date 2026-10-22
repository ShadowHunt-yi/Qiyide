# CodeEdit 三项定制功能实施方案

> 范围：中文国际化、多工作区、内存控制。
> 代码基线：CodeEdit `fa2aebd8`（main），CodeEditTextView `d7ac3f1`，CodeEditSourceEditor `1fa4d3c`，CodeEditLanguages `32a1ddc`。
> 本文档所有结论均基于本地源码核对，标注了 `文件:行号` 作为证据。标注「估算」的数值需在 M0 阶段实测校准。

---

## 0. 结论摘要

| 事项 | 结论 |
|---|---|
| 三个包的定位 | 编辑器内核，不含应用层。CodeEdit 主工程通过 SwiftPM 以版本号锁定，本地源码目前**未接入构建** |
| 中文国际化 | 主工程约 **651 处** UI 字面量、包内 **86 处**，现有本地化键仅约 55 条。属于「从零建设」，不是「补齐翻译」 |
| 多工作区 | 多窗口已天然支持（1 窗口 = 1 个 `WorkspaceDocument`），但**无工作区实体**：状态以文件夹 URL 为键、设置为全局单例 |
| 内存控制 | 存在 4 个确证的结构性开销：小地图双份布局、高亮属性全量写入、LSP 服务器不随窗口退出、tree-sitter 每文档一树 |
| 实施顺序建议 | M0 度量基线 → M1 低风险内存项 → M2 多工作区（模型层）→ M3 全量 i18n → M4 多根工作区 → M5 验收 |
| 最大风险 | 三个包是第三方 fork，必须改为本地 path 依赖并纳入版本管理，否则改动会被 SwiftPM 覆盖 |

---

## 1. 现状梳理

### 1.1 包与应用的依赖关系

```
CodeEdit (app, 55.5k 行 / 630 文件)
 ├─ CodeEditSourceEditor (14.6k 行 / 157 文件)   编辑器外层：视图控制器、高亮、折叠、迷你地图、查找
 │   ├─ CodeEditTextView (9.4k 行 / 92 文件)      文本内核：布局、行存储、选区、渲染、输入
 │   ├─ CodeEditLanguages (1.3k 行 / 5 文件)      tree-sitter 语法与查询（39 种语言，含二进制 xcframework）
 │   ├─ CodeEditSymbols / TextFormation
 ├─ CodeEditKit / WelcomeWindow / AboutWindow     UI 组件（**不在本地，含用户可见文案**）
 └─ LanguageClient / GRDB / Sparkle / SwiftTerm ...
```

三个包的分工边界清晰：`TextView` 只做文本与渲染，`SourceEditor` 只做编辑体验，`Languages` 只做语法数据。**没有任何一个包含应用级 UI（导航、设置、Git、终端）**，因此三项功能的主要工作量在 CodeEdit 主工程。

### 1.2 版本对账（必须先处理）

| 包 | 本地 HEAD | 主工程 `Package.resolved` 锁定 | 状态 |
|---|---|---|---|
| CodeEditTextView | `d7ac3f1` | `d7ac3f11` (0.12.1) | 一致 |
| CodeEditSourceEditor | `1fa4d3c` | `ee0c00a` (0.15.1) | 本地领先若干提交 |
| CodeEditLanguages | `32a1ddc` | `331d5db` (0.1.20) | 本地领先若干提交 |

主工程当前**没有**本地 path 依赖。若只在 `/Users/ext.liangzhenqi1/project/mycase/*` 改代码，`xcodebuild` 仍会去 GitHub 拉取 `0.15.1`，改动完全不生效。这是第一步必须解决的前置条件（见 §5.1）。

### 1.3 与三项功能直接相关的现状（含证据）

| 观察 | 证据 | 影响 |
|---|---|---|
| 工程使用 Xcode 同步文件夹 | `project.pbxproj` 中 `PBXFileSystemSynchronizedRootGroup` × 7 | 新增资源文件自动入 target，无需手改 pbxproj；但也意味着 `.lproj`/`.xcstrings` 一旦放错目录会被静默打包 |
| 本地化基础设施近乎为零 | `NSLocalizedString`/`String(localized:)` 仅 16 处；`Localization/en.lproj/Localizable.strings` 仅 80 行 | 需要全量改造，不能靠补翻译完成 |
| 每个窗口 = 一个 `WorkspaceDocument` | `WorkspaceDocument.swift:15`、`makeWindowControllers()` | 多窗口已有基础，缺「工作区」抽象 |
| 窗口状态以文件夹 URL 为键 | `WorkspaceDocument.swift:22-31`（`workspaceState-\(fileURL)`） | 同一文件夹的不同工作区配置会互相污染 |
| 全局设置是单例 | `Settings.swift:21`（`static let shared`）+ `~/Library/Application Support/CodeEdit/settings.json` | 无按工作区覆盖能力 |
| 工作区设置仅 2 个字段 | `CEWorkspaceSettingsData.swift:14-15`（`project`、`tasks`） | 已有 `.codeedit/settings.json` 通道，可复用扩展 |
| LSP 已按 (语言, 路径) 分键 | `LSPService.swift` `ClientKey(languageId, workspacePath)` | 多工作区天然隔离，但**只按路径**，同路径多工作区仍会冲突 |
| LSP 服务器关窗回收 | `CodeEditDocumentController.swift:124-129` 已调用 `closeWorkspace`；`LSPService.swift:266` | **已修正初版判断**：停止逻辑存在，但按路径精确匹配（尾部斜杠会失配）且未取消事件监听任务，见 EXECUTION_REPORT |
| 迷你地图无条件创建 | `TextViewController+Lifecycle.swift:46` | 每个编辑器实例多一份完整布局索引 |
| 迷你地图复用同一 textStorage 但自建布局 | `MinimapView.swift:142-155` | 内存翻倍，文本不重复 |
| `showMinimap` 只控制隐藏 | `SourceEditorConfiguration+Peripherals.swift:24,63-67` | 关闭小地图**不省内存** |
| 高亮属性直接写入 textStorage | `Highlighter.swift:267` | 属性 run 随滚动累积，最终覆盖全文 |
| tree-sitter 状态每文档一份 | `TreeSitterState.swift:13-70` | 每个打开标签各持一棵语法树 |

---

## 2. 功能一：中文国际化

### 2.1 方案对比

| 方案 | 做法 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| A. String Catalog（`.xcstrings`） | Xcode 15+ 资源，源字符串为键，en/zh-Hans 同文件维护 | 工具链完整（自动提取、复数、设备变体、审校状态）；SwiftUI/AppKit 通吃 | 需 `defaultLocalization`；大文件在 Git 中 diff 较吵 | **推荐** |
| B. 传统 `.strings` + `zh-Hans.lproj` | 手工维护两份 strings | 兼容性最好，diff 干净 | 无复数规则、无提取工具、键易漂移 | 备选（包内若需兼容旧工具链） |
| C. 自研 L10n 层（enum key + 运行时切换） | 自建 `L10n.t(.openFile)` | 可在应用内即时切换语言 | 需改造全部 780 处调用点，失去 Xcode 提取能力，维护成本最高 | 仅当「不重启切换语言」是硬需求时 |

**推荐 A**，理由：现有代码 90% 以上是 SwiftUI `Text("字面量")`，其参数类型为 `LocalizedStringKey`，**天然走 String Catalog 查找**，不需要改调用点；只需补资源 + 改造剩余 10%（动态字符串与 AppKit 文本）。

### 2.2 字符串盘点

| 位置 | `Text(` | `Button(` | `Label(` | `.help(` | `title:` | 小计 |
|---|---|---|---|---|---|---|
| CodeEdit 主工程 | 327 | 165 | 28 | 40 | 91 | **651** |
| CodeEditSourceEditor | 61 | 0 | 0 | 3 | 1 | **65** |
| CodeEditTextView | 22 | 0 | 0 | 0 | 3 | **25** |
| CodeEditLanguages | 0 | 0 | 0 | 0 | 0 | 0 |

另需处理的非 SwiftUI 文本：

| 类型 | 处数 | 说明 |
|---|---|---|
| `NSAlert` | 17 个文件 | `messageText` / `informativeText`，不自动本地化 |
| `NSMenuItem(` | 15 处 | 主工程 15 + 包内 6，需 `NSLocalizedString` |
| `String(format:)` | 7 处 | 复数与占位符需改为本地化格式 |
| 枚举展示名 | 多处 | `SettingsPage.Name`、`FileIcon.FileType`、`IndentOption`、`LineEnding` 等，需 `LocalizedDisplayName` 协议 |
| `CodeLanguage.tsName` | 39 种语言 | 建议**保留英文**（业界惯例），仅「Pure Text」等少数做映射 |

预计唯一键 **≈ 700 条**；`Text("...")` 中约 8% 是带插值的（`Text("Open \(name)")`），走 `%@` 占位符。

### 2.3 改动文件清单

| 文件 | 改动 |
|---|---|
| `CodeEdit/Localization/en.lproj/Localizable.strings` | 迁移为 `CodeEdit/Localization/Localizable.xcstrings`（保留旧文件直到 M3 验收） |
| `CodeEdit.xcodeproj/project.pbxproj` | `knownRegions` 增加 `zh-Hans`（同步文件夹下资源自动入包，但区域需登记） |
| `CodeEdit/Info.plist` | `CFBundleDevelopmentRegion` 保持 `en`；补 `CFBundleLocalizations = [en, zh-Hans]` |
| `CodeEdit/Utils/Localization/L10n.swift`（新增） | 统一封装：`String.localized`、`LocalizedDisplayName` 协议、复数辅助 |
| `CodeEdit/Features/Settings/Models/SettingsPage.swift` | `Name` 枚举的 `title` 从 `String` 改为本地化键 |
| `CodeEdit/Features/Settings/Models/PageAndSettings.swift` | `settingName: String` 参与搜索，需同时输出本地化名与英文名（搜索兼容） |
| `CodeEdit/Features/WindowCommands/*.swift`（12 个） | 菜单标题：`.keyboardShortcut` 邻近的 `Text`/`Button` 无需改，`CommandMenu("...")` 需确认绑定到 `LocalizedStringKey` |
| `CodeEdit/Features/Settings/Pages/**`（13 页） | 主要字面量集中地，逐页核对；重点：`GeneralSettingsView`（29 处）、`FeedbackView`（27 处）、`TextEditingSettingsView`（25 处） |
| `CodeEdit/Features/CEWorkspaceSettings/Views/*.swift` | 任务表单、环境变量、错误提示 |
| `CodeEdit/Features/SourceControl/**` | Git 错误信息、账户登录、克隆面板；错误文本多数来自 `GitClient` 的 `String`，需在展示层包 `LocalizedStringKey` |
| `CodeEditSourceEditor/Package.swift` | 增加 `defaultLocalization: "en"`（当前缺失，加 `.xcstrings` 后会编译失败） |
| `CodeEditSourceEditor/Sources/.../Find/**`、`CodeSuggestion/**`、`Gutter/**` | 65 处文案 + 6 处 `NSMenuItem` |
| `CodeEditTextView/Package.swift` | 增加 `defaultLocalization: "en"` |
| `CodeEditTextView/Sources/.../TextView/TextView+Menu.swift` | 右键菜单项 3 处 |
| `CodeEdit/Features/Feedback/FeedbackView.swift` | 若反馈内容提交到远端，界面文案本地化、上报字段保持英文 |

**不在范围内但影响「完整覆盖」**：`WelcomeWindow`、`AboutWindow`、`CodeEditSymbols` 三个包内也有文案（欢迎页按钮、关于页脚注）。它们不在本地三个包中，需一并 fork 才能做到 100% 覆盖。若不 fork，中文界面上会残留少量英文（可接受，但需在验收标准里写明）。

### 2.4 数据结构与接口

```swift
// CodeEdit/Utils/Localization/L10n.swift（新增）
import Foundation

enum L10n {
    /// 供 AppKit 场景使用：NSAlert / NSMenuItem / NSPanel
    static func t(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}

/// 需要出现在 UI 的枚举统一实现该协议，避免在 View 内散落 switch
protocol LocalizedDisplayName {
    var localizedName: String { get }
}

extension SettingsPage.Name: LocalizedDisplayName {
    var localizedName: String { L10n.t(rawValue) }   // rawValue 作为稳定键
}
```

包内（`CodeEditSourceEditor` / `CodeEditTextView`）：

```swift
// Sources/<Target>/Localization/Bundle+Localized.swift（每个包新增一份）
extension String {
    var moduleLocalized: String {
        NSLocalizedString(self, bundle: .module, comment: "")
    }
}
```
包内必须显式 `bundle: .module`，否则会去主 App bundle 查键而失效——这是 SPM 本地化最常见的坑。

### 2.5 验收标准

1. `语言与地区` 设为「简体中文」启动，主窗口、设置 13 页、菜单栏、右键菜单、弹窗、欢迎页无英文残留（除语言名、路径、Git 输出等专有内容）。
2. 切换为英文，界面与原版一致，无键名泄露（不出现 `settings.general.appearance` 这类 key）。
3. `xcrun xcstrings-tool` 或 Xcode 的「未翻译」统计为 0（允许白名单）。
4. 带插值文案在两种语言下占位符顺序正确（中文语序不同，必须用 `%@` 而非字符串拼接）。

---

## 3. 功能二：多工作区

### 3.1 语义必须先定义

「多工作区」有三种不同实现，成本差一个数量级：

| 方案 | 语义 | 用户体验 | 改动量 | 风险 |
|---|---|---|---|---|
| **A. 多窗口多工作区** | 1 窗口 = 1 文件夹；新增工作区管理器（命名、最近列表、切换、独立状态） | 类似 VS Code 打开多个窗口 | 中 | 低 |
| **B. 单窗口多根** | 1 窗口 = N 个文件夹（`.codeedit/workspace.json`），导航树多根、搜索跨根、Git 多仓库 | 类似 VS Code `.code-workspace` | 大 | 高（导航、搜索、Git、LSP 全链路） |
| **C. A + B** | 先做 A 的模型层，再让工作区支持多根 | 完整对标 VS Code | 最大 | 分阶段可控 |

**推荐 C，分两期交付**：M2 做 A（模型 + 管理器 + 状态隔离），M4 在 A 的模型上扩多根（B 只是把 `folders: [WorkspaceFolder]` 从 1 个变成 N 个，数据结构不用推翻）。

### 3.2 目标架构

```
WorkspaceManager（单例服务，ServiceContainer 注册）
 ├─ workspaces: [Workspace]        工作区定义（持久化到 Application Support/workspaces/*.json）
 ├─ recents: [Workspace.ID]        最近打开
 ├─ create / open / save / delete / duplicate
 └─ openInNewWindow(_:)
        │
        ▼
WorkspaceDocument（NSDocument，每窗口一个）
 ├─ workspaceID: UUID              状态与配置的唯一键（替换 fileURL 作键）
 ├─ folders: [URL]                 单根期只有 1 个
 ├─ registry: SharedResourceRegistry
 └─ existing managers: editorManager / searchState / taskManager / ...

SharedResourceRegistry（新增，关键：避免同一目录被多窗口重复加载）
 ├─ fileTree(for: URL) -> CEWorkspaceFileManager      引用计数，同目录共享
 ├─ sourceControl(for: URL) -> SourceControlManager
 ├─ lspSession(for: Workspace.ID) -> LSPSessionSet
 └─ release(_:)                                       引用归零时释放
```

**为什么需要 `SharedResourceRegistry`**：若不共享，打开同一文件夹的两个窗口会各持一份文件树、一个 Git 轮询器、一组 LSP 进程，内存成倍增长。共享 + 引用计数是「多工作区」与「轻量化」两个需求的交汇点，必须一起设计。

### 3.3 配置与状态隔离（核心）

**配置分层**（优先级自低到高）：

```
1. 内置默认值        SettingsData.init()
2. 用户全局          ~/Library/Application Support/CodeEdit/settings.json      （现有）
3. 工作区            <workspace>.json 的 settings 字段                          （新增）
4. 文件夹            <root>/.codeedit/settings.json                            （现有通道，仅 2 字段）
5. 文档级            CodeFileDocument.indentOption / defaultTabWidth / wrapLines（现有）
```

实现策略：**JSON 层合并 + 一次解码**，而不是为每一层写一份 optional 镜像结构（那会产生 10 个组 × 5 层 = 50 个类型）。

```swift
struct SettingsResolver {
    /// 依次深合并 JSON 字典，最终解码为强类型 SettingsData
    func effective(workspace: Workspace?, folder: URL?) throws -> SettingsData
}
```
优点：复用现有 `SettingsData: Codable`，新增设置项零改动；数组整体替换、对象深合并，语义与 VS Code 一致。
代价：丢失编译期字段校验，需在 M2 加单元测试覆盖「未知键忽略、类型冲突以高层为准」。

**状态隔离**：

| 状态 | 现状 | 目标 |
|---|---|---|
| 窗口尺寸/位置 | `UserDefaults`，键含 fileURL | 键含 `workspaceID` |
| 打开标签/布局 | `workspaceState-<fileURL>` | `workspaceState-<workspaceID>`，并支持导出到工作区文件（可携带） |
| 光标/滚动 | `editor-restoration.db`，键为文件 URI | 增加 `workspaceID` 列（DB 迁移，别删旧迁移） |
| 搜索索引 | 每文档 `SearchIndexer`（SKIndex 落盘） | 每工作区一个索引文件，路径含 `workspaceID` |
| LSP | `ClientKey(language, workspacePath)` | `ClientKey(language, workspaceID)` |
| Git | 每窗口一个 `SourceControlManager` | 每根目录一个，经 registry 共享 |

### 3.4 改动文件清单

| 文件 | 改动 | 期 |
|---|---|---|
| `CodeEdit/Features/Workspace/Models/Workspace.swift`（新增） | `Workspace`、`WorkspaceFolder`、`WorkspaceState` 模型 | M2 |
| `CodeEdit/Features/Workspace/WorkspaceManager.swift`（新增） | CRUD、最近列表、持久化、打开窗口 | M2 |
| `CodeEdit/Features/Workspace/SharedResourceRegistry.swift`（新增） | 目录级资源共享与引用计数 | M2 |
| `CodeEdit/Features/Workspace/Views/WorkspaceSwitcher.swift`（新增） | 工具栏/菜单切换器 | M2 |
| `CodeEdit/Features/Documents/WorkspaceDocument/WorkspaceDocument.swift` | 增加 `workspaceID`、`folders`；状态键改造；`close()` 补资源释放 | M2 |
| `CodeEdit/Features/Documents/Controllers/CodeEditDocumentController.swift` | 去重键改为 `workspaceID`；新增「打开工作区」入口 | M2 |
| `CodeEdit/AppDelegate.swift` | 会话恢复按工作区；关窗释放 LSP | M2 |
| `CodeEdit/Features/WindowCommands/FileCommands.swift` | 菜单项：新建/打开/保存工作区、将文件夹添加到工作区（M4） | M2/M4 |
| `CodeEdit/Features/Settings/Models/Settings.swift` | 增加 `resolver`，`shared.preferences` 保留为「用户层」 | M2 |
| `CodeEdit/Features/Settings/Pages/**/Views/*.swift` | 设置页增加作用域切换（用户/工作区），写入对应层 | M2 |
| `CodeEdit/Features/CEWorkspaceSettings/Models/CEWorkspaceSettingsData.swift` | 扩展为工作区配置（settings 覆盖 + folders 列表） | M2 |
| `CodeEdit/Features/CEWorkspace/Models/CEWorkspaceFileManager.swift` | `folderUrl` → `roots: [URL]`，`workspaceItem` → `roots: [CEWorkspaceFile]` | M4 |
| `CodeEdit/Features/NavigatorArea/ProjectNavigator/OutlineView/*.swift` | 数据源由单根改数组；多根分组显示 | M4 |
| `CodeEdit/Features/SourceControl/SourceControlManager.swift` | 由「一个仓库」改为「多仓库集合」+ 汇总状态 | M4 |
| `CodeEdit/Features/LSP/Service/LSPService.swift` | `ClientKey` 加 `workspaceID`；`stopServers(forWorkspace:)` | M2 |
| `CodeEdit/Features/Documents/Indexer/SearchIndexer.swift` | 索引路径按工作区划分；关窗关闭索引 | M2 |
| `CodeEdit/Features/Editor/Models/Restoration/EditorStateRestoration.swift` | 迁移：加 `workspaceID` 列 | M2 |

### 3.5 数据结构草案

```swift
struct Workspace: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var folders: [WorkspaceFolder]        // M2 固定 1 个，M4 放开
    var settings: [String: JSONValue]     // 工作区级覆盖，深合并进 SettingsData
    var createdAt: Date
}

struct WorkspaceFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var path: String                      // 存绝对路径；相对路径留给 M4 的可移植工作区文件
    var name: String?                     // 导航树显示名覆盖
}

/// 可携带的工作区状态（保存到工作区文件时使用）
struct WorkspaceState: Codable {
    var openFiles: [String]               // 相对路径
    var activeFile: String?
    var editorLayout: Data?               // EditorLayout 的编码结果
    var expandedFolders: [String]
    var terminalSessions: Int
}
```

接口：

```swift
@MainActor
final class WorkspaceManager: ObservableObject {
    static let shared: WorkspaceManager
    @Published private(set) var workspaces: [Workspace]
    @Published private(set) var recents: [Workspace.ID]

    func create(name: String, folders: [URL]) throws -> Workspace
    func open(_ id: Workspace.ID, inNewWindow: Bool) throws
    func save(_ workspace: Workspace) throws
    func delete(_ id: Workspace.ID) throws
    func addFolder(_ url: URL, to id: Workspace.ID) throws     // M4
}
```

---

## 4. 功能三：内存控制

### 4.1 内存热点（按确证程度排序）

| # | 位置 | 机制 | 后果 | 确证 |
|---|---|---|---|---|
| 1 | `MinimapView.swift:142` + `TextViewController+Lifecycle.swift:46` | 每个编辑器实例创建第二个 `TextLayoutManager`（独立红黑树行索引 + 独立行片段视图 + 独立 `TextSelectionManager`），仅共享 `textStorage` | 每个打开标签的布局内存 **×2**；`showMinimap=false` 只 `isHidden`，不省内存 | 代码确证 |
| 2 | `Highlighter.swift:267` | `textStorage.setAttributes(...)` 直接把语法属性写进文本存储；`HighlightProviderState.validSet`（`:46`）只增不减 | 大文件滚动到底后，全文携带属性 run，内存随「访问过的范围」单调增长 | 代码确证 |
| 3 | `LSPService.swift:266` `closeWorkspace` | 关窗会调用，但①按路径字符串精确匹配，工作区 URL 带尾部斜杠时失配；②未调用 `stopListeningToEvents`，事件监听任务继续持有客户端 | 失配时语言服务器进程随窗口关闭泄漏；监听任务阻止真正释放 | 代码确证（初版判断为「仅退出时停止」，已修正） |
| 4 | `TreeSitterState.swift:13-70` | 每文档一份 `Parser` + `Tree`；注入语言（markdown-html、html-js）会额外建层 | 打开 N 个标签 = N 棵树，后台标签也常驻 | 代码确证 |
| 5 | `Editor.swift:167` | 关闭标签置 `fileDocument = nil` | 已正确释放，非问题 | 代码确证 |
| 6 | `SearchIndexer` | 基于 `SKIndex`（Spotlight），落盘 + 内存映射 | 可接受；但关窗未 `close()` 会持有句柄 | 代码确证 |
| 7 | `TextLineStorage` | 每行一个红黑树节点，O(行数) | 必要成本；但与 #1 叠加后翻倍 | 代码确证 |

### 4.2 成本模型（估算，M0 校准）

以 **1 MB 源码 ≈ 2.5 万行** 为样本：

| 组成 | 估算 | 说明 |
|---|---|---|
| `NSTextStorage` 文本缓冲 | 2–3 MB | UTF-16 + 块存储 |
| 高亮属性 run（全文覆盖时） | 8–20 MB | 每 token 一个 run，run 结构 + 属性字典指针 |
| 行索引（主编辑器） | 2–3 MB | 2.5 万节点 |
| 行索引（迷你地图） | 2–3 MB | 同上，重复一份 |
| tree-sitter 树 | 3–10 MB | 节点数约为 token 数的 2–3 倍 |
| 可见行片段视图 | < 1 MB | 已懒加载 + 复用队列 |
| **合计 / 标签** | **≈ 18–40 MB** | |
| **10 个标签** | **≈ 180–400 MB** | 与「轻量化」目标直接冲突 |

LSP 语言服务器（独立进程，不计入 app footprint）：每个语言 50–300 MB（clangd / sourcekit-lsp / pyright 差异极大）。

> 结论：**内存问题的主因不是文本存储，而是「每标签 ×2 布局 + 全量属性 + 后台树」这三项叠加。**

### 4.3 优化措施矩阵

| 措施 | 收益（估算） | 代价 | 风险 | 涉及文件 |
|---|---|---|---|---|
| **M1-1 迷你地图按需创建**（`showMinimap` 默认 `false` 或仅在窗口宽 > 1200 且文件 < 5000 行时创建；关闭时 `nil` 掉 view 并释放布局） | 每标签 −2–3 MB；大文件更明显 | 关闭后需重建（重建 ~10ms） | 低 | `TextViewController+Lifecycle.swift`、`MinimapView.swift`、`SourceEditorConfiguration+Peripherals.swift` |
| **M1-2 高亮属性窗口化**：仅保留可视区 ± 500 行的属性，离开窗口后 `removeAttribute` 并回收 `RangeStore` 区间 | 大文件 −30%–50%（属性是最大项） | 回滚到旧区域需重新上色（可视区内无感） | 中（需处理滚动抖动、与 LSP 语义高亮叠加） | `Highlighter.swift`、`HighlightProviderState.swift`、`StyledRangeContainer.swift` |
| **M2-1 LSP 生命周期**：`stopServers(forWorkspace:)` + 空闲 10 分钟自动停止 + 重新聚焦时懒启动 | 每工作区 −50–300 MB（进程） | 首次补全延迟（冷启动 1–3 s） | 中（需处理重启后的文档同步） | `LSPService.swift`、`WorkspaceDocument.swift`、`AppDelegate.swift` |
| **M2-2 tree-sitter 树 LRU**：只保留最近 8 个可见文档的解析树，其余释放，聚焦时重解析 | 每后台标签 −3–10 MB | 切换回后台标签时重解析 50–300 ms（可异步） | 中（`TreeSitterClient` 的编辑增量同步需重建基线） | `TreeSitterState.swift`、`TreeSitterClient.swift`、新增 `TreeSitterPool.swift` |
| **M2-3 资源共享**（见 §3.2）：同目录多窗口共享文件树/SCM/LSP | 多窗口场景近似线性节省 | 引用计数与释放顺序复杂度 | 中 | `SharedResourceRegistry.swift`（新增） |
| **M3-1 预览缓存上限**：`ImageFileView` / `PDFFileView` 使用 `NSCache` 并设成本上限 | 每标签 −5–50 MB（大图/大 PDF） | 重新解码 | 低 | `Editor/Views/ImageFileView.swift`、`PDFFileView.swift` |
| **M3-2 关窗彻底释放**：`WorkspaceDocument.close()` 补齐 `searchIndexer.close()`、`sourceControlManager` 取消订阅、LSP 停止 | 修复泄漏基线 | 无 | 低 | `WorkspaceDocument.swift` |

**明确不做的**：
- 不裁剪已打开文档的文本缓冲（会导致数据丢失，不可接受）。
- 不延迟加载用户已打开的标签内容（违背编辑器语义）。
- 不引入全局「按文件大小限制打开」的硬阈值（应改为提示 + 优化）。

### 4.4 度量方案（M0 必须先做）

现有三个包**没有任何内存/性能度量测试**（`XCTMemoryMetric` / `measure(` 均为 0 命中）。建议：

1. **应用层轻量探针**：`MemoryProbe` 读取 `task_vm_info.phys_footprint`，在状态栏 debug 区显示实时 footprint（仅 Debug 构建）。
2. **可复现场景脚本**（手工，固定步骤）：
   - S1 冷启动 → 空窗口 60 s 稳定值
   - S2 打开 10 个 1 MB 文件（各滚动到底）
   - S3 关闭 9 个标签，观察 30 s 回落
   - S4 关闭窗口，观察 LSP 进程是否退出（`ps` 计数）
3. **包级基准**：在 `CodeEditTextViewTests` 增加 `measure(metrics: [XCTMemoryMetric()])` 覆盖「10 万行文档的分页布局」，作为回归闸门。
4. **验收阈值（建议，待确认）**：

| 指标 | 建议阈值 |
|---|---|
| S1 空载 footprint | ≤ 180 MB |
| S2 十标签（1 MB / 个）增量 | ≤ 250 MB |
| S3 关标签后 30 s 回落 | ≥ 关闭前 70% 被释放 |
| S4 关窗后残留 LSP 进程 | 0 |

---

## 5. 实施顺序与里程碑

### 5.1 M0：前置与基线（0.5 周）

1. 三个包在主工程改为 `.package(path: "../CodeEditSourceEditor")` 等本地依赖，或建立内部 fork 分支并改 URL；重新生成 `Package.resolved`。
2. 对齐版本：把本地 HEAD 的改动（`1fa4d3c`、`32a1ddc`）在主工程编译验证，或回退到 pin 版本再做定制，**二选一并记录**。
3. 跑通 `xcodebuild -scheme CodeEdit build` 与 `CodeEditTests`，记录基线。
4. 上线 `MemoryProbe` + 四个场景脚本，产出基线报告。

> 没有 M0，后续所有改动都无法验证是否生效——这是本方案唯一不可跳过的阶段。

### 5.2 后续里程碑

| 里程碑 | 内容 | 依赖 | 交付物 |
|---|---|---|---|
| M1 | 内存低风险项（M1-1、M2-1、M3-2） | M0 | 关闭工作区后进程/内存回落报告 |
| M2 | 多工作区 A 期（模型、管理器、状态隔离、配置分层） | M0 | 可创建/切换工作区，两份工作区配置互不影响 |
| M3 | 全量 i18n（主工程 + 两包） | M2（新 UI 文案需先定型） | 中英双语可切换，翻译覆盖率 100% |
| M4 | 多根工作区（B） | M2 | 单窗口多文件夹、跨根搜索、多仓库 Git |
| M5 | 内存深度优化（M1-2、M2-2、M3-1）+ 验收 | M1、M4 | 达到 §4.4 阈值 |

**顺序理由**：先做 M0 才能归因；多工作区会新增 UI 文案，必须先定型结构再统一翻译（否则翻译两次）；高亮窗口化与 tree-sitter LRU 是三项功能里唯一有「行为回归风险」的改动，放在最后并用基准护栏。

---

## 6. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 包改动被 SwiftPM 覆盖 | 定制功能全部失效 | M0 改为 path 依赖 / 内部 fork，并在 CI 中校验 `Package.resolved` |
| `defaultLocalization` 缺失导致 SPM 编译失败 | 阻塞构建 | 两包 `Package.swift` 同步补上 |
| 包内本地化错误使用主 bundle | 包内文案显示英文 | 统一 `bundle: .module` 封装 + 快照测试 |
| 多根工作区改动外溢到搜索/Git/LSP | 功能回归面积大 | 分两期，A 期先交付可用版本 |
| 高亮窗口化导致滚动闪烁 | 体验退化 | 保留 ±500 行缓冲；A/B 对比录屏验收 |
| tree-sitter 树释放后重解析慢 | 大文件切标签卡顿 | 仅释放后台超过 30 s 的树；异步重解析 + 保留折叠信息 |
| `WelcomeWindow`/`AboutWindow` 未 fork | 中文覆盖不完整 | 明确验收口径，或追加 fork 两个包 |

---

## 7. 待确认决策

1. **多工作区语义**：A（多窗口各一文件夹 + 管理器）、B（单窗口多根）、C（A→B 分期）。方案默认 C。
2. **语言切换方式**：跟随系统、重启生效（成本低）；还是应用内即时切换（需自研 L10n 层，成本最高）。
3. **内存阈值**：是否采用 §4.4 的建议值（180 MB / 250 MB），或另设目标。
4. **是否 fork 并长期维护**：三个包 + `WelcomeWindow` + `AboutWindow`。这决定 i18n 能否做到 100%。
5. **交付方式**：直接进入 M0-M2 编码，还是先做 M0 基线 + 一个纵向切片 PoC（例如只做「迷你地图按需创建 + 设置页中文」）验证链路。

---

## 附录：本次核对使用的命令（可复现）

```bash
# 版本对账
git -C ../CodeEditTextView log -1 --format='%h %ci'
git -C ../CodeEditSourceEditor log -1 --format='%h %ci'
grep -A3 '"identity"' CodeEdit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# 文案盘点
grep -rEo 'Text\("|Button\("|Label\("|\.help\("' CodeEdit --include='*.swift' | wc -l

# 内存热点定位
grep -n "minimapView = MinimapView" ../CodeEditSourceEditor/Sources/CodeEditSourceEditor/Controller/TextViewController+Lifecycle.swift
grep -n "setAttributes(attributeProvider" ../CodeEditSourceEditor/Sources/CodeEditSourceEditor/Highlighting/Highlighter.swift
grep -n "stopAllServers" CodeEdit/AppDelegate.swift
```
