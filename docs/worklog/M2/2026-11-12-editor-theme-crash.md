# 定位并修复 dev 包缺少主题导致编辑器崩溃

- 日期：2026-11-12（Asia/Shanghai）
- 类型：fix / config
- 里程碑：M2
- 请求：查看 App 崩溃日志，确定为什么崩溃。

## What（改了什么）

- 读取最近的 macOS `.ips` 与统一日志，核对捕获时间、进程路径、PID、异常和二进制 UUID，不把旧 CPU 资源报告当成这次崩溃。
- `CodeFileView.currentTheme` 不再用 `themes.first!`；为空时使用不依赖文件、适配 light/dark 的内存安全主题。
- 主题库分别加载用户与内置目录，缺失某目录或单文件损坏不阻断其他可用主题。使用临时数组，不在读取前清空已有主题。
- 主题初始化失败不写 nil / Broken 到保存的选择；运行时读取兜底也不修改用户设置。
- dev 打包明确拷贝仓库根目录 `DefaultThemes` 并保留目录结构。签名前逐个核对实际包内 18 个主题文件的内容摘要和浅/深配色；缺少资源即失败，防止“代码编译通过但资源漏打包”再次交付。
- 增加主题加载与 fallback 的 Swift Testing 回归；完整 App 模块测试现在包含 Wiki 与主题，仍不等于全仓 XCTest。

## Why（为什么改）

这是前一版 dev 打包脚本的遗漏，不是用户知识库损坏，也不是 800 请求额度或模型服务使 App 崩溃。

1. 最近的 QiyideDev 报告生成于 **2026-11-12 14:00:24 +0800**，捕获于 14:00:10；统一日志的致命错误为 **14:00:09.920**。
2. PID 91312，13:44:43 从 `/Applications/QiyideDev.app` 启动，版本 0.3.7 (48)。安装可执行文件 UUID `608224EA-4F5E-3CEA-8A14-E4901E8F9C2B` 与崩溃报告吻合。
3. 主线程调用栈为 `_assertionFailure` → `CodeFileView.currentTheme.getter` → `CodeFileView.body`。异常是 `EXC_BREAKPOINT / SIGTRAP`。
4. 日志精确报告 `CodeEdit/CodeFileView.swift:155: Fatal error: Unexpectedly found nil while unwrapping an Optional value`。
5. 安装包没有 `Contents/Resources/DefaultThemes`，用户 `Qiyide/Themes` 目录为空。原主题加载器在枚举缺失内置目录时出错，主题数组和选择为空；代码文件布局时强制取第一项，于是主动 trap。
6. Xcode 工程原本将根目录 DefaultThemes 作为单独资源文件夹，但 SwiftPM 打包脚本只扫 CodeEdit/ 下的普通资源，漏掉了这一文件夹。

“已通过 161 项相关测试 / App 能启动”不能证明“首次打开代码文件不会因资源缺失崩溃”。此前验证没有覆盖这条路径。本次加入真实包资源检查与空数组 fallback 回归。

## Impact（影响范围）

- 影响代码编辑器初次打开、主题加载/刷新、主题选择的持久化及 dev 打包。
- 用户主题优先于同 id 内置主题；已有用户颜色覆盖仍只应用到内存。
- 正常包使用完整内置主题，fallback 只在主题不可用时保证编辑器可用，并输出可识别的 Themes 日志，不把异常静默假装成功。
- 本次不删除、重置或迁移用户设置、主题、Keychain、项目知识库及缓存。
- 不修改同级编辑器组件包，不调用真实模型，不向外部发送崩溃报告。
- 修复开发包包含本工作区已有的建档续跑修复，但不自动替换安装 App；原安装版仍有此缺陷，需明确安装动作后才生效。

## 验证

- 原安装包的资源检查明确失败：`Missing bundled DefaultThemes`；macOS 实际崩溃与相同源码行证实问题。
- 空选择+空主题数组、浅/深 fallback、损坏主题、缺失某一目录、用户覆盖不丢失、只读错误路径及仓库全部主题解码：见最终测试日志与交付清单。
- 完整 App 模块 171 项相关 Swift Testing 回归通过，14 个套件；其中新增 10 项主题用例。
- 实际开发包 18 个 `.cetheme` 与源码逐项哈希一致，并包含浅/深主题；全部仓库主题经 Swift 类型解码验证。
- 开发包 `codesign --verify --deep --strict` 通过；仍是本地 ad-hoc 签名，不代表正式公证。
- 用户 `Qiyide/settings.json` 与安装 App 可执行文件摘要均未改变；本轮未关闭或替换安装版。
- 修复 ZIP：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-editor-theme-fix.zip`；包含同工作区的建档续跑修复。
- ZIP SHA-256：`1657c840f03e944e5b9de4c49e8a158137067ecb1968470409a9b493793cfb6b`。
- 完整日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-spm/test.log`。
- 交付清单：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-editor-theme-fix.manifest.json`。
- 只验证了本地资源与空主题安全路径；本轮未自动启动真实项目进行 UI 操作。
- 本次没有在实际用户项目中重演崩溃，也未启动真实模型。

## 涉及文件

- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Editor/Views/CodeFileView.swift` — 去掉当前主题的强制解包。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Settings/Pages/ThemeSettings/Models/Theme+Fallback.swift` — 内存 light/dark 安全主题。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Settings/Pages/ThemeSettings/Models/ThemeResourceLoader.swift` — 目录与单文件错误隔离。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Settings/Pages/ThemeSettings/Models/ThemeModel.swift` — 可用主题解析、异常日志、不写入 nil。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEdit/Features/Settings/Pages/ThemeSettings/Models/ThemeModel+CRUD.swift` — 临时加载快照与一次选择更新。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/CodeEditTests/Features/Theme/ThemeLoadingTests.swift` — 主题资源和空状态回归。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/package-dev-spm.sh` — 复制 DefaultThemes、主题回归接入、打包前核对。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/scripts/verify/verify-dev-themes.py` — 实际资源包完整性检查。

## 原始证据

- 崩溃报告：`/Users/ext.liangzhenqi1/Library/Logs/DiagnosticReports/QiyideDev-2026-11-12-140024.ips`。
- 精确致命日志：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-editor-theme-crash-2026-11-12/fatal-log.txt`。
- 摘要：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-editor-theme-crash-2026-11-12/crash-summary.json`。
