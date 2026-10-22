# 执行报告：M0 基线 + M1 首批改造

日期：2026-10-22
代码基线：CodeEdit `fa2aebd8`，CodeEditTextView `d7ac3f1`，CodeEditSourceEditor `1fa4d3c`，CodeEditLanguages `32a1ddc`

---

## 0. 环境约束（必须先读）

本机环境**无法执行 `xcodebuild`**，原因有两条，均与代码无关：

1. **嵌套沙箱受限**：`xcodebuild` 解析 SwiftPM 清单时会调用 `sandbox-exec` 加载限制性 profile，本会话所在的沙箱不允许再次 `sandbox_apply`，报错：
   `xcodebuild: error: Could not resolve package dependencies: sandbox-exec: sandbox_apply: Operation not permitted`。
   验证方式：`sandbox-exec -p '(deny file-write*)' /bin/echo ok` 同样失败，而 `(allow default)` 成功，说明是限制性嵌套沙箱被拒。
2. **网络需代理**：直连 github.com 超时，需 `https_proxy=http://127.0.0.1:7890` 才能克隆依赖。

因此本轮采取的验证策略是：

| 改动层级 | 验证方式 | 结果 |
| --- | --- | --- |
| 包内代码（SourceEditor / TextView） | `swift build`（SwiftPM 命令行，绕过 Xcode） | ✅ 通过 |
| 工作区数据层（纯 Foundation） | 临时 SwiftPM 工程 + 行为断言 | ✅ 全部通过 |
| 应用层（App target） | **无法编译**，仅静态审查 | ⚠️ 待你在本地 Xcode 验证 |

---

## 1. 已完成并验证的改动

### 1.1 依赖接线（M0-1）

**问题**：三个包原本以远程版本锁定，本地源码改动不参与编译。

| 文件 | 改动 |
| --- | --- |
| `CodeEdit.xcodeproj/project.pbxproj` | 两处 `XCRemoteSwiftPackageReference "CodeEditSourceEditor"` → `XCLocalSwiftPackageReference ../CodeEditSourceEditor`（含 `packageReferences` 与 `productRef` 注释同步） |
| `CodeEditSourceEditor/Package.swift` | `CodeEditTextView`、`CodeEditLanguages` 由远程版本依赖改为 `.package(path:)` 本地依赖 |

**待你验证**：在 Xcode 打开工程，确认 Packages 解析成功、`CodeEdit` scheme 可编译。若报路径错误，`relativePath` 需要相对 `.xcodeproj` 所在目录调整为 `../CodeEditSourceEditor`。

> 注意：`CodeEditTextView` 与 `CodeEditLanguages` 是经 `CodeEditSourceEditor` 间接引入的，主工程并不直接声明它们。因此只改主工程 pbxproj 不足以让这两个包的本地改动生效，必须同时改 SourceEditor 的清单——这是本轮实际踩到的点。

### 1.2 迷你地图按需创建（内存热点 #1）

**问题**：`TextViewController.loadView()` 无条件创建 `MinimapView`，而迷你地图会新建**第二个** `TextLayoutManager`（独立红黑树行索引 + 独立行片段视图 + 独立 `TextSelectionManager`）。`showMinimap = false` 只是 `isHidden`，内存照常占用。

**改动**：

| 文件 | 改动 |
| --- | --- |
| `TextViewController.swift` | `minimapView: MinimapView!` → `private(set) var minimapView: MinimapView?`；新增 `setMinimapVisible(_:)` 与 `activateMinimapConstraints(for:)` |
| `TextViewController+Lifecycle.swift` | 不再无条件创建；改为 `setMinimapVisible(configuration.peripherals.showMinimap)`；迷你地图约束从 `setUpConstraints()` 移入创建流程；`minimapView.layout()` 改为可选链 |
| `TextViewController+StyleViews.swift` | 内边距计算改为可选链；`updateTextInsets` 不再依赖迷你地图存在 |
| `TextViewController+ReloadUI.swift` | 两处调用改为可选链 |
| `SourceEditorConfiguration+Peripherals.swift` | 开关迷你地图时调用 `setMinimapVisible(_:)`，隐藏即销毁实例 |
| `SourceEditorConfiguration+Appearance.swift` | `wrapLines`、`theme` 同步改为可选链 |
| `Highlighter.swift` | 新增 `updateMinimapView(_:)`，创建/销毁时同步可见范围来源 |
| `VisibleRangeProvider.swift` | `minimapView` 由 `private weak` 改为模块内可见的 `weak`，供同步使用 |

