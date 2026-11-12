# 安装已验证的知识建设 dev 包

- 日期：2026-11-12（Asia/Shanghai）
- 类型：chore
- 里程碑：M2

## What（改了什么）

按用户“替换”的明确授权，将 `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/QiyideDev.app` 安装为 `/Applications/QiyideDev.app`，版本 0.3.7 (48)。

旧版通过正常退出关闭，没有强制结束。旧 App 整包移入备份：`/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-backups/QiyideDev-before-knowledge-contracts-2026-11-12-134432-bc78ef.app`。先暂存校验，再替换；出错时有恢复旧版的路径。

## Why（为什么改）

前一轮只交付开发包，未替换安装版。本次用户明确要求替换，使安装 App 使用已经完成相关测试的知识版本缓存、完整模块聚合、来源更新、正常跳过与人工保护改动。

## Impact（影响范围）

- 只替换 `/Applications/QiyideDev.app` 的应用包，不删除或清理用户配置、Keychain、知识库或业务仓库。
- 正常启动安装路径的新版，PID 91312。NSWorkspace 报告启动完成，延后检查进程仍运行；这不是完整功能验收。
- 完整暂存包与安装包文件/符号链接摘要和工作区开发包一致；旧版备份也逐项一致。
- 安装包 `codesign --verify --deep --strict` 通过。仍是本地 ad-hoc dev 签名，不代表正式公证。
- 新可执行文件 SHA-256：`49c98449e7b7a12c9cbaebd687d73ca42b448a2e0c4c9bfa7b21fa410079bc0f`。
- 不重编、不提交、不推送，也不调用真实模型。原 144 项轻量 Wiki 与 147 项完整 App 模块相关测试证据沿用已打包版本。
- 前一轮清单中的“安装版未替换”是打包交付时的历史状态；本次安装结果单独保存在 `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.implementation/KNOWLEDGE-2026-11-12/installation.json`。

## 涉及文件

- `/Applications/QiyideDev.app` — 已替换并启动。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/build/app-backups/QiyideDev-before-knowledge-contracts-2026-11-12-134432-bc78ef.app` — 可恢复的旧应用包。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.implementation/KNOWLEDGE-2026-11-12/installation.json` — 安装、备份、签名、内容哈希与启动记录。
- `/Users/ext.liangzhenqi1/project/mycase/CodeEdit/.workflow/.implementation/KNOWLEDGE-2026-11-12/install-dev-app.py` — 可回滚的本地安装流程；原子重命名前核验版本。
