import SwiftUI

struct WikiSourceCheckFeedback: View {
    @ObservedObject var store: WikiStore
    let entries: [WikiEntry]
    let onReport: (() -> Void)?

    private var counts: WikiKnowledgeCheckCounts { .count(entries: entries, report: store.knowledgeReport) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch store.knowledgeCheck.status {
            case .checking:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("正在校验 \(store.knowledgeCheck.progress.checkedEntries)/\(store.knowledgeCheck.progress.totalEntries) 条知识")
                    Spacer()
                    Button("取消校验") { store.cancelKnowledgeCheck() }.controlSize(.small)
                }
                ProgressView(value: store.knowledgeCheck.progress.fraction).progressViewStyle(.linear)
                if !store.knowledgeCheck.progress.currentEntry.isEmpty {
                    Text("当前：" + store.knowledgeCheck.progress.currentEntry)
                }
                if !store.knowledgeCheck.progress.currentPath.isEmpty {
                    Text(store.knowledgeCheck.progress.currentPath).font(.system(size: 10, design: .monospaced))
                        .lineLimit(2).textSelection(.enabled)
                }
                Text("校验只读来源，不自动确认、修改内容或创建来源基线。")
                    .foregroundStyle(.secondary)
            case .completed:
                Label(store.knowledgeCheck.message, systemImage: counts.review > 0 ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(counts.review > 0 ? Color.orange : Color.green)
                    .font(.system(size: 11, weight: .medium))
                Text("本次检查了 \(store.knowledgeReport.sourcesChecked) 个来源 / 范围项，未修改或确认任何条目。")
                    .foregroundStyle(.secondary)
                ForEach(WikiEvidenceIssue.Kind.allCases.filter { (counts.reasons[$0] ?? 0) > 0 }, id: \.self) { reason in
                    Text("\(counts.reasons[reason] ?? 0) 条：\(reason.title)")
                }
                if counts.review > 0 {
                    Text("校验已完成，但仍有来源问题未解决。查看具体路径和下一步；重新校验不会自动确认或创建来源基线。")
                        .foregroundStyle(.secondary)
                }
                if let onReport { Button("查看校验报告与下一步", action: onReport).controlSize(.small) }
            case .cancelled, .failed:
                Label(store.knowledgeCheck.message, systemImage: store.knowledgeCheck.status == .failed ? "exclamationmark.triangle" : "pause.circle")
                    .foregroundStyle(store.knowledgeCheck.status == .failed ? Color.red : Color.secondary)
                Text("没有自动修改知识或确认记录。可点击重新校验。")
                    .foregroundStyle(.secondary)
            case .idle:
                if store.knowledgeReport.checkedAt != nil, let onReport {
                    Button("查看当前校验结果", action: onReport).controlSize(.small)
                }
            }
        }
        .font(.system(size: 10))
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("wiki-source-check-feedback")
    }
}

struct WikiSourceCheckReportSheet: View {
    @ObservedObject var store: WikiStore
    let entries: [WikiEntry]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源校验报告").font(.system(size: 17, weight: .semibold))
                    Text("校验判断版本，不证明业务正确，也不自动更新人工确认。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            WikiSourceCheckFeedback(store: store, entries: entries, onReport: nil)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(entries.sorted { $0.title < $1.title }) { entry in
                        reportCard(entry)
                    }
                }
            }
            HStack {
                Spacer()
                Button(store.isCheckingKnowledge ? "校验中…" : "重新校验") { store.refreshKnowledge() }
                    .disabled(store.isCheckingKnowledge)
            }
        }
        .padding(18)
        .frame(width: 640, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func reportCard(_ entry: WikiEntry) -> some View {
        let assessment = store.assessment(for: entry)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(entry.displayTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                WikiKnowledgeBadge(assessment: assessment)
            }
            Text("实际文件来源：\(entry.sources.count) · 声明范围：\(entry.scopePaths.count)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text(assessment.detail).font(.system(size: 11)).textSelection(.enabled)
            if !assessment.issues.isEmpty {
                DisclosureGroup("展开 \(assessment.issues.count) 个具体问题") {
                    ForEach(Array(assessment.issues.enumerated()), id: \.offset) { _, issue in
                        VStack(alignment: .leading, spacing: 3) {
                            if let path = issue.path {
                                Text(path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                            }
                            Text(issue.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }.font(.system(size: 10))
            }
            if !assessment.nextStep.isEmpty {
                Text("下一步：" + assessment.nextStep).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button("查看原文与处理来源") { onSelect(entry.id); dismiss() }.controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