**行为变化**：默认仍显示迷你地图（默认值未改）；用户在设置中关闭后，内存才真正释放。重新开启时会重建并恢复布局与高亮范围。

**验证**：`swift build` 通过（首次 5m46s 含依赖下载，增量 6s）。

### 1.3 LSP 关窗回收加固（内存热点 #3，修正初版判断）

**修正**：初版方案称「LSP 仅在应用退出时停止」不准确——`CodeEditDocumentController.removeDocument` 已调用 `lspService.closeWorkspace(path)`。真实缺陷是：

1. 路径**精确字符串匹配**：工作区 URL 带尾部斜杠（`WorkspaceDocument.initWorkspaceState` 会主动补 `/`），而语言服务器注册时的键不一定带 → `filter` 匹配不到，服务器泄漏。
2. 关闭后未调用 `stopListeningToEvents(for:)`，事件监听 `Task` 继续持有客户端。

**改动**（`CodeEdit/Features/LSP/Service/LSPService.swift`）：路径归一化比较 + 关闭后取消监听任务 + 新增 `normalizeWorkspacePath(_:)`。

**状态**：⚠️ 应用层代码，未能编译验证。

### 1.4 中文界面（464 条键，100% 覆盖）

**做法**：采用「英文源字符串即键」策略，因此**不需要改动任何 Swift 调用点**即可让 `Text("General")` 这类 SwiftUI 文案立即命中中文——这是本轮最省风险的做法。

| 文件 | 说明 |
| --- | --- |
| `CodeEdit/Localization/zh-Hans.lproj/Localizable.strings`（新增） | 464 条键全部译为简体中文，按模块分组并加注释 |
| `CodeEdit.xcodeproj/project.pbxproj` | `knownRegions` 增加 `zh-Hans` |
| `CodeEdit/Info.plist` | 新增 `CFBundleLocalizations = [en, zh-Hans]` |
| `CodeEditSourceEditor/Package.swift`、`CodeEditTextView/Package.swift` | 新增 `defaultLocalization: "en"`（SPM 本地化前置条件） |

**覆盖率核验**（脚本统计源码字面量 vs. 译文文件）：

```
覆盖率 464/464; 缺失 []
plutil -lint ... OK
```

**未覆盖的部分（诚实说明）**：
- 带字符串插值的文案（如 `Text("Open \(name)")`）不在本轮 464 条内，需单独处理占位符。
- `NSAlert` / `NSMenuItem` 等 AppKit 文本共 40 余处，仍为英文，需改为 `NSLocalizedString`（这属于 M3 后半段）。
- `WelcomeWindow`、`AboutWindow` 两个第三方包内的文案不在本地仓库，未处理。

### 1.5 内存基线工具（M0-4）

| 文件 | 用途 |
| --- | --- |
| `CodeEdit/Utils/Memory/MemoryProbe.swift`（新增） | 采样 `phys_footprint` / RSS / 峰值 / 打开文档数，11s 一次，写 JSONL 到应用支持目录；仅在 `--memory-probe` 或 `CEMemoryProbeEnabled` 下启用 |
| `CodeEdit/Features/StatusBar/Views/StatusBarItems/StatusBarMemoryLabel.swift`（新增） | 状态栏实时读数（仅探针开启时插入视图树） |
| `CodeEdit/Features/StatusBar/Views/StatusBarView.swift` | 插入条件渲染 |
| `CodeEdit/AppDelegate.swift` | `applicationDidFinishLaunching` 中按开关启动探针 |
| `scripts/memory/make-fixture.sh` | 生成 10×1MB Swift 样本工作区 |
| `scripts/memory/baseline.sh` | S1 冷启动基线采集，输出 Markdown 报告（`footprint` + 语言服务器进程数） |

**状态**：⚠️ 应用层代码，未编译验证；脚本已 `bash -n` 通过并试跑生成样本。

### 1.6 多工作区数据层（M2 前半，已通过行为验收）

