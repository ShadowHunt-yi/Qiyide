import AppKit
import SwiftUI

struct WikiKnowledgeContextSheet: View {
    let root: URL
    /// nil 表示全库；筛选后的 ID 只约束范围，不沿用此前的可信状态。
    let entryIDs: Set<String>?
    let onClose: () -> Void
    @State private var snapshot: WikiContextSnapshot?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("给 AI 的知识上下文").font(.system(size: 17, weight: .semibold))
                    Text("只纳入已确认且符合来源条件的知识。复制不会自动发送给外部 AI。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose)
            }
            if let snapshot {
                HStack {
                    Text("\(snapshot.items.count) 条参考 · 排除 \(snapshot.excludedCount) 条 · 预算外 \(snapshot.omittedCount) 条")
                    Spacer()
                    Button(copied ? "已复制快照" : "复制这份快照") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snapshot.text, forType: .string)
                        copied = true
                    }
                }
                .font(.system(size: 11))
                ScrollView {
                    Text(snapshot.text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Text("快照是当次校验的结果。规则或代码变化后，请重新打开并生成新快照。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ProgressView("重新读取知识并校验来源…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .task {
            snapshot = await WikiKnowledgeContext.load(root: root, entryIDs: entryIDs)
        }
    }
}
