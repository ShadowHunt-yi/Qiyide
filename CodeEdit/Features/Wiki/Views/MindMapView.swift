//
//  MindMapView.swift
//  CodeEdit
//
//  领域建模的思维导图。根在中间，领域往两侧展开，模块再往外。
//
//  为什么不用 Canvas 一把梭（像 WikiGraphView 那样）：
//  图谱动辄几百个节点，必须自己画；导图只有 20 个上下，
//  每个节点用独立 View 反而更划算——右键菜单、双击改名、悬停提示
//  都是现成的，省掉一整套命中测试和手势分发。
//
//  布局取舍：不做力导向。导图的价值在于「层级可读」，
//  弹簧布局会把域和模块搅在一起，反而看不出从属关系。
//

import SwiftUI

// MARK: - 布局

/// 一次布局计算的结果。
struct MindPlacement: Identifiable {
    let id: String
    let node: MindNode
    let center: CGPoint
    /// 相对根节点的方向，决定连线从哪一侧出发。
    let side: Side

    enum Side { case root, left, right }

    var size: CGSize {
        switch node.kind {
        case .system: return CGSize(width: 200, height: 46)
        case .domain: return CGSize(width: 156, height: 42)
        case .subdomain: return CGSize(width: 140, height: 36)
        case .module, .shared: return CGSize(width: 132, height: 32)
        }
    }

    var rect: CGRect {
        CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

enum MindMapLayout {
    private static let rootGap: CGFloat = 220
    private static let levelGap: CGFloat = 190
    private static let domainRowGap: CGFloat = 26
    private static let moduleRowHeight: CGFloat = 40
    private static let domainBlockGap: CGFloat = 18

    /// 计算所有节点中心点。
    static func compute(
        graph: MindGraph,
        size: CGSize,
        expanded: Set<String>
    ) -> [MindPlacement] {
        guard !graph.isEmpty, size.width > 200, size.height > 160,
              let root = graph.root else { return [] }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var placements: [MindPlacement] = [
            MindPlacement(id: root.id, node: root, center: center, side: .root)
        ]

        // 根的直接子节点：域和共享依赖。按体量排序后前后对半分到两侧。
        let topLevel = graph.children(of: root.id).sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.classCount > rhs.classCount }
            return lhs.kind == .domain && rhs.kind != .domain
        }
        let half = (topLevel.count + 1) / 2
        let sides: [(nodes: [MindNode], dir: CGFloat, side: MindPlacement.Side)] = [
            (Array(topLevel.prefix(half)), -1, .left),
            (Array(topLevel.suffix(from: min(half, topLevel.count))), 1, .right)
        ]

        for group in sides where !group.nodes.isEmpty {
            placements.append(contentsOf: layoutSide(
                nodes: group.nodes,
                graph: graph,
                expanded: expanded,
                rootCenter: center,
                direction: group.dir,
                side: group.side,
                availableHeight: size.height
            ))
        }
        return placements
    }

    /// 一侧的垂直堆叠。每块的高度由「域自身」和「展开后的模块数」共同决定，
    /// 这样展开一个域时不会压到相邻的域。
    private static func layoutSide(
        nodes: [MindNode],
        graph: MindGraph,
        expanded: Set<String>,
        rootCenter: CGPoint,
        direction: CGFloat,
        side: MindPlacement.Side,
        availableHeight: CGFloat
    ) -> [MindPlacement] {
        struct Block {
            var node: MindNode
            var children: [MindNode]
            var height: CGFloat
        }

        var blocks: [Block] = nodes.map { node in
            let children = expanded.contains(node.id) ? graph.children(of: node.id) : []
            let childHeight = children.isEmpty
                ? 0
                : CGFloat(children.count) * moduleRowHeight + CGFloat(children.count - 1) * 4
            return Block(
                node: node,
                children: children,
                height: max(48, childHeight)
            )
        }

        let totalHeight = blocks.reduce(0) { $0 + $1.height }
            + CGFloat(max(0, blocks.count - 1)) * domainBlockGap
        var cursor = rootCenter.y - totalHeight / 2

        var result: [MindPlacement] = []
        for index in blocks.indices {
            let block = blocks[index]
            let blockCenterY = cursor + block.height / 2

            let domainX = rootCenter.x + direction * rootGap
            result.append(MindPlacement(
                id: block.node.id,
                node: block.node,
                center: CGPoint(x: domainX, y: blockCenterY),
                side: side
            ))

            // 模块在域的外侧继续向外排，垂直方向以域中心对称分布。
            if !block.children.isEmpty {
                let moduleX = domainX + direction * levelGap
                let startY = blockCenterY - block.height / 2 + moduleRowHeight / 2
                for (childIndex, child) in block.children.enumerated() {
                    result.append(MindPlacement(
                        id: child.id,
                        node: child,
                        center: CGPoint(
                            x: moduleX,
                            y: startY + CGFloat(childIndex) * (moduleRowHeight + 4)
                        ),
                        side: side
                    ))
                }
            }
            cursor += block.height + domainBlockGap
        }
        return result
    }
}

