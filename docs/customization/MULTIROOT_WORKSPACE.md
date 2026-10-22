# 多根工作区使用说明

日期：2026-10-22
能力：把多个项目目录放进**同一个窗口**的项目导航器中管理与切换（对标 VS Code 的 multi-root workspace）。

---

## 1. 如何开启

不需要任何开关或配置文件，功能已内置。步骤：

1. `Cmd+O` 打开第一个项目（这会创建窗口，它就是工作区的主根）；
2. 菜单栏 **文件 → 将文件夹添加到工作区…**（`Add Folder to Workspace...`）；
3. 在文件选择器中选中第二个（或多个）项目目录，点「添加」；
4. 项目导航器顶部会出现多个根节点，可分别展开、切换、拖拽、新建文件。

移除某个附加项目：在导航器中**右键该根节点 → 从工作区移除文件夹**。该操作只把目录移出工作区，不会删除磁盘上的任何文件。主根不提供该入口。

---

## 2. 行为说明

| 能力 | 状态 |
| --- | --- |
| 导航器显示多个根、分别展开/折叠 | ✅ |
| 根节点的重命名、新建、拖拽等操作被禁止 | ✅（避免误删整个项目） |
| 搜索（Find in Workspace）跨全部根 | ✅ |
| 快速打开（Open Quickly）跨全部根 | ✅ |
| 「拷贝相对路径」在多根下输出 `<根目录名>/相对路径` | ✅ |
| 重启后自动恢复附加根目录 | ✅（持久化到 `.qiyide/settings.json`） |
| Git 面板 | ⚠️ 仍以主根仓库为准，附加根的 Git 状态不显示 |
| LSP（补全/诊断） | ⚠️ 仍以主根作为 workspace 路径 |
| 每个根独立的设置 | ⚠️ 未实现（当前仍是工作区级设置） |

---

## 3. 持久化

附加根目录写在主根下的工作区配置文件里：

```json
// <主根>/.qiyide/settings.json
{
  "project" : {
    "projectName" : "",
    "additionalRoots" : [
      "/Users/you/project/another-project"
    ]
  }
}
```

- 主根不写入该数组，永远是打开窗口时选择的那个目录。
- 启动时会过滤掉已不存在的路径，因此删掉磁盘目录不会导致打开失败。
- 想彻底重置：关闭窗口，删除该文件中的 `additionalRoots` 字段即可。

---

## 4. 实现要点（便于后续维护）

| 文件 | 改动 |
| --- | --- |
| `CEWorkspace/Models/CEWorkspaceFileManager.swift` | 新增 `rootUrls` / `rootItems`；多根初始化器；每个根一条 `DirectoryEventStream`；`getFile` 跨根解析；`addRoot` / `removeRoot` |
| `NavigatorArea/ProjectNavigator/OutlineView/ProjectNavigatorViewController.swift` | `content` 由「单个主根」改为返回全部根节点；新增 `expandRootItems()` |
| `.../ProjectNavigatorOutlineView.swift` | 根集合变化时整树刷新（顶层节点不能用 `reloadItem` 增量刷新） |
| `.../ProjectNavigatorMenu.swift` | 菜单项本地化；根节点禁用「移到废纸篓/立即删除」；附加根显示「从工作区移除文件夹」 |
| `.../ProjectNavigatorMenuActions.swift` | 新增 `removeRootFromWorkspace()`；相对路径在多根下的输出规则 |
| `CEWorkspaceSettings/Models/CEWorkspaceSettingsData+ProjectSettings.swift` | 新增持久化字段 `additionalRoots` |
| `Documents/WorkspaceDocument/WorkspaceDocument.swift` | 先读设置再建文件管理器；新增 `addRootFolders(_:)` / `removeRootFolder(_:)` |
| `Documents/WorkspaceDocument/WorkspaceDocument+Index.swift` | 搜索索引遍历全部根目录 |
| `OpenQuickly/ViewModels/OpenQuicklyViewModel.swift` | 支持多根枚举 |
| `WindowCommands/FileCommands.swift` | 新增「将文件夹添加到工作区…」菜单与文件选择器 |
| `Editor/TabBar/Views/EditorTabBarContextMenu.swift` | 标签栏「拷贝相对路径」多根规则 |
| `SourceControl/SourceControlWorkspace.swift`（新增） | 每个根一个 `SourceControlManager`；仓库选择与聚合统计 |
| `.../SourceControlNavigator/Views/SourceControlRepositoryPicker.swift`（新增） | 面板顶部仓库切换器与改动总数角标 |
| `.../SourceControlNavigator/Views/SourceControlNavigatorAllChangesView.swift`（新增） | 「全部仓库」聚合改动列表 |
| `CEWorkspace/Models/CEWorkspaceFileManager+DirectoryEvents.swift` | Git 事件按根目录路由到所属仓库 |
| `SourceControl/SourceControlManager+GitClient.swift` | 状态回写限定在本仓库范围内 |
| `CodeEditUI/Views/ToolbarBranchPicker.swift` | 跟随当前选中仓库显示名称与分支 |

