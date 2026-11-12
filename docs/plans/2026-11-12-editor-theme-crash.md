---
title: 这次崩溃的原因：dev 包漏了主题资源
subtitle: 2026-11-12 · 14:00:09 崩溃，主线程空主题强制解包。
lang: zh
template: sheet
theme: blueprint
cols: 2
source: macOS 崩溃报告、统一日志、安装包与源码核对
---
这是此前 dev 打包遗漏引发的编辑器崩溃。
不是建档 800 额度、模型服务或内存上限。

## A 日志明确指向哪里 {span=2}
```callout warn 已定位，不是猜测
进程从 /Applications/QiyideDev.app 启动。
版本 0.3.7 (48)，PID 91312。
14:00:09.920 在 CodeFileView.swift:155 崩溃。
```
最近报告生成于 2026-11-12 14:00:24。
报告的可执行 UUID 与安装包完全一致。

```text title="统一日志的致命错误"
CodeEdit/CodeFileView.swift:155:
Fatal error: Unexpectedly found nil while unwrapping an Optional value
```
主线程调用栈：断言失败 → currentTheme → 代码编辑器 body。

## B 为什么主题会为空
```flow
dev 打包只复制 CodeEdit 子目录 -> 漏掉根目录 DefaultThemes
漏掉根目录 DefaultThemes -> 主题目录读取失败
用户主题目录也为空 -> 无可用主题
主题目录读取失败 -> 无可用主题
无可用主题 -> themes.first 强制解包
 themes.first 强制解包 -> 主线程崩溃: 打开文件并渲染时
```
源仓库有 18 个内置主题，安装包却没有该目录。
Xcode 工程会复制它，SwiftPM 打包脚本此前遗漏了。

## C 已修复什么
- 打包明确复制 DefaultThemes，并逐项验证内容。
- 删除编辑器当前主题的强制解包。
- 浅色和深色都有不依赖文件的内存安全兜底。
- 某目录缺失或一个主题损坏，不影响其他主题。
- 加载失败不清空保存的主题选项。
- 不重置配置、Keychain、知识库或缓存。

| 验证 | 结果 |
|---|---|
| 完整 App 模块相关测试 | 171 项通过，14 个套件 |
| 新增主题回归 | 10 项，包括空数组与缺失资源 |
| 实际包内主题 | 18 个与源文件逐项一致 |
| 开发包签名 | deep / strict 验证通过 |

这些不是全仓 XCTest 或真实业务系统回归。

## D 修复包与现场证据
修复包包含同工作区的建档续跑修复。
**尚未替换安装 App。** 用户设置和旧安装包保持不变。

[修复开发包 ZIP](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-editor-theme-fix.zip)

[包验证清单](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-editor-theme-fix.manifest.json)

[精确致命日志](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-editor-theme-crash-2026-11-12/fatal-log.txt)

[开发记录与代码位置](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/worklog/M2/2026-11-12-editor-theme-crash.md)