// MARK: - 视图

struct MindMapView: View {

    @ObservedObject var store: DomainModelStore
    @Binding var selection: String?
    /// 渲染用的图。传 nil 时用 `store.graph`（建模模式，可编辑）。
    /// 投影视图把 `ViewProjector` 的产物放这里，编辑依然作用于原模型。
    var displayGraph: MindGraph?
    /// 投影视图下只读：右键只保留查看类操作，避免在 `view:` 前缀的节点上改原模型。
    var isReadOnly: Bool = false
    /// 展开的域节点，模块只有展开后才画，避免一屏塞满。
    @State private var expanded: Set<String> = []
    @State private var editingID: String?
    @State private var editingTitle: String = ""

    private var graph: MindGraph { displayGraph ?? store.graph }

    var body: some View {
        GeometryReader { proxy in
            let placements = MindMapLayout.compute(
                graph: graph,
                size: proxy.size,
                expanded: expanded
            )

            ZStack(alignment: .topLeading) {
                if placements.isEmpty {
                    emptyHint
                } else {
                    connectionLayer(placements)
                    ForEach(placements) { placement in
                        nodeView(placement)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // 点空白处取消选中。
                selection = nil
                editingID = nil
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: graph.nodes.count) { _, _ in
            // 重新识别后旧的展开状态可能指向已不存在的节点，清掉。
            let alive = Set(graph.nodes.map(\.id))
            expanded.formIntersection(alive)
        }
    }

    // MARK: 连线

    private func connectionLayer(_ placements: [MindPlacement]) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.id, $0) })
        return Canvas { context, _ in
            for placement in placements {
                guard let parentID = placement.node.parentID,
                      let parent = byID[parentID] else { continue }
                var path = Path()
                let start = CGPoint(
                    x: parent.center.x + (placement.side == .left ? -parent.size.width / 2 : parent.size.width / 2),
                    y: parent.center.y
                )
                let end = CGPoint(
                    x: placement.center.x + (placement.side == .left ? placement.size.width / 2 : -placement.size.width / 2),
                    y: placement.center.y
                )
                // 水平切线的三次贝塞尔，读起来比直线更像「分支」。
                let midX = (start.x + end.x) / 2
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: midX, y: start.y),
                    control2: CGPoint(x: midX, y: end.y)
                )
                let isSharedBranch = placement.node.kind == .shared
                context.stroke(
                    path,
                    with: .color(isSharedBranch ? Color.orange.opacity(0.55) : Color.secondary.opacity(0.45)),
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: isSharedBranch ? [4, 3] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 节点

    @ViewBuilder
    private func nodeView(_ placement: MindPlacement) -> some View {
        let node = placement.node
        let isSelected = selection == node.id
        let children = graph.children(of: node.id)
        let isExpanded = expanded.contains(node.id)

        MindNodeCard(
            node: node,
            isSelected: isSelected,
            isExpanded: isExpanded,
            childCount: children.count,
            isEditing: editingID == node.id,
            editingTitle: $editingTitle,
            onCommitEdit: { commitEdit(node) }
        )
        .frame(width: placement.size.width, height: placement.size.height)
        .position(placement.center)
        .onTapGesture(count: 2) {
            if !children.isEmpty {
                if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } else {
                beginEdit(node)
            }
        }
        .onTapGesture {
            selection = node.id
        }
        .contextMenu {
            if isReadOnly {
                // 投影视图是只读快照：节点 id 带 `view:` 前缀，改它会影响不到原模型，
                // 所以这里只保留查看与展开，不给编辑入口。
                Button("查看判定依据") { selection = node.id }
                if !children.isEmpty {
                    Button(isExpanded ? "折叠模块" : "展开模块") {
                        if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
                    }
                }
            } else {
                Button("重命名…") { beginEdit(node) }
                if !children.isEmpty {
                    Button(isExpanded ? "折叠模块" : "展开模块") {
                        if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
                    }
                }
                Divider()
                if let owner = store.graph.node(node.id)?.owner, !owner.authors.isEmpty {
                    Section("负责人（按提交）") {
                        ForEach(owner.authors.prefix(4), id: \.name) { author in
                            Button("\(author.name) · \(author.commits) 次") {
                                store.assignOwner(node.id, to: author.name)
                            }
                        }
                    }
                    if owner.manual != nil {
                        Button("清除人工负责人") { store.assignOwner(node.id, to: nil) }
                    }
                    Divider()
                }
                Button(node.isShared ? "取消共享标记" : "标记为共享依赖") {
                    store.setShared(node.id, !node.isShared)
                }
                if node.kind != .domain && node.kind != .system {
                    Divider()
                    Menu("合并到领域…") {
                        ForEach(store.domains) { domain in
                            Button(domain.displayTitle) {
                                store.merge(node.id, into: domain.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func beginEdit(_ node: MindNode) {
        editingTitle = node.title
        editingID = node.id
    }

    private func commitEdit(_ node: MindNode) {
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != node.title {
            store.rename(node.id, to: trimmed)
        }
        editingID = nil
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("还没有领域模型")
                .font(.system(size: 13, weight: .medium))
            Text("点上方「识别领域」扫描代码结构，再用导图手工校正。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 节点卡片

private struct MindNodeCard: View {
    let node: MindNode
    let isSelected: Bool
    let isExpanded: Bool
    let childCount: Int
    let isEditing: Bool
    @Binding var editingTitle: String
    let onCommitEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isEditing {
                TextField("名称", text: $editingTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .onSubmit(onCommitEdit)
            } else {
                HStack(spacing: 4) {
                    Text(node.displayTitle)
                        .font(.system(size: node.kind == .system ? 13 : 12, weight: .medium))
                        .lineLimit(1)
                    if node.isManual {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if node.kind != .system {
                HStack(spacing: 4) {
                    Text("\(node.classCount) 类")
                    if let owner = ownerLabel {
                        Text("·")
                        Text(owner).lineLimit(1)
                    }
                    if childCount > 0 {
                        Text(isExpanded ? "· 已展开" : "· \(childCount) 模块")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .help(tooltip)
    }

    private var ownerLabel: String? {
        let name = node.owner.primary
        guard !name.isEmpty else { return nil }
        return name
    }

    private var tooltip: String {
        var lines = ["\(node.displayTitle) · \(node.classCount) 类 / \(node.fileCount) 文件"]
        if !node.packages.isEmpty {
            lines.append("包：" + node.packages.prefix(2).joined(separator: ", "))
        }
        if !node.owner.primary.isEmpty {
            lines.append("负责人：" + node.owner.primary)
        }
        for item in node.evidence.prefix(4) {
            lines.append("· [\(item.kind.title)] \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private var background: some ShapeStyle {
        switch node.kind {
        case .system, .domain:
            return AnyShapeStyle(Color.accentColor.opacity(isSelected ? 0.26 : 0.14))
        case .shared:
            return AnyShapeStyle(Color.orange.opacity(isSelected ? 0.26 : 0.13))
        case .module, .subdomain:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        switch node.kind {
        case .system, .domain: return Color.accentColor.opacity(0.55)
        case .shared: return Color.orange.opacity(0.6)
        case .module, .subdomain: return Color.secondary.opacity(0.3)
        }
    }
}
