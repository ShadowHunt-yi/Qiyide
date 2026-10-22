# Git 快捷操作与应用图标

本轮两处改动：源代码管理面板「更改」页签下方的快捷操作条，以及 Qiyide 的应用图标。

---

## 1. Git 快捷操作条

### 位置上

```
[ 更改 | 历史记录 | 仓库 ]      ← 分段控件
────────────────────────
[↻] [↓] [↑] │ [▣] [🗑]      ← 快捷操作条（本轮新增）
────────────────────────
提交信息框
改动文件列表
```

只在「更改」页签出现；切到「历史记录」「仓库」时隐藏，因为那两页不需要这些操作。

### 按钮与行为

| 图标 | 提示 | 行为 | 禁用条件 |
| --- | --- | --- | --- |
| ↻ `arrow.triangle.2.circlepath` | 获取更改 | 直接执行 `git fetch`，进行中显示小转圈并禁用按钮 | 获取进行中 |
| ↓ `arrow.down.to.line` | 拉取 | 打开既有拉取弹窗（可选取远端、分支、rebase） | 未配置远端 |
| ↑ `arrow.up.to.line` | 推送 | 打开既有推送弹窗（可选取远端、分支、是否强制） | 未配置远端或无当前分支 |
| ▣ `archivebox` | 储藏更改… | 有改动时打开储藏弹窗；无改动时给出提示 | 无改动 |
| 🗑 `trash` | 放弃所有更改… | 有改动时弹确认框；无改动时给出提示 | 无改动 |

设计取舍：**需要额外输入的操作一律复用现有弹窗**，不在面板里重做一套表单。否则「拉取」要么默认远端、要么自己实现一套选择器，都会和右键菜单、命令面板里的行为不一致。

### 为什么不做成直接执行

`git pull` / `git push` 的远端与分支组合在 CodeEdit 里是可配置的（`SourceControlPullView` / `SourceControlPushView`）。直接执行等于替用户做了决定，一旦默认值不符就会产生意料之外的合并或推送。获取（fetch）无副作用，才做成一步直达。

### 涉及文件

| 文件 | 改动 |
| --- | --- |
| `NavigatorArea/SourceControlNavigator/Views/SourceControlQuickActionsView.swift`（新增） | 快捷操作条本体 |
| `.../SourceControlNavigatorView.swift` | 在「更改」页签插入操作条与分隔线 |

文案全部复用既有译文（`Fetch Changes` / `Pull` / `Push` / `Stash Changes...` / `Discard All Changes...`），未新增本地化键。

---

## 2. 应用图标

### 设计

- **底板**：深靛蓝渐变圆角方形（824×824，圆角 186），四周留 100px 透明边距，符合 macOS 图标栅格。
- **主体**：青蓝渐变的 **Q**——圆环用偶奇填充构造，尾部从碗内穿过环带向右下延伸。
- **细节**：碗内一个白色代码折角 `>`，把「Qiyide」与「代码编辑器」两件事同时说清。

### 生成方式

图标由脚本绘制，不依赖设计工具，可随时重生成：

```bash
xcrun swift scripts/design/make-app-icon.swift /tmp/qiyide-icon
```

脚本输出 1024px 主图，再按 macOS 需要的 10 个尺寸缩放：

```
CodeEdit/Assets.xcassets/AppIcon.appiconset/
├── icon_16x16.png      icon_16x16@2x.png
├── icon_32x32.png      icon_32x32@2x.png
├── icon_128x128.png    icon_128x128@2x.png
├── icon_256x256.png    icon_256x256@2x.png
├── icon_512x512.png    icon_512x512@2x.png
└── Contents.json
```

### 两个渲染陷阱（脚本注释里也写了）

1. **渐变未铺满画布**：`drawLinearGradient` 默认只填充起点到终点之间的区域，起点之外的左上角会留下透明缺口。必须传 `[.drawsBeforeStartLocation, .drawsAfterEndLocation]`。
2. **圆环不要用描边**：`replacePathWithStrokedPath` 在本环境下会把圆环上下压平。改用「外圆 + 内圆 + 偶奇裁剪」的实心环。

### 接线

原工程把 `CE_APPICON_NAME` 指向 `AppIconDev` / `AppIconBeta` 等名称，但工程里并没有对应的图标集，所以**之前构建出的 app 根本没有图标**。本轮：

- 新建 `AppIcon.appiconset`；
- 五套配置（Debug / Release / Alpha / Beta / Pre）统一指向 `AppIcon`。

代价是失去「开发版 / 测试版」图标角标区分——那些图标本来就不存在，所以没有实际损失。若将来需要区分，复制图标集改名即可。

### 验证

用 `actool` 单独编译资产目录，确认图标能被正确识别并生成 `icns`：

```bash
xcrun actool CodeEdit/Assets.xcassets --compile /tmp/actool-out \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist /tmp/actool-out/partial.plist
```

预期输出 `AppIcon.icns`、`Assets.car`，且 partial plist 中包含：

```
CFBundleIconFile = AppIcon
CFBundleIconName = AppIcon
```

构建 App 后即可在 Dock 与 Finder 中看到新图标。

---

## 3. 分支合并

### 原状态

工程里**没有**任何合并能力。`GitClient` 只有 Clone / Branch / Commit / Status / Fetch / Pull / Push / Remote / Stash / Validate 十个扩展，没有 Merge；`SourceControlManager` 也没有对应方法。唯一沾边的是：

