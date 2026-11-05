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
    let onNavigate: ([String]) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8, alignment: .top)]

    private var largest: Int {
        max(domain.modules.map(\.classCount).max() ?? 1, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(domain.modules) { module in
                        StructureTile(
                            title: module.title,
                            classCount: module.classCount,
                            ratio: Double(module.classCount) / Double(largest),
                            help: module.key,
                            isOutsideModel: !module.isModeled && !module.isRoot && domain.kind != .unassigned
                        ) {
                            onNavigate([domain.id, module.id])
                        }
                    }
                }
            }
            .padding(12)
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
}

/// 一个模块或子包的方块：包名、类数、规模条。
struct StructureTile: View {
    let title: String
    let classCount: Int
    let ratio: Double
    var help: String = ""
    /// 领域模型里没有这个包，是按路径规则归进来的。
    var isOutsideModel = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Text("\(classCount) 个类")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isOutsideModel {
                        WikiChip(text: "模型外", color: .orange)
                            .help("领域模型里没有这个包，是按路径规则归进来的。通常是识别之后新加的。")
                    }
                }
                StructureSizeBar(ratio: ratio)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .structureCard(highlighted: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