| 文件 | 内容 |
| --- | --- |
| `CodeEdit/Features/Workspace/Models/JSONValue.swift`（新增） | 与模型解耦的 JSON 值类型 + 深合并（对象递归、数组替换、null 清除、未知键保留） |
| `CodeEdit/Features/Workspace/Models/Workspace.swift`（新增） | `Workspace` / `WorkspaceFolder`，含 `stateKey`（状态隔离键）与默认命名 |
| `CodeEdit/Features/Workspace/WorkspaceStore.swift`（新增） | 持久化 `~/Library/Application Support/CodeEdit/Workspaces/workspaces.json`；CRUD、最近列表、目录去重匹配、原子写入；可注入目录便于测试 |
| `scripts/verify/workspace-core/`（新增） | 脱离 Xcode 的验收工程与断言 |

**验收结果**（`./scripts/verify/workspace-core/run.sh`）：

```
Build complete!
ALL CHECKS PASSED
```

断言覆盖：
- 三层配置合并优先级（用户 → 工作区 → 文件夹）
- 未覆盖字段保留、`null` 清除、数组整体替换、编码解码往返无损
- 工作区创建（自动命名 / 显式命名 / 多根）、最近列表顺序、同目录匹配
- 持久化往返（名称、根目录、设置覆盖、时间、最近列表）
- 更新 / 删除 / 三类错误路径

---

## 2. 尚未完成（需要可编译环境）

| 事项 | 原因 |
| --- | --- |
| `WorkspaceStore` 接入 `WorkspaceDocument`（`workspaceID` 替换 `fileURL` 作为状态键、配置分层注入 `Settings`） | 应用层改动，无法编译验证；且涉及状态迁移，需实机回归 |
| 工作区切换器 UI、菜单项（新建/打开/保存工作区） | 同上 |
| 高亮属性窗口化、tree-sitter 树 LRU | 影响渲染行为，必须有实机性能对比 |
| 插值文案与 AppKit 文本的本地化 | 需 Xcode 生成 String Catalog 并逐条核对 |

---

## 3. 你需要在本地执行的验证

```bash
# 1. 依赖解析（Xcode 内会自动完成，或命令行）
cd /Users/ext.liangzhenqi1/project/mycase/CodeEdit
xcodebuild -resolvePackageDependencies -project CodeEdit.xcodeproj -scheme CodeEdit

# 2. 编译
xcodebuild -project CodeEdit.xcodeproj -scheme CodeEdit -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# 3. 单元测试基线
xcodebuild test -project CodeEdit.xcodeproj -scheme CodeEdit \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

# 4. 内存基线（S1）
./scripts/memory/make-fixture.sh ~/CodeEditMemoryFixture 10 1024
./scripts/memory/baseline.sh "$(xcodebuild -project CodeEdit.xcodeproj -scheme CodeEdit -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')" 60

# 5. 中文界面
#    系统设置 → 语言与地区 → 首选语言加入「简体中文」→ 重启 CodeEdit
```

预期：
- 中文系统下，菜单、设置 13 页、检查器、状态栏、Git 面板显示中文。
- 关闭「显示迷你地图」后反复开关，界面不崩、文本左右内边距正确（验证按需创建/销毁）。

---

## 4. 已知风险

1. **应用层未编译**：1.2/1.3/1.4/1.5 中涉及 App target 的文件（`MemoryProbe`、`StatusBarMemoryLabel`、`AppDelegate`、`LSPService`）可能存在编译错误，属正常风险，需首轮编译暴露。
2. **pbxproj 手改**：已备份至 `.workbuddy/backup/project.pbxproj.20261022.bak`，如 Xcode 打开异常可直接还原。
3. **本地包版本领先**：`CodeEditSourceEditor` 与 `CodeEditLanguages` 的 HEAD 均领先于主工程原锁定版本，首轮编译需确认 API 兼容。
4. **`.strings` 未经过 App 打包验证**：同步文件夹（`PBXFileSystemSynchronizedRootGroup`）会自动收集资源，但仍需实机确认 `zh-Hans.lproj` 被打入 `.app`（可用 `ls CodeEdit.app/Contents/Resources/zh-Hans.lproj` 检查）。
