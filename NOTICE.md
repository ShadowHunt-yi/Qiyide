# NOTICE — 来源、修改与第三方归属

本文件说明本仓库（Qiyide）与上游项目的关系、相对上游的修改，以及第三方组件的归属。
它是 [README](README.md) 中来源声明的补充，不改变 [LICENSE.md](LICENSE.md) 的效力。

## 1. 项目来源

| 项目 | 说明 |
| --- | --- |
| 上游项目 | **CodeEdit** — <https://github.com/CodeEditApp/CodeEdit> |
| 上游版权 | `Copyright (c) 2022 CodeEdit` |
| 上游许可证 | MIT License（全文见 [LICENSE.md](LICENSE.md)，该文件为上游原文，未作修改） |
| 本仓库 | **Qiyide** — <https://github.com/ShadowHunt-yi/CodeEdit>，CodeEdit 的衍生项目 |
| 本仓库许可 | MIT（沿用上游），保留上游版权与许可声明 |
| 关系 | 独立的二次开发，**非** CodeEdit 官方发行版，与上游团队无隶属或背书关系 |

## 2. 相对上游的修改

依据 MIT 许可证，本仓库在保留原始版权声明的前提下对代码进行了修改。主要改动方向：

- **产品化**：改名 Qiyide，独立 Bundle ID / App Group / URL Scheme / 应用支持目录，使与原版并存安装；
  停用上游自动更新源。细节见 [`docs/customization/REBRAND.md`](docs/customization/REBRAND.md)。
- **本地化**：补充简体中文界面与文案。
- **编辑器能力**：行级 git blame 与行历史、Markdown 源码/预览分栏与滚动同步、XML 词法高亮、
  括号配对高亮的越界崩溃修复、差异视图以编辑器标签形式呈现。
- **多仓库工作区**：仓库切换与改动聚合、新建终端时选择目标仓库、LSP 会话按文件所属仓库解析、
  历史面板跟随文件所属仓库。
- **性能与稳定性**：文件树展示缓存与排序键预取、搜索索引排除构建产物、缩略图按可视区域排版、
  折叠与 Git 状态刷新合并、内置性能采样与主线程看门狗。
- **交付**：`scripts/build.sh` / `scripts/package-dmg.sh` 与 GitHub Actions 云打包工作流。

逐条改动可查阅本仓库的 Git 提交历史。

## 3. 本地定制的同源包

以下三个包在本仓库中同时维护，工作流会把它们与主仓库一起检出：

| 包 | 来源 | 说明 |
| --- | --- | --- |
| CodeEditTextView | ShadowHunt-yi/CodeEditTextView（上游 CodeEditApp） | 新增附件按类型批量移除、附件单击回调、行尾装饰排版语义 |
| CodeEditSourceEditor | ShadowHunt-yi/CodeEditSourceEditor（上游 CodeEditApp） | 括号高亮崩溃修复、迷你地图按需创建与分区排版、折叠输入合并、标记语言语义 token |
| CodeEditLanguages | ShadowHunt-yi/CodeEditLanguages（上游 CodeEditApp） | 语言定义，未作功能性修改 |

## 4. 第三方组件

本项目使用以下开源组件，各自遵循其自身许可证（均为宽松许可，通常为 MIT / Apache-2.0）。
完整版本与校验和见 `CodeEdit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。

| 组件 | 用途 |
| --- | --- |
| AboutWindow / WelcomeWindow / CodeEditKit / CodeEditSymbols | CodeEdit 生态的界面与符号组件 |
| LanguageClient / LanguageServerProtocol | LSP 客户端与协议定义 |
| SwiftTerm | 终端模拟 |
| Sparkle | 应用更新（本仓库已停用上游更新源） |
| GRDB.swift | 编辑器状态恢复的本地数据库 |
| SwiftUI-Introspect / LogStream / ZIPFoundation / collectionconcurrencykit | 界面内省、日志流、压缩与集合工具 |
| swift-async-algorithms / swift-collections | 标准库扩展 |
| tree-sitter 语法（经 CodeEditLanguages 引入） | 语法高亮 |
| mermaid（`CodeEdit/Features/Editor/Markdown/Resources/mermaid.min.js`） | Markdown 预览中的图表渲染，MIT |

## 5. 商标与品牌

“CodeEdit” 名称、图标及相关品牌标识归上游项目所有。本仓库仅在描述来源时引用，
不暗示上游对本项目的认可或背书。Qiyide 的图标与名称由本仓库自行使用。

## 6. 问题反馈

- 与上游共有的缺陷 → 上游仓库 Issues：<https://github.com/CodeEditApp/CodeEdit/issues>
- 仅存在于本仓库的问题 → 本项目 Issues：<https://github.com/ShadowHunt-yi/CodeEdit/issues>
