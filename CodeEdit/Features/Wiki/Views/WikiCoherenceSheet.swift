//
//  WikiCoherenceSheet.swift
//  CodeEdit
//
//  一致性体检面板：按问题类型分组列出「模型 / 知识 / 代码」对不上的地方。
//
//  只提供一种批量修复（清除悬空归属），其余只报不改——
//  「某个域没有知识」该生成还是该删域，是人的判断，不是程序的。
//

import SwiftUI

struct WikiCoherenceSheet: View {

    let root: URL
    let graph: MindGraph
    @ObservedObject var store: WikiStore
    /// 修复后通知父视图重算（父视图还要刷新状态条与列表）。
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var report: CoherenceReport?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 680, height: 520)
        .task { recompute() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一致性体检")
                .font(.system(size: 14, weight: .medium))
            Text("检查领域模型、知识条目与代码之间对不上的地方。"
                 + "只报确定的问题，不做模糊推断。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let report {
                if report.isEmpty {
                    Label("没有发现问题", systemImage: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                } else {
                    Text(report.groups.map { "\($0.kind.title) \($0.issues.count)" }
                        .joined(separator: " · "))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if let report {
            if report.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 24))
                        .foregroundStyle(.green)
                    Text("模型、知识与代码是一致的")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(report.groups, id: \.kind) { group in
                            section(group.kind, issues: group.issues)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section(_ kind: CoherenceReport.Kind, issues: [CoherenceReport.Issue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: kind))
                    .frame(width: 7, height: 7)
                Text(kind.title)
                    .font(.system(size: 11, weight: .medium))
                Text("\(issues.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(hint(for: kind))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(issues.prefix(20)) { issue in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(issue.headline)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Text(issue.detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
                if issues.count > 20 {
                    Text("…还有 \(issues.count - 20) 条")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func color(for kind: CoherenceReport.Kind) -> Color {
        switch kind {
        case .dangling: return .red
        case .gap: return .orange
        case .unassigned: return .yellow
        case .staleSource: return .purple
        case .baseDrift: return .secondary
        }
    }

    private func hint(for kind: CoherenceReport.Kind) -> String {
        switch kind {
        case .dangling: return "可一键清除"
        case .gap: return "在导图模式「⋯ → 生成缺失知识」"
        case .unassigned: return "用「域归属」补写"
        case .staleSource: return "代码已删除或改名，需人工确认"
        case .baseDrift: return "重新识别可使模型跟上代码"
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if let dangling = report?.count(.dangling), dangling > 0 {
                Text("清除后这些条目会回到「未归类」")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
            Button("清除悬空归属") { clearDangling() }
                .disabled((report?.count(.dangling) ?? 0) == 0)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: 动作

    private func recompute() {
        report = WikiCoherence.check(root: root, graph: graph, store: store)
    }

    private func clearDangling() {
        guard let report else { return }
        do {
            let count = try WikiCoherence.clearDangling(report, store: store)
            message = "已清除 \(count) 条条目的悬空归属"
            onChanged()
            recompute()
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
    }
}
