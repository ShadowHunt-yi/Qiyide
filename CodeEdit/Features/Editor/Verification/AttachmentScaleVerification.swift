//
//  AttachmentScaleVerification.swift
//  CodeEdit
//
//  量化 `TextAttachmentManager` 的规模成本。
//
//  行尾标注（git blame）与查找高亮都是「每处匹配一个附件」，数量可以到几万。
//  原来两个操作是 O(n) 甚至 O(n²)：
//  - `add`：每插一条都搬移数组（O(n)），并触发一次全量布局失效
//  - `textUpdated`：每次按键遍历全部附件（这条是 package 方法，这里测不到，
//    只能靠代码评审；基准覆盖的是数组侧的成本）
//
//  用法：
//    QIYIDE_VERIFY_ATTACH=1 build/QiyideDev.app/Contents/MacOS/QiyideDev
//  可选：
//    QIYIDE_VERIFY_ATTACH_COUNTS=2000,10000,30000
//

#if DEBUG
import AppKit
import CodeEditTextView
import Foundation

/// 基准用最小附件：只要求协议里的三个成员。
private final class BenchmarkAttachment: TextAttachment {
    var width: CGFloat = 0
    var isSelected: Bool = false
    func draw(in context: CGContext, rect: NSRect) {}
}

enum AttachmentScaleVerification {

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_ATTACH"] != nil else { return }
        let counts = (ProcessInfo.processInfo.environment["QIYIDE_VERIFY_ATTACH_COUNTS"] ?? "2000,10000,30000")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        Task { @MainActor in
            for count in counts {
                // 附件均匀散布在文档里，模拟「每行一个标注」。
                let items: [(attachment: any TextAttachment, range: NSRange)] = (0..<count).map {
                    (BenchmarkAttachment(), NSRange(location: $0 * 12, length: 1))
                }

                // 逐条：每次 insert 都搬移数组（旧路径）
                let oneByOne = TextAttachmentManager()
                let t1 = Date()
                for item in items {
                    oneByOne.add(item.attachment, for: item.range)
                }
                let oneByOneMS = Date().timeIntervalSince(t1) * 1000

                // 批量：拼接一次、排序一次（新路径）
                let batched = TextAttachmentManager()
                let t2 = Date()
                batched.add(contentsOf: items)
                let batchedMS = Date().timeIntervalSince(t2) * 1000

                // 视口查询：取文档中段一屏（约 80 行）内的附件
                let mid = count / 2
                let queryRange = NSRange(location: mid * 12, length: 80 * 12)
                let t3 = Date()
                var found = 0
                for _ in 0..<1000 {
                    found = batched.getAttachmentsOverlapping(queryRange).count
                }
                let queryMS = Date().timeIntervalSince(t3) * 1000

                let ratio = batchedMS > 0 ? oneByOneMS / batchedMS : 0
                log(String(
                    format: "[verify][attach] %6d 个 · 逐条 %8.1f ms · 批量 %6.1f ms（%.1f×）· 查询×1000 %6.1f ms（命中 %d）",
                    count, oneByOneMS, batchedMS, ratio, queryMS, found
                ))
            }
            exit(0)
        }
    }
}
#endif
