---
title: 校验来源已修：给出进度、阻塞原因与下一步
subtitle: 2026-11-12 · 校验不能代替人工确认，也不能补出没绑定的来源。
lang: zh
template: sheet
theme: blueprint
cols: 2
source: 用户截图、实际记录只读核对、隔离回归与真实组件预览
---
不是你的操作问题：旧模板写入了业务包简称，但实际文件来源为 0。
原界面又没展示阻塞原因，反复校验看起来像没有执行。

## A 为什么始终 9 条需核对 {span=2}
```callout warn 已定位实际记录，不是猜测
9 条都是已确认的领域模板，但没有实际文件来源。
136 份范围记录没有可核验的确认摘要。
agent/suggest 等简称不是完整仓库路径。
```
点击校验只读取既有记录，不能凭空创建文件来源。
也不能把旧模型结果直接绑定到当前代码并自动变绿。

## B 新版怎样反馈
- 点击后显示校验中、条目进度和当前路径。
- 可取消，重复点击不会启动并行任务。
- 完成后持续显示结果，不只改一个时间。
- 报告列出缺基线、无法读取和已变化的具体路径。
- 原状态未改变时，说明阻塞原因和下一步。
- 取消或失败不会把部分结果标为完成。

![完成后明确保留 9 条阻塞原因；这是隔离组件样例](/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/wiki-dev/source-check-2026-11-12/completed-with-blockers.png)

## C 如何处理原有来源
```flow
校验报告 -> 查看原文与来源
查看原文与来源 -> 唯一还原真实路径: 使用 Java 源码根与公共包前缀
查看原文与来源 -> 手动选择实际范围: 同名模块或目录缺失
唯一还原真实路径 -> 来源更新建议
手动选择实际范围 -> 人工核对
来源更新建议 -> 人工对照后接受
人工对照后接受 -> 再次校验
人工核对 -> 再次校验
```
实际只读检查：5 条可唯一还原，4 条仍有多义或缺失范围。
**没有自动改写或确认你的 9 条知识。**
新建议保留原文；接受前再查来源与原版本。

新版操作路径：
1. 点击“查看校验报告与下一步”。
2. 进入具体条目的原文。
3. 唯一范围选择“解析真实来源并生成更新建议”。
4. 有歧义时手动编辑完整文件来源和范围。
5. 对照无误后接受建议或确认，再校验。

## D 已验证什么
| 验证范围 | 结果 |
|---|---|
| 轻量 Wiki 相关测试 | 173 项通过，13 个套件 |
| 完整 App 模块相关测试 | 186 项通过，15 个套件 |
| 来源校验组件预览 | 4 张截图，含运行、阻塞和人工接受 |
| 原知识、缓存和任务文件 | 14 个文件内容未变 |
| 模型调用 | 0 次 |
| 开发包主题与签名 | 18 个主题核对，deep / strict 通过 |

这些不是全仓 XCTest 或独立业务验收。
代码和路径未变，不代表业务判断已被证明。

## E 修复包与记录
新包同时包含建档续跑和主题崩溃修复。
**尚未替换安装 App，需要明确安装后才生效。**

[修复开发包 ZIP](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-source-check-fix.zip)

[完整验证清单](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev-2026-11-12-source-check-fix.manifest.json)

[开发记录与关键文件](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/docs/worklog/M2/2026-11-12-source-check-feedback.md)

[实际记录只读报告](file:///Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.debug/DBG-source-check-feedback-2026-11-12/actual-check-report.json)
