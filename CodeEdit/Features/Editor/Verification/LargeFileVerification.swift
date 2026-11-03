//
//  LargeFileVerification.swift
//  CodeEdit
//
//  量化「打开大文件」这条路径上几处 O(n) 的真实代价。
//
//  为什么需要：卡顿的结论不能靠读代码拍脑袋。合成一个几十 MB 的文本，
//  把旧实现（`textStorage.string` + `hashValue`）与新实现（`length` + 编辑代数）
//  摆在一起计时，才知道哪一处是主因、优化有没有意义。
//
//  用法：
//    QIYIDE_VERIFY_LARGE=1 build/QiyideDev.app/Contents/MacOS/QiyideDev
//  可选：
//    QIYIDE_VERIFY_LARGE_LINES=200000   合成多少行（默认 20 万行，约 20MB）
//

#if DEBUG
import AppKit
import Foundation

enum LargeFileVerification {

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_LARGE"] != nil else { return }
        let lineCount = Int(ProcessInfo.processInfo.environment["QIYIDE_VERIFY_LARGE_LINES"] ?? "200000") ?? 200_000

        Task { @MainActor in
            let sample = (0..<lineCount)
                .map { "let value\($0) = someFunction(\($0), \"payload-\($0)\") // 注释" }
                .joined(separator: "\n")
            let storage = NSTextStorage(string: sample)
            log("[verify][large] 样例：\(storage.length) 字符 / \(lineCount) 行 / "
                + "\(ByteCountFormatter.string(fromByteCount: Int64(sample.utf8.count), countStyle: .memory))")

            func measure(_ label: String, _ work: () -> Void) {
                let start = Date()
                work()
                log(String(format: "[verify][large]   %-34@ %8.1f ms", label as NSString,
                           Date().timeIntervalSince(start) * 1000))
            }

            log("[verify][large] 旧实现（每次刷新 / 每次 body 都做）：")
            var fullCopy = ""
            measure("textStorage.string（全文复制）") { fullCopy = storage.string }
            measure("String.hashValue（全文哈希）") { _ = fullCopy.hashValue }
            measure("getLastLines(5) 于全文") { _ = fullCopy.getLastLines(5) }

            log("[verify][large] 新实现：")
            var length = 0
            measure("storage.length（O(1)）") { length = storage.length }
            var bridged = NSMutableString()
            measure("mutableString 桥接（不复制）") { bridged = storage.mutableString }
            measure("切首尾各 512 字符") {
                _ = (bridged as NSString).substring(to: min(512, bridged.length))
                _ = (bridged as NSString).substring(from: max(0, bridged.length - 512))
            }

            log("[verify][large] 行级 blame 的逐行枚举（安装附件前的准备）：")
            var lineRanges: [NSRange] = []
            measure("enumerateSubstrings(.byLines)") {
                let nsText = bridged as NSString
                nsText.enumerateSubstrings(
                    in: NSRange(location: 0, length: nsText.length),
                    options: [.byLines, .substringNotRequired]
                ) { _, lineRange, _, _ in
                    lineRanges.append(lineRange)
                }
            }
            log("[verify][large]   得到 \(lineRanges.count) 行区间 → 旧实现会为每行建一个 TextAttachment")

            // 阈值判断：改动之后这两类文件的行为差异。
            let gate = 200_000
            log("[verify][large] 标注闸门 \(gate) 字符 → 本样例"
                + (storage.length > gate ? "不装行级标注（跳过 git blame）" : "正常装标注"))
            exit(0)
        }
    }
}
#endif
