<div align="center">

# Qiyide

**基于 [CodeEdit](https://github.com/CodeEditApp/CodeEdit) 二次开发的 macOS 代码编辑器**

[![Build DMG](https://github.com/ShadowHunt-yi/Qiyide/actions/workflows/build-dmg.yml/badge.svg)](https://github.com/ShadowHunt-yi/Qiyide/actions/workflows/build-dmg.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black.svg)](#)

</div>

> [!IMPORTANT]
> **来源声明**：本项目是 [CodeEdit](https://github.com/CodeEditApp/CodeEdit)（`Copyright (c) 2022 CodeEdit`，MIT）的衍生项目，
> 由独立维护者二次开发，**非**上游官方发行版，与上游团队无隶属或背书关系。
> 修改说明与第三方归属见 [NOTICE.md](NOTICE.md)；许可证全文见 [LICENSE.md](LICENSE.md)。

## 简介

Qiyide 在 CodeEdit 的基础上做产品化与工程化改造：可以与原版 CodeEdit **并存安装**、界面**完整中文化**、
补上日常开发缺失的 Git 与多仓库能力、修复若干崩溃与卡顿，并提供可复现的构建与打包流水线。

以下功能均为**本仓库新增或重做**，上游 CodeEdit 不具备。

## 本仓库独有的功能

### 编辑器

| 功能 | 说明 | 入口 |
| --- | --- | --- |
| 行级 Git blame 标注 | 行尾显示提交哈希 / 作者 / 日期 / 摘要；按分支与文本指纹去重，编辑后合并刷新；标注按类型整体卸载，不会叠加 | 默认开启，⌥⌘B 切换 |
| 单行变更历史 | 查看某一行从引入到现在的全部提交与逐次 diff | ⌥⌘L |
| Markdown 源码 / 预览分栏 | 双栏实时预览、滚动位置双向同步；mermaid 图表离线渲染；渲染在后台线程并 350ms 防抖 | ⌥⌘P（仅 .md 生效） |
| 差异以编辑器标签打开 | 不再弹独立窗口：单击打开临时差异标签、双击固定、可拖到编辑区打开完整文件 | 源代码管理面板 |
| XML 族词法高亮 | 精确区分标签名、属性名、属性值、注释、CDATA、处理指令；只失效受影响行 | 自动（`.xml` / `.plist` 等） |
| 折叠带 | 代码折叠模型接入行号栏折叠带，折叠区间计算合并连续输入 | 行号栏 |
| 括号配对高亮修复 | 修复光标远离可视区域时 `NSRange` 越界导致的必崩问题 | 自动 |

### 多仓库工作区

| 功能 | 说明 |
| --- | --- |
| 仓库切换与聚合 | 顶部仓库切换器；「全部仓库」视图按仓库分组汇总改动，可一键跳转到对应仓库 |
| 新建终端选择仓库 | 多根工作区下工具栏 `+` 变成仓库下拉，选中即在该仓库根目录启动终端 |
| LSP 按仓库解析 | 语言服务器会话以「文件所属根目录」为键，次要根项目不再套用主根配置；关闭窗口时释放所有根的服务器进程 |
| 历史面板跟随文件 | 检查器「历史」显示当前文件所属仓库的提交，而不是当前活动仓库 |
| 逐仓库刷新 | 文件事件按根目录路由，每个仓库独立刷新分支、远程、改动与储藏 |
| 相对路径带根名 | 多根下复制相对路径会带 `<根目录名>/` 前缀，避免跨根歧义 |

### 性能与诊断

| 功能 | 说明 |
| --- | --- |
| 内置性能采样 | 记录启动、git 状态、blame、diff、文件树重载/展开、Markdown 渲染耗时；原始样本保留 1 小时并聚合为小时桶（30 天），文件硬上限 2 MB；另有主线程看门狗记录 >250ms 的停顿 |
| 性能摘要 | 「视图 → 复制性能摘要」输出各类别的次数、平均、p95、最大值，可直接用于定位优化方向 |
| 文件树提速 | 展示子项按数据代缓存、排序键预取（2000+ 项目录实测 478ms → 43ms）、紧凑目录链带环检测 |
| 索引瘦身 | 搜索索引跳过 `target/`、`node_modules` 等构建产物（实测索引量减少约 62.9%），正则预编译 |
| Git 刷新合并 | 文件系统事件 300ms 合并为一次 `git status`；改动列表渲染不建树；自动 fetch 由 10s 放宽到 180s |
| 缩略图保护 | 迷你地图只排版可视区域，内容高度超约 5000 行时停用，避免秒级主线程卡顿 |

### 稳定性修复

- 括号配对高亮的 `NSRangeException` 崩溃（SwiftUI 布局期间触发）；
- blame 错误分类：未跟踪 / 无提交 / 文件已删除 / 非 UTF-8 一律静默降级，只有真实故障才提示，且文案可读；
- 移除「全部展开」入口：大树下全量展开是 O(n²) 的主线程长任务；
- 历史时间显示为「现在」：修正 Git 日期解析（`%aD` + 本地化解析失败后回退当前时间）；
- 重命名 / 格式化进入撤销栈，并限制写入工作区范围内；
- blame 标注末行锚点：文件末尾无换行时不再吞掉最后一个可见字符。

### 中文化与工程化

- 界面与文案完整简体中文；
- 独立 Bundle ID / App Group / URL Scheme / 应用支持目录，可与原版 CodeEdit 并存；
- `scripts/build.sh`（可指定目标架构）与 `scripts/package-dmg.sh`（ad-hoc 签名 + dmg + SHA256）；
- GitHub Actions 云打包：四仓库同级检出自建包、Release 构建、产出 universal dmg，推 `v*` 标签时发布到 GHCR。

## 构建与打包

**本地**

```bash
./scripts/build.sh Release        # → build/Build/Products/Release/Qiyide.app
./scripts/package-dmg.sh Release  # → build/Qiyide-<版本>-<build>.dmg
```

**云端**：Actions → `Build DMG` → Run workflow；或推送 `v*` 标签自动构建并发布
`ghcr.io/shadowhunt-yi/qiyide:<tag>`。

> 产物为 ad-hoc 签名，首次打开需右键 → 打开，或 `xattr -dr com.apple.quarantine /Applications/Qiyide.app`。

## 许可证与归属

- **上游**：CodeEdit — MIT，`Copyright (c) 2022 CodeEdit`（[LICENSE.md](LICENSE.md) 为上游原文）
- **本仓库**：MIT，保留上游版权声明；修改与依赖归属见 [NOTICE.md](NOTICE.md)
- “CodeEdit” 名称与图标归上游所有，本项目仅作来源说明

## 上游项目

本项目全部能力建立在上游 [CodeEdit](https://github.com/CodeEditApp/CodeEdit) 之上，
建议同时阅读上游 README 与其贡献指南。与上游共有的缺陷请反馈至上游 Issues；
仅存在于本仓库的问题请提到[本项目 Issues](https://github.com/ShadowHunt-yi/Qiyide/issues)。
