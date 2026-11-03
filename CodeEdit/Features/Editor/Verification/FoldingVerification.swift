//
//  FoldingVerification.swift
//  CodeEdit
//
//  验证折叠的两件事：
//  1. 缩进扫描算出的候选区间对不对（含空行跟随、尾部空行剔除）；
//  2. 折叠真的改到了布局层面——被折叠行的高度归零、展开后原样还原。
//
//  用法：
//    QIYIDE_VERIFY_FOLD=1 build/QiyideDev.app/Contents/MacOS/QiyideDev
//

#if DEBUG
import AppKit
import CodeEditTextView
import Foundation

enum FoldingVerification {

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_FOLD"] != nil else { return }

        Task { @MainActor in
            // 4 空格缩进的嵌套结构，末尾故意留一个空行。
            let sample = [
                "struct A {",            // 0，缩进 0
                "    func f() {",        // 1，缩进 4
                "        print(1)",      // 2，缩进 8
                "",
                "    }",                 // 4，缩进 4
                "}",                     // 5，缩进 0
                ""                       // 6，空行
            ].joined(separator: "\n")

            let model = FoldingModel()
            model.refreshCandidates(text: sample, tabWidth: 4)
            let candidates = model.currentCandidates()
            let rendered = candidates.map { "\($0.lines.lowerBound)...\($0.lines.upperBound)" }
            log("[verify][fold] 缩进候选：\(rendered.joined(separator: "  "))  期望 0...4  1...3")

            let textView = TextView(string: sample)
            textView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            guard let layoutManager = textView.layoutManager else {
                log("[verify][fold] 无 layoutManager，跳过布局验证")
                exit(1)
            }

            let lineCountBefore = layoutManager.lineStorage.count
            // 折叠最外层：0...4（首行 0 保留可见，1..4 被隐藏）
            model.fold(0...4)
            layoutManager.setFoldedLineRanges(model.regions.map(\.lines))

            let hidden = (1...4).filter { layoutManager.isLineFolded($0) }
            let visibleCheck = layoutManager.isLineFolded(0) == false
            log("[verify][fold] 折叠 0...4 → 隐藏行 \(hidden)，首行仍可见：\(visibleCheck ? "是" : "否")，"
                + "行数不变：\(layoutManager.lineStorage.count == lineCountBefore ? "是" : "否")")

            // 展开
            model.unfold(containingLine: 2)
            layoutManager.setFoldedLineRanges(model.regions.map(\.lines))
            let stillHidden = (0...6).filter { layoutManager.isLineFolded($0) }
            log("[verify][fold] 展开后仍隐藏的行：\(stillHidden)（应为空）")

            // 规模：十万行的候选计算耗时
            let bigText = (0..<100_000).map { index -> String in
                let depth = index % 8
                return String(repeating: "    ", count: depth) + "line\(index)"
            }.joined(separator: "\n")
            let start = Date()
            let bigModel = FoldingModel()
            bigModel.refreshCandidates(text: bigText, tabWidth: 4)
            let ms = Date().timeIntervalSince(start) * 1000
            log(String(
                format: "[verify][fold] 十万行缩进扫描 %.1f ms，候选 %d 个",
                ms, bigModel.currentCandidates().count
            ))

            // 按需扫描：交互路径只算点中的那一块，不扫全文。
            let bigView = TextView(string: bigText)
            bigView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            if let bigLayout = bigView.layoutManager {
                let probeStart = Date()
                let range = bigLayout.foldableRange(startingAtLine: 50_000, tabWidth: 4)
                let probeMS = Date().timeIntervalSince(probeStart) * 1000
                let desc = range.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil"
                log(String(format: "[verify][fold] 按需扫描单块 %.2f ms → %@", probeMS, desc))
            }

            exit(0)
        }
    }
}
#endif
