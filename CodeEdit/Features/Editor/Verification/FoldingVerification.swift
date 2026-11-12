//
//  FoldingVerification.swift
//  CodeEdit
//
//  验的是「上游折叠引擎 + 我这层命令」这套东西真的能用：
//  1. 折叠区间算出来了吗（`LineIndentationFoldProvider` → `LineFoldCalculator`）；
//  2. `foldAll / unfoldAll / toggleFoldAtCursor` 有没有真的把占位附件塞进布局、
//     以及状态计数对不对；
//  3. 大文档下这几个命令的耗时（不能点一下卡一下）。
//
//  用法：
//    QIYIDE_VERIFY_FOLD=1 build/QiyideDev.app/Contents/MacOS/QiyideDev
//

#if DEBUG
import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Foundation

enum FoldingVerification {

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_FOLD"] != nil else { return }

        Task { @MainActor in
            log("[verify][fold] 开始")
            let sample = [
                "struct Outer {",           // 0
                "    func inner() {",       // 1
                "        if true {",        // 2
                "            print(1)",     // 3
                "            print(2)",     // 4
                "        }",                // 5
                "    }",                    // 6
                "",                         // 7
                "    func other() {",       // 8
                "        print(3)",         // 9
                "    }",                    // 10
                "}",                        // 11
            ].joined(separator: "\n")

            let controller = makeController(text: sample)
            log("[verify][fold] 控制器就绪（\(controller.foldableRegionCount) 个区间，可能还没算）")
            // 折叠计算是异步的（初始事件 → 180ms 防抖 → 全文档扫描），等它出结果。
            let ready = await waitForFolds(controller, timeout: 3)
            log("[verify][fold] 折叠区间计算：\(ready ? "已就绪" : "超时")（\(controller.foldableRegionCount) 个）")
            log("[verify][fold] 区间（行号）：" + describe(controller))

            // Tab 缩进：设置是「4 空格」，但文件用 1 个 Tab 作一级缩进。
            // 修复前深度按「前导空白**字符数** ÷ 4」算，1~2 个 Tab 都退化成深度 0，
            // 相邻行深度相同 → 浅层方法块完全算不出折叠区间（只有 ≥4 个 Tab 的深块能折），
            // 表现为「有的块能折、有的不能」。修复后按列宽换算，1 Tab 等价 4 空格。
            let tabSample = [
                "class A {",             // 0
                "\t@Override",           // 1
                "\tpublic void m() {",   // 2
                "\t\tif (x) {",          // 3
                "\t\t\tcall();",         // 4
                "\t\t}",                 // 5
                "\t}",                   // 6
                "}",                     // 7
            ].joined(separator: "\n")
            let tabController = makeController(text: tabSample)
            let tabReady = await waitForFolds(tabController, timeout: 3)
            let tabRegions = describe(tabController)
            log("[verify][fold] Tab 缩进：\(tabReady ? "已就绪" : "超时")"
                + "（\(tabController.foldableRegionCount) 个）→ \(tabRegions)")
            // describe() 的末行用「区间末偏移 - 1」映射，所以收尾行的编号是最后一条被覆盖的行。
            let tabPass = tabRegions.contains("0...6")
                && tabRegions.contains("2...6")
                && tabRegions.contains("3...5")
            log("[verify][fold] Tab 缩进期望 0...6 / 2...6 / 3...5 → \(tabPass ? "✅ 通过" : "❌ 不符")")

            // 光标放到第 4 行（`print(1)`），应命中 `if true {` 那一块。
            controller.setCursorPositions([CursorPosition(line: 4, column: 1)])
            controller.toggleFoldAtCursor()
            log("[verify][fold] 光标折叠 → 已收起 \(controller.collapsedRegionCount) · "
                + "占位附件 \(attachmentCount(controller))")

            // 再按一次应展开回去。
            controller.toggleFoldAtCursor()
            log("[verify][fold] 再折叠回去（应展开）→ 已收起 \(controller.collapsedRegionCount) · "
                + "占位附件 \(attachmentCount(controller))")

            // 光标能否穿过折叠区：收起 `if true {`（第 3-6 行）后，从上一行往下走，
            // 应该直接落到折叠区之后，而不是逐行「看不见地」移动。
            controller.setCursorPositions([CursorPosition(line: 4, column: 1)])
            controller.toggleFoldAtCursor()
            let collapsedLine = cursorLine(controller)
            controller.setCursorPositions([CursorPosition(line: 2, column: 1)])
            var visited: [Int] = []
            for _ in 0..<3 {
                controller.textView.selectionManager.moveSelections(direction: .down, destination: .line)
                visited.append(cursorLine(controller) ?? -1)
            }
            log("[verify][fold] 折叠第 \(collapsedLine) 行附近 → 从第 2 行连按 3 次↓，落点行：\(visited)")
            controller.unfoldAll()

            // 全部收起 / 全部展开。
            let foldStart = Date()
            controller.foldAll()
            let foldMS = Date().timeIntervalSince(foldStart) * 1000
            log(String(
                format: "[verify][fold] 全部收起 %.2fms → 已收起 %d · 占位附件 %d",
                foldMS, controller.collapsedRegionCount, attachmentCount(controller)
            ))

            let unfoldStart = Date()
            controller.unfoldAll()
            let unfoldMS = Date().timeIntervalSince(unfoldStart) * 1000
            log(String(
                format: "[verify][fold] 全部展开 %.2fms → 已收起 %d · 占位附件 %d",
                unfoldMS, controller.collapsedRegionCount, attachmentCount(controller)
            ))

            // 折叠状态记忆：同一个键的新控制器应恢复上次收起的段落；
            // 起始行文本变了（行号漂移）则不应恢复。
            let stateKey = "verify-fold-state-\(UUID().uuidString)"
            controller.foldStateKey = stateKey
            controller.setCursorPositions([CursorPosition(line: 4, column: 1)])
            controller.toggleFoldAtCursor()
            let anchors = controller.collapsedFoldAnchors
            log("[verify][fold] 记忆：收起 \(controller.collapsedRegionCount) 段 · "
                + "锚点 \(anchors.map { "\($0.startLine)...\($0.endLine)«\($0.openingText)»" })")

            // 直接按锚点恢复（绕过持久化），先确认恢复逻辑本身对不对。
            let direct = makeController(text: sample)
            _ = await waitForFolds(direct, timeout: 3)
            direct.restoreCollapsedFolds(anchors)
            log("[verify][fold] 记忆：直接恢复 → \(direct.collapsedRegionCount) 段")

            let reopened = makeController(text: sample)
            reopened.foldStateKey = stateKey
            _ = await waitForFolds(reopened, timeout: 3)
            log("[verify][fold] 记忆：重开同一文件 → 恢复 \(reopened.collapsedRegionCount) 段；"
                + "占位附件 \(attachmentCount(reopened))")

            let shifted = makeController(text: "// 首行被改过\n" + sample)
            shifted.foldStateKey = stateKey
            _ = await waitForFolds(shifted, timeout: 3)
            log("[verify][fold] 记忆：行号漂移后 → 恢复 \(shifted.collapsedRegionCount) 段（应为 0）")

            controller.clearPersistedFoldState()

            // 规模：不同行数下量「建控制器 + 首次折叠计算」的耗时，看是不是随行数爆炸。
            let probeText = String(repeating: "    probe line\n", count: 20_000)   // ≈ 280KB
            let probe = makeController(text: probeText)
            let storage = probe.textView.textStorage!
            let probes: [(String, () -> Void)] = [
                ("mutableString.length", { _ = storage.mutableString.length }),
                ("string.count", { _ = storage.string.count }),
                ("attributedSubstring(16)", {
                    _ = storage.attributedSubstring(from: NSRange(location: 0, length: 16)).length
                }),
                ("character(at: 100)", { _ = storage.mutableString.character(at: 100) }),
            ]
            for (name, block) in probes {
                let start = Date()
                for _ in 0..<200 { block() }
                let ms = Date().timeIntervalSince(start) * 1000
                log(String(format: "[verify][fold] 文本访问 · %@ × 200 次 %.1fms", name, ms))
            }

            for lineCount in [2_000, 5_000, 10_000, 20_000] {
                let text = (0..<lineCount).map { index -> String in
                    String(repeating: "    ", count: index % 6) + "line\(index)"
                }.joined(separator: "\n")

                let setupStart = Date()
                let big = makeController(text: text)
                let setupMS = Date().timeIntervalSince(setupStart) * 1000

                let calcStart = Date()
                let ready = await waitForFolds(big, timeout: 40)
                let calcMS = Date().timeIntervalSince(calcStart) * 1000
                log(String(
                    format: "[verify][fold] %d 行：建视图 %.0fms · 折叠计算 %.0fms（%@，%d 个区间）",
                    lineCount, setupMS, calcMS, ready ? "完成" : "超时", big.foldableRegionCount
                ))

                let foldStart = Date()
                big.foldAll()
                let foldMS = Date().timeIntervalSince(foldStart) * 1000
                let unfoldStart = Date()
                big.unfoldAll()
                let unfoldMS = Date().timeIntervalSince(unfoldStart) * 1000
                log(String(
                    format: "[verify][fold] %d 行：全部收起 %.2fms · 全部展开 %.2fms",
                    lineCount, foldMS, unfoldMS
                ))
            }

            exit(0)
        }
    }

    // MARK: - 辅助

    @MainActor
    static func makeController(text: String) -> TextViewController {
        log("[verify][fold]   构造控制器…")
        let controller = TextViewController(
            string: text,
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: theme,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    wrapLines: false
                ),
                // 迷你地图在验收里没有意义，且它要等真实可见区域才有意义。
                peripherals: .init(showGutter: true, showMinimap: false, showFoldingRibbon: true)
            ),
            cursorPositions: [],
            highlightProviders: []
        )
        log("[verify][fold]   init 完成，挂到窗口…")
        // 让 AppKit 正常驱动 loadView：折叠模型、折叠带、行号列都是在 loadView 里
        // 创建并互相绑定的，脱离窗口直接取 `view` 会卡住视图加载。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        log("[verify][fold]   窗口就绪")
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        verificationWindow = window
        return controller
    }

    /// 持有窗口，避免视图在验收过程中被释放。
    private static var verificationWindow: NSWindow?

    /// 验收只需要一套能画出来的配色，不追求主题效果。
    private static var theme: EditorTheme {
        EditorTheme(
            text: .init(color: .textColor),
            insertionPoint: .textColor,
            invisibles: .init(color: .gray),
            background: .textBackgroundColor,
            lineHighlight: .selectedTextBackgroundColor,
            selection: .selectedTextColor,
            keywords: .init(color: .systemPink),
            commands: .init(color: .systemBlue),
            types: .init(color: .systemMint),
            attributes: .init(color: .systemTeal),
            variables: .init(color: .systemCyan),
            values: .init(color: .systemOrange),
            numbers: .init(color: .systemYellow),
            strings: .init(color: .systemRed),
            characters: .init(color: .systemGreen),
            comments: .init(color: .systemGray)
        )
    }

    /// 等折叠计算完成。折叠是异步算的，直接读会读到空缓存。
    @MainActor
    private static func waitForFolds(_ controller: TextViewController, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.foldableRegionCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private static func cursorLine(_ controller: TextViewController) -> Int? {
        guard let range = controller.textView.selectionManager.textSelections.first?.range,
              let layout = controller.textView.layoutManager else { return nil }
        return layout.textLineForOffset(range.location)?.index
    }

    @MainActor
    private static func attachmentCount(_ controller: TextViewController) -> Int {        let length = controller.textView.textStorage.length
        guard length > 0 else { return 0 }
        return controller.textView.layoutManager.attachments
            .getAttachmentsOverlapping(NSRange(location: 0, length: length)).count
    }

    @MainActor
    private static func describe(_ controller: TextViewController) -> String {
        guard let layout = controller.textView.layoutManager else { return "（无布局管理器）" }
        let ranges = controller.foldableRanges.prefix(8).compactMap { range -> String? in
            guard let start = layout.textLineForOffset(range.lowerBound)?.index,
                  let end = layout.textLineForOffset(max(range.upperBound - 1, range.lowerBound))?.index else {
                return nil
            }
            return "\(start)...\(end)"
        }
        return ranges.isEmpty ? "（空）" : ranges.joined(separator: "  ")
    }
}
#endif
