//
//  WikiDomainDetailView.swift
//  CodeEdit
//
//  域详情：右栏选中一个域时显示。
//
//  它是「结构」和「知识」的接缝：上半是模型算出来的事实（归属包、负责人、
//  判定依据、模块），下半是挂在这个域下的知识条目。合并之前，这两半分处两个窗口。
//
//  为什么单独成文件：这段有 150 行，放在 WikiWindow 里让那个文件长到 1700 行，
//  而它本身只依赖「节点 + 条目 + 模块 + 三个回调」，不需要窗口的其它状态。
//  抽出来之后输入一目了然，也方便以后单独给知识图谱复用。
//

import SwiftUI

struct WikiDomainDetailView: View {

    let node: MindNode
    /// 已按更新时间降序的知识条目。
    let entries: [WikiEntry]
    /// 已按类数降序的模块。
    let modules: [MindNode]

    var onOpenMindMap: () -> Void
    var onGenerate: () -> Void
    var onSelectEntry: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                facts
                packageSection
                ownerSection
                evidenceSection
                moduleSection
                entrySection
            }
            .padding(14)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(node.displayTitle)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                if node.isManual {
                    WikiChip(text: "人工", color: .accentColor)
                }
                Spacer()
                Button("打开导图", action: onOpenMindMap)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("领域")
                Text("\(node.classCount) 类")
                Text("\(node.fileCount) 文件")
                Text("\(entries.count) 条知识")
                    .foregroundStyle(entries.isEmpty ? Color.orange : Color.secondary)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    /// 域标识。改名之后标题会变，只有这个 id 是稳定的，
    /// 用户要对着 `domains.locked.json` 核对时认的是它。
    private var facts: some View {
        Text(node.id)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // MARK: 结构事实

    @ViewBuilder
    private var packageSection: some View {
        if !node.packages.isEmpty {
            WikiSection(title: "归属包") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(node.packages.prefix(6), id: \.self) { package in
                        Text(package)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var ownerSection: some View {
        if !node.owner.authors.isEmpty || node.owner.manual != nil {
            WikiSection(title: "负责人") {
                VStack(alignment: .leading, spacing: 2) {
                    if let manual = node.owner.manual {
                        Text("人工指定：\(manual)")
                            .font(.system(size: 10))
                    }
                    ForEach(node.owner.authors.prefix(4), id: \.name) { author in
                        HStack(spacing: 6) {
                            Text(author.name)
                                .font(.system(size: 10, design: .monospaced))
                            Spacer()
                            Text("\(author.commits) 次")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var evidenceSection: some View {
        if !node.evidence.isEmpty {
            WikiSection(title: "判定依据") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(node.evidence.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            WikiChip(text: item.kind.title)
                            Text(item.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 2)
                            Text(String(format: "%.0f%%", item.weight * 100))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var moduleSection: some View {
        if !modules.isEmpty {
            WikiSection(title: "包含模块（\(modules.count)）") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(modules.prefix(12)) { module in
                        HStack(spacing: 6) {
                            Text(module.displayTitle)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                            Text("\(module.classCount) 类")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if modules.count > 12 {
                        Text("…还有 \(modules.count - 12) 个")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: 知识

    private var entrySection: some View {
        WikiSection(title: "知识条目（\(entries.count)）") {
            if entries.isEmpty {
                HStack(spacing: 6) {
                    Text("这个域还没有知识")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Button("生成草稿", action: onGenerate)
                        .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        Button {
                            onSelectEntry(entry.id)
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(WikiGraphView.color(for: entry.type))
                                    .frame(width: 6, height: 6)
                                Text(entry.displayTitle)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                if entry.isDraft {
                                    Text("草稿")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.quaternary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