---

## 5. 多仓库 Git 的展示方式

多根工作区里，每个根目录可能是**各自独立的 Git 仓库**（也可能有的不是仓库）。源代码管理面板分两层展示：

### 5.1 面板顶部的仓库切换器

根目录数量大于 1 时，源代码管理面板顶部会出现一行切换器：

```
⎇  CodeEdit ▾                                     ⑤
```

- 左侧是当前仓库名，点击展开菜单，列出全部根目录；
- 菜单项形如 `CodeEdit · main (5)` / `docs · dev (2)`，即「目录名 · 当前分支（改动数）」；
- 非 Git 仓库标记为「非 Git 仓库」；
- 右侧数字是**整个工作区**的改动文件总数，跨仓库汇总。

菜单中的「全部仓库」选项对应聚合视图。

### 5.2 两种视图

| 视图 | 内容 | 适用 |
| --- | --- | --- |
| **全部仓库**（默认，添加第二个根后自动进入） | 按仓库分区的改动文件列表，每个仓库一段，标题为该仓库名、分支与改动数 | 一眼看到「哪个项目有未提交改动」 |
| **单个仓库** | 原有的「更改 / 历史记录 / 仓库」三个分页，含提交框、暂存勾选、分支管理 | 实际提交、切换分支、推送 |

在聚合视图里**点击任意仓库标题**即切换到该仓库的完整视图。

聚合视图有意不提供提交框：一次提交只能属于一个仓库，把提交框放在跨仓库列表上会产生「提交到哪里」的歧义。这与 VS Code 的行为一致——提交按仓库进行，只是它把每个仓库的提交框都展开显示。

### 5.3 各处界面跟随当前仓库

选定某个仓库后，以下位置都会指向该仓库：

- 导航器底部的「放弃全部改动 / 储藏」菜单；
- 窗口工具栏的分支选择器（显示当前仓库名与分支，可直接切换分支）；
- 推送 / 拉取 / 分支切换等所有弹窗；
- 历史检查器。

### 5.4 状态标记与「只显示改动」

项目导航器里的 Git 状态字母与「只显示有改动的文件」过滤，覆盖**所有仓库**的文件：每个仓库只写入/清理自己范围内的状态，互不覆盖。

---

## 6. 已知限制与后续

1. **不扫描嵌套仓库**。只在根目录这一层判断是否为仓库；根目录内部再嵌套的 Git 仓库不会被单独列为一项（VS Code 会按 `git.repositoryScanMaxDepth` 扫描）。若需要，可在 `SourceControlWorkspace.sync` 中增加深度为 1 的子目录探测。
2. **LSP 仍以主根为 workspace 路径**。`workspaceFolders` 尚未传多根，跨根跳转与补全会受限。
3. **设置尚未分层**。当前 `.qiyide/settings.json` 属于整个工作区，无法为单个根指定不同配置。
4. **移除根后的清理**：会回收该根下的文件树缓存、事件流与仓库对象，但已打开的编辑器标签不会自动关闭。
5. **启动成本**：每个根在打开工作区时会各执行一次 `git status`，仓库数量很多时会增加启动时间，但只在后台进行，不阻塞界面。

