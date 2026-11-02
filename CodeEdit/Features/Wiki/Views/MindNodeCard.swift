//
//  MindNodeCard.swift
//  CodeEdit
//
//  导图里的一张卡片：标题、类型符号、类数与文件数、展开/编辑入口。
//
//  自绘而不是用 List/Table 的一行：卡片要能压在画布上、跟着缩放走，
//  还要在离屏渲染（ImageRenderer）里画出来——系统控件在那种场景会退化成占位符。
//

import SwiftUI

// MARK: - 节点卡片

struct MindNodeCard: View {
    let node: MindNode
    let isSelected: Bool
    let isExpanded: Bool
    let childCount: Int
    let isSummary: Bool
    let hiddenCount: Int
    let isEditing: Bool
    @Binding var editingTitle: String
    let onCommitEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow
            if showsMeta {
                metaRow
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .overlay {
            if isSummary {
                // 汇总卡用虚线：一眼看出「这不是一个真实模块」。
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(borderColor, lineWidth: isSelected ? 1.6 : 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .help(tooltip)
    }

    private var showsMeta: Bool {
        !isSummary && node.kind != .system
    }

    @ViewBuilder
    private var titleRow: some View {
        if isEditing {
            TextField("名称", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .onSubmit(onCommitEdit)
        } else {
            HStack(spacing: 5) {
                if let symbol = kindSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 11)
                }
                Text(node.displayTitle)
                    .font(.system(size: node.kind == .system ? 13.5 : 12, weight: weight))
                    .lineLimit(1)
                    // 长包名宁可略缩也不截断：模块名一旦变成「infer…」就分不清了。
                    .minimumScaleFactor(0.82)
                    .truncationMode(node.kind == .module ? .middle : .tail)
                if node.isManual && !isSummary {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 元信息只留「规模」。
    ///
    /// 不显示负责人：一个域名加「647 类 · ext.xiaoshengyu5」在 168pt 宽里
    /// 必然要截断成「ext.x…yu5」，比不显示更糟。负责人在悬停提示、
    /// 右侧详情、以及「团队归属图」里都有，图上只看规模就够。
    private var metaRow: some View {
        HStack(spacing: 4) {
            Text("\(node.classCount) 类")
            if childCount > 0 {
                Text("·")
                Text(isExpanded ? "已展开" : "\(childCount) 模块")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var weight: Font.Weight {
        switch node.kind {
        case .system, .domain: return .semibold
        default: return .regular
        }
    }

    /// 类型图标。模块不画——模块占绝大多数，每个都带图标只会变成噪声。
    private var kindSymbol: String? {
        if isSummary { return "chevron.down" }
        switch node.kind {
        case .system: return "shippingbox.fill"
        case .domain: return "square.stack.3d.up.fill"
        case .subdomain: return "square.stack.3d.up"
        case .shared: return "link"
        case .module: return nil
        }
    }

    private var tooltip: String {
        var lines = ["\(node.displayTitle) · \(node.classCount) 类 / \(node.fileCount) 文件"]
        if !node.packages.isEmpty {
            lines.append("包：" + node.packages.prefix(2).joined(separator: ", "))
        }
        if !node.owner.primary.isEmpty {
            lines.append("负责人：" + node.owner.primary)
            let others = node.owner.authors.dropFirst().prefix(2).map { "\($0.name) \($0.commits)" }
            if !others.isEmpty { lines.append("其他：" + others.joined(separator: "、")) }
        }
        for item in node.evidence.prefix(4) {
            lines.append("· [\(item.kind.title)] \(item.detail)")
        }
        if isSummary {
            lines.append("点一下展开全部 \(hiddenCount) 个模块")
        }
        return lines.joined(separator: "\n")
    }

    private var accent: Color {
        if isSummary { return Color.secondary.opacity(0.6) }
        switch node.kind {
        case .system: return .accentColor
        case .domain: return Color.accentColor.opacity(0.85)
        case .shared: return .orange
        case .subdomain, .module: return Color.secondary.opacity(0.5)
        }
    }

    private var background: some ShapeStyle {
        if isSummary {
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 1 : 0.7))
        }
        switch node.kind {
        case .system, .domain:
            return AnyShapeStyle(Color.accentColor.opacity(isSelected ? 0.24 : 0.12))
        case .shared:
            return AnyShapeStyle(Color.orange.opacity(isSelected ? 0.24 : 0.12))
        case .module, .subdomain:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isSummary { return Color.secondary.opacity(0.4) }
        switch node.kind {
        case .system, .domain: return Color.accentColor.opacity(0.5)
        case .shared: return Color.orange.opacity(0.55)
        case .module, .subdomain: return Color.secondary.opacity(0.28)
        }
    }
}
