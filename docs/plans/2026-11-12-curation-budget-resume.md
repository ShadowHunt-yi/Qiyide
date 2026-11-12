---
title: 建档续跑修复：本次额度不等于历史累计
subtitle: 2026-11-12 · 旧成果不清空，文件理解和模块输出分开。
lang: zh
theme: blueprint
template: sheet
cols: 2
source: 本地检查点、隔离回归与真实组件截图
---
这是上一版遗留的预算和兼容性问题，不是让你扩大历史上限就能解决。
修复不清空成本，也不把旧观察虚标成当前完成。

## A 两个根因 {span=2}
```callout warn 为什么 2362 次历史会卡住 800 的额度
原逻辑用历史累计请求数比较 800 的上限。
再次启动仍读取 2362，所以立刻再次暂停。
新版模块统计又不认识旧记录，界面只显示 0。
```
实际旧状态保留 2627/2654 个历史完成文件。
2629 份文件观察也还在，但缺少读取时版本。

## B 修复后的预算规则
```flow
用户点击开始 -> 本次有限额度: 默认 800 次
本次有限额度 -> 缓存与任务续跑
缓存与任务续跑 -> 正常暂停: 本次额度或时长到达
正常暂停 -> 用户再次点击继续
用户再次点击继续 -> 新的本次额度: 复用已保存观察
缓存与任务续跑 -> 历史累计: 持续记账，不清零
```
并发请求和重试仍共用同一预算闸门。
不自动重开额度，不在后台无限请求。
面板可以编辑下一次的请求数和时长。

## C 为什么进度不再笼统显示 0
| 指标 | 现在表示什么 |
|---|---|
| 当前理解 | 当前内容和模型策略匹配的文件观察 |
| 模块输出 | 完整草稿、更新建议或明确无需沉淀 |
| 旧观察待升级 | 缺少读时版本，只作为历史材料保留 |
| 旧任务 2627/2654 | 历史完成口径，不冒充当前处理数 |
| 历史累计请求 2362 | 沿用旧记账，不占本次额度，也不是账单 |

已经理解但尚未输出模块，会显示两种进度。
旧观察和旧模块摘要在升级前归档保留。
没有版本凭据的旧观察仍需有限重新理解。

## D 面板预览 {span=2}
以下是真实 SwiftUI 组件的隔离样例，不是用户仓库的新产出。
样例用 1 次额度测试暂停与续跑。

![已理解两个文件、模块尚未输出；上次 1/1 与下次 800 分开显示](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/curation-resume-2026-11-12/budget-exhausted.png)

## E 验证与交付
| 验证范围 | 结果 |
|---|---|
| 轻量 Wiki 相关测试 | 158 项通过，12 个套件 |
| 完整 App 模块相关测试 | 161 项通过，13 个套件 |
| 真实组件隔离预览 | 4 张截图，暂停与续跑验证通过 |
| 开发包签名 | deep / strict 验证通过 |

这些测试不是全仓 XCTest 或真实模型回归。
实际任务只读核对，未写检查点或缓存，未发模型请求。
修复版没有自动替换正在使用的安装 App。

[开发记录](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/worklog/M2/2026-11-12-curation-budget-resume.md)

[修复版 ZIP](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-curation-resume.zip)

[只读核对结果](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-curation-resume-2026-11-12/actual-state-verified.json)

[验证清单和哈希](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-curation-resume.manifest.json)
