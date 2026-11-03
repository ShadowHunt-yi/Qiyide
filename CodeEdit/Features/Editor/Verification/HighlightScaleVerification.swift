//
//  HighlightScaleVerification.swift
//  CodeEdit
//
//  对照实验：大文件的 tree-sitter 初始解析，同步 vs 异步。
//
//  `TreeSitterClient.setUp` 原来无条件同步解析全文（主线程），12MB 要几秒，
//  表现就是「打开大文件卡死」。现在按 `Constants.maxSyncContentLength` 分流：
//  小文件同步（立刻有高亮），大文件异步（先显示纯文本，解析完再上色）。
//
//  这个入口把同一个 `TreeSitterClient` 在两个阈值下各跑一次，直接对比
//  `setUp` 的返回耗时——同步那次就是修复前用户感受到的阻塞。
//
//  用法：
//    QIYIDE_VERIFY_HIGHLIGHT=1 build/QiyideDev.app/Contents/MacOS/QiyideDev
//  可选：
//    QIYIDE_VERIFY_HIGHLIGHT_LINES=2000,20000,200000
//

#if DEBUG
import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import Foundation

enum HighlightScaleVerification {

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_HIGHLIGHT"] != nil else { return }
        let sizes = (ProcessInfo.processInfo.environment["QIYIDE_VERIFY_HIGHLIGHT_LINES"] ?? "2000,20000,200000")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        Task { @MainActor in
            for lines in sizes {
                let sample = (0..<lines)
                    .map { "let value\($0) = someFunction(\($0), \"payload-\($0)\")" }
                    .joined(separator: "\n")
                let textView = TextView(string: sample)
                textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
                let length = textView.documentRange.length

                // 同步（= 修复前的行为）：把阈值抬到无穷大，走 operation() 直执行。
                TreeSitterClient.Constants.maxSyncContentLength = Int.max
                let syncClient = TreeSitterClient()
                let syncStart = Date()
                syncClient.setUp(textView: textView, codeLanguage: .swift)
                let syncMS = Date().timeIntervalSince(syncStart) * 1000

                // 异步（= 修复后）：恢复阈值，大文件走 executor 队列。
                TreeSitterClient.Constants.maxSyncContentLength = 1_000_000
                let asyncClient = TreeSitterClient()
                let asyncStart = Date()
                asyncClient.setUp(textView: textView, codeLanguage: .swift)
                let asyncMS = Date().timeIntervalSince(asyncStart) * 1000

                let verdict = length > 1_000_000
                    ? (asyncMS < syncMS / 10 ? "大文件已改为异步（通过）" : "仍是同步（未生效）")
                    : "小文件保持同步（预期行为）"
                log(String(
                    format: "[verify][highlight] %7d 行 / %9d 字符 · 同步 setUp %8.1f ms · 异步 setUp %7.1f ms · %@",
                    lines, length, syncMS, asyncMS, verdict
                ))
            }
            exit(0)
        }
    }
}
#endif
