# 改名记录：CodeEdit → Qiyide

日期：2026-10-22
目标：让 Qiyide 与原版 CodeEdit **在同一台 Mac 上并存安装、互不干扰**。

---

## 1. 标识对照表

| 项目 | 改前 | 改后 | 说明 |
| --- | --- | --- | --- |
| 产品名（产物） | `CodeEdit.app` | `Qiyide.app` | `PRODUCT_NAME = Qiyide`（保持 target 名不变） |
| Bundle ID（主） | `app.codeedit.CodeEdit` | `app.qiyide.Qiyide` | **并存的关键**：不同 Bundle ID 才会被 LaunchServices 视为两个应用 |
| Bundle ID（测试） | `app.codeedit.CodeEditTests` | `app.qiyide.QiyideTests` | UI 测试同理 |
| Bundle ID（扩展） | `app.codeedit.CodeEdit.OpenWithCodeEdit` | `app.qiyide.Qiyide.OpenWithCodeEdit` | Finder 扩展独立注册 |
| 显示名 | `CodeEdit` | `Qiyide` | `CFBundleDisplayName` |
| App Group | `app.codeedit.CodeEdit.shared` | `app.qiyide.Qiyide.shared` | 否则两者共享同一组容器，扩展设置会互相覆盖 |
| URL Scheme | `codeedit://` | `qiyide://` | 避免 LaunchServices 争抢同一 scheme |
| 应用支持目录 | `Application Support/CodeEdit` | `Application Support/Qiyide` | 沙盒内路径，实际隔离已由 Bundle ID 保证 |
| 项目配置目录 | `<项目>/.codeedit/` | `<项目>/.qiyide/` | 避免两个 IDE 读写同一份项目配置 |
| 更新源 | CodeEdit 官方 appcast | **已停用** | 见第 4 节，这是并存场景下的必要处理 |

保留不变：target 名（`CodeEdit`、`CodeEditTests`、`CodeEditUITests`、`OpenWithCodeEdit`）、工程文件名 `CodeEdit.xcodeproj`、scheme 名、Swift 类型名、GitHub 仓库地址（`CodeEditApp/CodeEdit`，属于上游来源而非产品名）。

**为什么保留 target 名**：改名 target 会连带 scheme、测试宿主、CI 脚本、`BUILT_PRODUCTS_DIR` 路径全链路调整，收益仅是内部命名一致，对「并存」没有帮助。因此只改产物名（`PRODUCT_NAME`），target 名保持原样。

---

## 2. 并存需要满足的三个隔离条件

| 隔离维度 | 依赖什么 | 是否已处理 |
| --- | --- | --- |
| 安装位置与安装包识别 | Bundle Identifier | ✅ 已改为 `app.qiyide.Qiyide` |
| 设置、窗口状态、主题、索引 | 沙盒容器（由 Bundle ID 派生） | ✅ 自动隔离 |
| Finder 扩展共享数据 | App Group | ✅ 已改为 `app.qiyide.Qiyide.shared` |
| 「用…打开」菜单项 | 扩展的 `CFBundleDisplayName` | ✅ 已改为 `Qiyide` |
| 文档默认打开方式 | `CFBundleDocumentTypes`（两者都会注册） | ⚠️ 由用户在「打开方式」中自行选择，属预期行为 |

---

## 3. 改动清单

**工程与配置**

| 文件 | 改动 |
| --- | --- |
| `CodeEdit.xcodeproj/project.pbxproj` | 20 处 Bundle ID；5 个构建配置的 `PRODUCT_NAME = Qiyide`；4 处 `TEST_HOST` 指向 `Qiyide.app/Contents/MacOS/Qiyide` |
| `CodeEdit.xcodeproj/xcshareddata/xcschemes/*.xcscheme` | 6 处 `BuildableName = "Qiyide.app"`（`BlueprintName` 保持 `CodeEdit`） |
| `CodeEdit/Info.plist` | 新增 `CFBundleDisplayName`；URL Scheme 改 `qiyide`；移除 `SUFeedURL`、`SUPublicEDKey` |
| `OpenWithCodeEdit/Info.plist` | 扩展显示名改 `Qiyide` |
| `CodeEdit/CodeEdit.entitlements`、`OpenWithCodeEdit/OpenWithCodeEdit.entitlements` | App Group 改名 |
| `Configs/*.xcconfig`（5 个） | 版权声明改为 `Copyright © 2026 Qiyide (based on CodeEdit, MIT)` |

**代码**

