//
//  WikiKnowledgeOverview.swift
//  CodeEdit
//
//  先回答哪些知识值得看、能否作为依据；图谱与建模保留为进一步探索的工具。
//

import SwiftUI

struct WikiKnowledgeBadge: View {
    let assessment: WikiKnowledgeAssessment

    var body: some View {
        Text(assessment.state.title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Self.color(assessment.state))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Self.color(assessment.state).opacity(0.09), in: Capsule())
            .help(assessment.detail)
    }

    static func color(_ state: WikiKnowledgeState) -> Color {
        switch state {
        case .current: return .green
        case .agreement: return .blue
        case .stale: return .orange
        case .draft, .unreviewed, .unverifiable: return .secondary
        case .checking: return .secondary
        }
    }
}

struct WikiKnowledgeOverview: View {
    @ObservedObject var store: WikiStore
    let entries: [WikiEntry]
    let onSelect: (String) -> Void
    let onCreateRule: () -> Void
    let onShowContext: () -> Void
    @State private var lens: Lens = .attention
    @State private var showSourceReport = false

    enum Lens: String, CaseIterable {
        case attention = "待我核对"
        case rules = "规则与术语"
        case decisions = "决策与边界"
        case implementation = "实现参考"
        case all = "全部"
    }

    private var visible: [WikiEntry] {
        entries.filter {
            switch lens {
            case .attention: return !store.assessment(for: $0).state.canReference
            case .rules: return [.rule, .term].contains($0.type)
            case .decisions: return [.decision, .incident].contains($0.type)
            case .implementation: return [.module, .topic].contains($0.type)
            case .all: return true
            }
        }.sorted {
            let left = rank($0), right = rank($1)
            return left == right ? $0.title < $1.title : left < right
        }
    }

    private func rank(_ entry: WikiEntry) -> Int {
        if entry.proposalFor != nil { return 0 }
        switch store.assessment(for: entry).state {
        case .stale: return 1
        case .unverifiable: return 2
        case .unreviewed: return 3
        case .draft: return 4
        case .checking: return 5
        case .agreement: return 6
        case .current: return 7
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content.frame(width: max(0, geometry.size.width), alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showSourceReport) {
            WikiSourceCheckReportSheet(store: store, entries: entries, onSelect: onSelect)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("业务知识与审查依据")
                    .font(.system(size: 19, weight: .semibold))
                Text("先核对规则、决策和来源，再把同一份知识交给 AI。条目多、图谱完整，都不等于业务已验证。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("新建业务规则", action: onCreateRule)
                    Button("给 AI 的上下文", action: onShowContext)
                    Button { store.refreshKnowledge() } label: {
                        HStack(spacing: 4) {
                            if store.isCheckingKnowledge { ProgressView().controlSize(.small) }
                            Text(store.isCheckingKnowledge ? "校验中…" : "校验来源")
                        }
                    }
                    .disabled(store.isCheckingKnowledge)
                    .help("只读检查内容、实际文件与范围，不会代替人工确认")
                }
                .controlSize(.small)
            }
            summary
            WikiSourceCheckFeedback(store: store, entries: entries, onReport: { showSourceReport = true })
            HStack {
                Text("查看").font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("知识视角", selection: $lens) {
                    ForEach(Lens.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 145)
                Spacer(minLength: 0)
            }
            if entries.isEmpty {
                empty("还没有知识", detail: "先记一条业务规则或设计决定；不必先给整个仓库建档。")
            } else if visible.isEmpty {
                empty("这个视角下没有待处理条目", detail: "这仅表示知识状态；代码实现与业务验收仍需单独审查。")
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { entry in card(entry) }
                }
            }
        }
        .padding(18)
    }

    private var summary: some View {
        let counts = WikiKnowledgeCheckCounts.count(entries: entries, report: store.knowledgeReport)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                metric("可作参考", value: counts.ready)
                metric("待确认", value: counts.drafts)
                metric("需核对", value: counts.review)
                if !store.isCheckingKnowledge && counts.checking > 0 { metric("待校验", value: counts.checking) }
                Spacer(minLength: 0)
            }
            if store.isCheckingKnowledge {
                Label("正在校验来源，暂不沿用旧状态", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if let date = store.knowledgeReport.checkedAt {
                Text("来源校验于 \(date.formatted(date: .omitted, time: .standard)) · 使用上下文前会重新校验")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.isCheckingKnowledge ? "—" : "\(value)")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func card(_ entry: WikiEntry) -> some View {
        let assessment = store.assessment(for: entry)
        return Button { onSelect(entry.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(entry.displayTitle).font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    WikiKnowledgeBadge(assessment: assessment)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary).font(.system(size: 12)).lineLimit(3)
                }
                Text(entry.proposalFor == nil ? assessment.detail : "这是更新建议，原知识保留。请先对照原文，再接受更新。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                HStack {
                    Text(entry.type.title)
                    Text("· \(entry.sources.count) 个实际文件")
                    if !entry.scopePaths.isEmpty { Text("· \(entry.scopePaths.count) 个范围") }
                    Spacer()
                    Text("查看与核对 →").foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }
}
