//
//  DomainBackfillSheet.swift
//  CodeEdit
//
//  域归属报告：把「历史条目属于哪个域」的判断摆出来，人确认后再落盘。
//
//  为什么要有这个面板而不是直接后台补：
//  归属是推断出来的，代码路径一改就可能错。让人看一眼「这条条目凭哪条路径
//  被判成 AI画像」，比事后去 diff 里找原因便宜得多。
//

import SwiftUI

struct DomainBackfillSheet: View {

    let root: URL
    let graph: MindGraph
    /// 与父页面共用同一个 store：补写后父页面的域计数、体检要立刻跟着变。
    /// 早先这里自己 new 了一个 WikiStore，写完文件父页面毫不知情，
    /// 用户会以为按钮没生效。
    @ObservedObject var store: WikiStore
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var report: DomainBackfillReport?
    @State private var message: String?
    @State private var working = false

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
        .task { load() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("域归属")
                .font(.system(size: 14, weight: .medium))
            Text("按条目的关联代码路径匹配域的包路径，只补「能唯一确定」的条目。"
                 + "多义与匹配不到的保持未归类，留给人工判断。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let report {
                Text(report.summary)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
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
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                    Text("没有需要处理的条目")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !report.gaps.isEmpty {
                            section("空缺域（没有任何知识）", count: report.gaps.count) {
                                ForEach(report.gaps) { gap in
                                    HStack(spacing: 6) {
                                        Text(gap.domainTitle)
                                            .font(.system(size: 11, weight: .medium))
                                        Text("\(gap.classCount) 类")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(gap.domainID)
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }

                        if !report.suggestions.isEmpty {
                            section("可归属", count: report.suggestions.count) {
                                ForEach(report.suggestions) { item in
                                    suggestionRow(item, domainColor: .accentColor)
                                }
                            }
                        }

                        if !report.ambiguous.isEmpty {
                            section("多义（需人工确定）", count: report.ambiguous.count) {
                                ForEach(report.ambiguous) { item in
                                    suggestionRow(item, domainColor: .orange)
                                }
                            }
                        }

                        if !report.orphans.isEmpty {
                            section("匹配不到域", count: report.orphans.count) {
                                ForEach(report.orphans) { item in
                                    HStack(spacing: 6) {
                                        Text(item.entryTitle)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(item.sourceCount) 条关联代码")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
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

    private func suggestionRow(_ item: DomainBackfillReport.Suggestion, domainColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(item.entryTitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
                Text(item.domainTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(domainColor)
                    .lineLimit(1)
                Spacer()
            }
            Text(item.via)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func section<Content: View>(
        _ title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            content()
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if let report, !report.suggestions.isEmpty {
                Text("将写入 \(report.suggestions.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { dismiss() }
            Button("按建议补写") { applySuggestions() }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (report?.suggestions.isEmpty ?? true))
        }
    }

    // MARK: 动作

    private func load() {
        report = WikiDomainBackfill.report(graph: graph, store: store)
    }

    private func applySuggestions() {
        guard let report else { return }
        working = true
        do {
            let count = try WikiDomainBackfill.apply(report, store: store)
            message = "已补写 \(count) 条"
            onChanged()
        } catch {
            message = "写入失败：\(error.localizedDescription)"
        }
        // 写完重算：剩下的多义/无归属数量会变。
        self.report = WikiDomainBackfill.report(graph: graph, store: store)
        working = false
    }
}