- `pull` 支持 `--rebase` / `--no-rebase`——那是**拉取**时的变基选择，不是合并分支；
- `GitStatus` 有 `unmerged` 值、`git status` 解析器也会解析 `u` 记录，但没有解决/中止冲突的流程，且这些文件**不会**进入改动列表（原代码里是 `// TODO: Unmerged changes`）。

### 现在的能力

两个入口，同一套逻辑：

| 入口 | 位置 | 形式 |
| --- | --- | --- |
| 分支右键 | 「仓库」分页 → 任意分支 → 右键 | 「合并到当前分支…」 |
| 快捷条 | 「更改」页签下方的操作条 | 合并图标，点开列出可合并的本地分支 |

行为：

- 执行 `git merge <branch>`，允许快进（ff）；
- 成功后刷新改动列表、未同步提交数、当前分支；
- **冲突时**：先刷新一次（让冲突文件出现在改动列表里），再弹出对话框，列出最多 8 个冲突文件，提供两个选项：
  - **中止合并** → `git merge --abort`，恢复到合并前；
  - **稍后处理** → 保留冲突现场，用户手动解决后在面板里暂存并提交。

### 为什么用 `diff --diff-filter=U` 判断冲突

`git status` 的冲突组合有 7 种：`DD` `AU` `UD` `UA` `DU` `AA` `UU`。现有解析器把 `X` 映射成 `GitStatus`，其中只有部分字符是 `U`（例如 `UA` 会解析成 `added`），因此靠 `anyStatus() == .unmerged` 会漏掉一部分冲突。改用 `git diff --name-only --diff-filter=U` 才能完整覆盖。

### 未做的部分

- 没有 `--no-ff` / `--squash` / `--ff-only` 选项；
- 没有 `merge --continue`（解决冲突后走正常的「暂存 + 提交」流程，等价于 `git commit` 完成合并）；
- 没有三路合并的可视化冲突编辑器——冲突文本由用户直接在编辑器里改。

### 涉及文件

| 文件 | 改动 |
| --- | --- |
| `SourceControl/Client/GitClient+Merge.swift`（新增） | `merge` / `merge --abort` / `conflictedFiles` / `isMerging` |
| `SourceControl/SourceControlManager+GitClient.swift` | `merge(branch:)`、`abortMerge()`、`handleMergeFailure(_:)`；改动列表纳入未合并文件 |
| `.../Repository/Views/SourceControlNavigatorRepositoryView+contextMenu.swift` | 分支右键「合并到当前分支…」 |
| `.../Views/SourceControlQuickActionsView.swift` | 快捷条合并菜单 |

---

## 4. 多仓库修复与差异视图 / LSP 代码导航

### 多仓库 Git 修复

| 问题 | 根因 | 修复 |
| --- | --- | --- |
| 显示分支但提示「无远程」 | `WorkspaceView` 只对主仓库调 `refreshRemotes`，次要仓库从不刷新 | `SourceControlWorkspace.sync` 与更改视图/聚合视图的 `.task` 中逐仓库刷新 remotes 与 stash |
| 同名文件无法区分（看似重复） | 列表只显示 `lastPathComponent`，中间截断 | `GitChangedFileLabel` 显示 `相对仓库根的目录/文件名` |
| 点击改动文件无反应 | ① 嵌套根目录时 `getFile` 用 `first(where:)` 匹配到外层根；② 查不到时静默 return；③ `Editor.openFile` 失败只写日志 | 根匹配改为「最长前缀」；`openGitFile` 兜底用 URL 直接构造；失败发通知横幅 |

### 差异视图

- `GitClient+Diff.swift`：`diff HEAD --unified=3 -- <file>` 解析为行数组；未跟踪文件合成「整文件新增」。
- `GitDiffView.swift`：独立窗口，统一布局（旧行号｜新行号｜内容），右键菜单「查看差异」入口（单仓库与聚合列表都有）。

### LSP 代码导航（Navigate 菜单新增五项）

| 菜单 | 快捷键 | 实现 |
| --- | --- | --- |
| 悬停信息 | ⌥⌘H | `requestHover` → 通知横幅展示（v1） |
| 跳转到定义 | ⌥⌘D | `requestGoToDefinition` → 打开目标文件 |
| 查找引用 | ⌥⌘R | `requestFindReferences` → 独立结果窗口，按文件分组 |
| 重命名符号 | ⌃⌘R | `prepareRename` 校验 + 确认框 → `requestRename` → `WorkspaceEdit` 应用（打开的文档改内存，未打开的写磁盘） |
| 格式化文档 | ⌥⌘F | `requestFormatting` → 应用 `TextEdit` 到当前文档 |

- 前置条件：语言服务器需在 设置 → 开发者 中配置二进制路径（`lspBinaries`），未配置时提示而不是静默失败。
- 新文件：`LSP/Service/LSPCodeActions.swift`、`LSP/Views/LSPReferencesView.swift`、`SourceControl/Client/GitClient+Diff.swift`、`SourceControl/Views/GitDiffView.swift`。

### 未做

- 代码折叠：需要动 `CodeEditTextView` 内核（无折叠模型），单独立项。
- 主题：现有 `.cetheme` 导入导出已可用；如需导入 VS Code 主题需另做转换器。
- 悬停浮层定位到光标处（当前用通知横幅代替）。
- 格式化选项（tabSize / 保存时格式化）未接设置页。
