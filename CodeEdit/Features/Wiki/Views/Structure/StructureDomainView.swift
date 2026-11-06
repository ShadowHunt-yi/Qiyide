//
//  StructureDomainView.swift
//  CodeEdit
//
//  结构地图的第二级：一个域的全部模块。
//
//  全仓那一级每个域只露出最大的几个模块，这里才是完整清单。
//  每块带一条规模条：同一个域里谁大谁小，不用逐个读数字。
//

import SwiftUI

struct StructureDomainView: View {
    let domain: StructureDomain
    let index: StructureIndex
    var overlay: StructureOverlay?
    let onNavigate: ([String]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8, alignment: .top)]

    private var largest: Int {
        max(domain.modules.map(\.classCount).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(domain.modules) { module in
                    StructureTile(
                        title: module.title,
                        classCount: module.classCount,
                        ratio: Double(module.classCount) / Double(largest),
                        help: module.key,
                        isOutsideModel: !module.isModeled && !module.isRoot && domain.kind != .unassigned,
                        isNew: overlay?.diff.newModules.contains(module.id) == true,
                        marks: overlay?.diff.marks(module: module.id) ?? StructureMarks(),
                        pending: overlay?.pending([domain.id, module.id]) ?? 0,
                        isQuiet: overlay != nil
                    ) {
                        onNavigate([domain.id, module.id])
                    }
                }
            }
            if let overlay {
                removedModules(overlay.diff.removedModules(domain: domain.id))
                edgeList(overlay.diff.edges(touching: [domain.id]))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(domain.title)
                    .font(.system(size: 15, weight: .semibold))
                if let tag = domain.kind.tag {
                    WikiChip(text: tag)
                }
            }
            if !domain.keys.isEmpty {
                Text(domain.keys.joined(separator: ", "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let note = domain.kind.note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func removedModules(_ modules: [StructureRemovedModule]) -> some View {
        if !modules.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("本分支删光的模块")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(modules) { module in
                    Text(module.key)
                        .font(.system(size: 11.5, design: .monospaced))
                        .strikethrough()
                        .foregroundStyle(StructurePalette.deleted)
                }
            }
        }
    }

    /// 这个域牵涉到的依赖变化。跨域的已经在待确认里问过了；
    /// 域内模块之间的不打扰人，但在这里列出来，想看的时候看得到。
    @ViewBuilder
    private func edgeList(_ edges: [StructureEdgeChange]) -> some View {
        if !edges.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("这个域变化的依赖")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                Divider()
                ForEach(edges) { edge in
                    HStack(spacing: 6) {
                        Text(edge.kind == .added ? "+" : "−")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(edge.kind == .added ? StructurePalette.added : StructurePalette.deleted)
                        Text("\(name(edge.fromModule, edge.fromDomain)) → \(name(edge.toModule, edge.toDomain))")
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !edge.crossesDomains {
                            WikiChip(text: "域内")
                        }
                        Spacer(minLength: 4)
                        Text("\(edge.references.count) 处")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                }
            }
            .padding(.bottom, 4)
            .structureCard()
        }
    }

    /// 本域的模块只写模块名，别的域的带上域名。
    private func name(_ moduleID: String, _ domainID: String) -> String {
        let title = index.module(moduleID)?.title ?? moduleID.replacingOccurrences(of: "module:", with: "")
        guard domainID != domain.id else { return title }
        return "\(index.domain(domainID)?.title ?? domainID) › \(title)"
    }
}

/// 一个模块或子包的方块：包名、类数、规模条。
struct StructureTile: View {
    let title: String
    let classCount: Int
    let ratio: Double
    var help: String = ""
    /// 领域模型里没有这个包，是按路径规则归进来的。
    var isOutsideModel = false
    /// 本分支新出现的。
    var isNew = false
    var marks = StructureMarks()
    var pending = 0
    /// 正在叠加分支增量：没改动的方块压暗。
    var isQuiet = false
    let action: () -> Void

    @State private var isHovering = false

    private var isDimmed: Bool {
        isQuiet && marks.isEmpty && pending == 0
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if pending > 0 {
                        StructurePendingBadge(count: pending)
                    }
                }
                HStack(spacing: 5) {
                    Text("\(classCount) 个类")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isNew {
                        WikiChip(text: "新", color: StructurePalette.added)
                    }
                    if isOutsideModel && !isNew {
                        WikiChip(text: "模型外", color: .orange)
                            .help("领域模型里没有这个包，是按路径规则归进来的。通常是识别之后新加的。")
                    }
                    Spacer(minLength: 2)
                    StructureMarksLabel(marks: marks)
                }
                StructureSizeBar(ratio: ratio)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .structureCard(highlighted: isHovering || (isQuiet && !isDimmed))
        .opacity(isDimmed ? 0.62 : 1)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