| 文件 | 改动 |
| --- | --- |
| `AppDelegate.swift`、`GeneralSettingsView.swift` | App Group suite 名 |
| `SoftwareUpdater.swift` | 更新通道改为可配置常量，默认未配置即关闭；`checkForUpdates` 增加可用性守卫 |
| `GeneralSettingsView.swift` | 更新相关控件在未配置时禁用，并显示原因 |
| 18 处界面文案 | “About CodeEdit”→“About Qiyide”、“Welcome to CodeEdit”、“Allow CodeEdit to install…” 等 |
| 6 个存储路径文件 | `Application Support/CodeEdit` → `Qiyide`；`.codeedit` → `.qiyide` |
| `Localization/zh-Hans.lproj/Localizable.strings` | 11 条含产品名的译文同步；新增更新禁用提示 |

**其他**

| 文件 | 改动 |
| --- | --- |
| `.github/workflows/pre-release.yml` | 产物路径与 codesign 前缀同步（发布/上传环节仍指向上游，见第 5 节） |
| `AppCast/_config.yml` | 站点标题 |
| `scripts/memory/baseline.sh` | 用法文案 |

---

## 4. 必须理解的取舍：自动更新被关闭

原实现从 `CodeEditApp/CodeEdit` 的 GitHub Releases 拉取 appcast，并用上游 EdDSA 公钥校验。若保留：

- Sparkle 会把 Qiyide 判定为「旧版本 CodeEdit」，下载并安装官方包 → **定制版被覆盖回原版**；
- 同时与「并存」目标直接冲突（会替换掉原版安装）。

因此当前 `SoftwareUpdater.UpdateChannel` 为空，更新器不启动，设置页的「检查更新」「自动检查」「包含预发布」均置灰并提示原因。

启用自有更新通道的步骤：

1. 生成自有 EdDSA 密钥对，把公钥写入 `Info.plist` 的 `SUPublicEDKey`；
2. 在 `SoftwareUpdater.UpdateChannel` 填入自有 `appcastURL`；
3. `UpdateChannel.isConfigured` 自动变真，界面控件随之启用。

---

## 5. 首次运行与迁移

- **首次启动是全新状态**：设置、主题、窗口布局、最近项目、工作区列表都从默认值开始（沙盒容器变了，属预期）。
- **想继承原 CodeEdit 的配置**（可选，一次性）：

```bash
# 原数据在旧容器，新数据在新容器；仅在两个应用都退出后执行
OLD="$HOME/Library/Containers/app.codeedit.CodeEdit/Data/Library/Application Support/CodeEdit"
NEW="$HOME/Library/Containers/app.qiyide.Qiyide/Data/Library/Application Support/Qiyide"
ls "$OLD" && mkdir -p "$NEW" && cp -R "$OLD"/. "$NEW"/
```

- **项目级配置**：旧项目的 `.codeedit/settings.json` 不会被 Qiyide 读取；如需沿用，把该目录复制为 `.qiyide`。

---

## 6. 签名前置条件（重要）

App Group `app.qiyide.Qiyide.shared` 必须在你所用开发者账号的 App ID 中先行创建并勾选，否则带 entitlements 的签名会失败。本地调试可用 `CODE_SIGNING_ALLOWED=NO`（此时 App Group 不生效，「Open With Qiyide」扩展行为可能受限）。

---

## 7. 验证清单

```bash
# 1. 产物名与 Bundle ID
xcodebuild -project CodeEdit.xcodeproj -scheme CodeEdit -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
ls build/Debug/Qiyide.app/Contents/MacOS/Qiyide
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" build/Debug/Qiyide.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" build/Debug/Qiyide.app/Contents/Info.plist

# 2. 中文资源是否入包
ls build/Debug/Qiyide.app/Contents/Resources/zh-Hans.lproj/

# 3. 与原版并存
ls /Applications | grep -E "CodeEdit|Qiyide"     # 应同时存在两个 .app
```

界面检查：
- 菜单栏「Qiyide」→「关于 Qiyide」；关于窗口副标题显示 `Qiyide: 版本号`。
- 设置 → 通用：「检查更新」为禁用态，并显示未配置更新源的说明。
- Finder 右键「打开方式」出现 `Qiyide`（首次可能需在「打开方式 → 其他」中确认一次）。

---

## 8. 未处理项（明确记录）

1. **上游 CI 发布链路**：`pre-release.yml` 的路径与签名前缀已同步，但 DMG 制作、appcast 发布、Notarization 仍指向 CodeEdit 官方基础设施，不能直接用于 Qiyide 发布。
2. **`WelcomeWindow` / `AboutWindow` / `CodeEditSymbols`**：三个外部包内含文案与品牌元素（欢迎页标题、关于页图标），不在本地仓库，未改名。
3. **反馈提交目标**：`FeedbackModel` 仍指向 `CodeEditApp/CodeEdit` 仓库，按现状提交会把 Qiyide 的问题发到上游。需要自有反馈渠道时再另行配置。
4. **命令行工具**：设置中的「安装 `qiyide` 命令」按钮本就是 `.disabled(true)` 且资源脚本不存在，属上游未完成功能，未实现。
