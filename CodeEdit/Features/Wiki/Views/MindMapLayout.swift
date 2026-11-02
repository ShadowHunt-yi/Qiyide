//
//  MindMapLayout.swift
//  CodeEdit
//
//  导图的几何布局：把一棵域/模块树摊成一组带坐标的卡片。
//
//  这里是纯计算——输入「树 + 画布尺寸 + 展开状态」，输出 placement 数组，
//  不碰任何 SwiftUI 类型。抽出来的好处不只是文件变短：
//  布局能单独写测试、能在后台算，也不会因为改一个卡片样式就动到这段。
//

import CoreGraphics
import Foundation

// MARK: - 布局

/// 一次布局计算的结果。
struct MindPlacement: Identifiable {
    let id: String
    let node: MindNode
    let center: CGPoint
    /// 相对根节点的方向，决定连线从哪一侧出发。
    let side: Side
    /// 「还有 N 个模块」这类占位卡：不可编辑，点一下展开全部。
    var isSummary: Bool = false
    var hiddenCount: Int = 0

    enum Side { case root, left, right }

    var size: CGSize {
        if isSummary { return CGSize(width: 136, height: 28) }
        switch node.kind {
        case .system: return CGSize(width: 208, height: 52)
        case .domain: return CGSize(width: 168, height: 48)
        case .subdomain: return CGSize(width: 152, height: 40)
        case .module, .shared: return CGSize(width: 148, height: 34)
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

/// 布局结果：节点位置 + 内容包围盒（供「适应窗口」计算缩放）。
struct MindLayoutResult {
    var placements: [MindPlacement] = []
    var contentBounds: CGRect = .zero

    static let empty = MindLayoutResult()
}

enum MindMapLayout {
    /// 单个域最多直接画多少个模块，其余折叠成汇总卡。
    ///
    /// 10 而不是「越多越好」：一个域 20 个模块排成竖列就是 760pt，
    /// 三个这样的域并排，整张图必然被压到看不清字。
    static let maxVisibleModules = 10

    private static let rootGap: CGFloat = 210
    private static let levelGap: CGFloat = 180
    private static let domainBlockGap: CGFloat = 20
    /// 模块行高 = 卡片 34 + 行距 4。
    private static let moduleRow: CGFloat = 38
    private static let minBlockHeight: CGFloat = 58
    private static let contentPadding: CGFloat = 28
    /// 两侧高度差超过这个倍数才重新分配，避免展开一个域就让整棵树换边。
    private static let imbalanceLimit: CGFloat = 1.6

    /// 计算所有节点中心点。
    static func compute(
        graph: MindGraph,
        size: CGSize,
        expanded: Set<String>,
        showAll: Set<String> = []
    ) -> MindLayoutResult {
        guard !graph.isEmpty, size.width > 240, size.height > 200,
              let root = graph.root else { return .empty }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var placements: [MindPlacement] = [
            MindPlacement(id: root.id, node: root, center: center, side: .root)
        ]

        // 根的直接子节点：域和共享依赖。按体量降序后**按序号交错**分配到两侧。
        //
        // 为什么是交错而不是「对半分」：对半分的边界会随节点数变化，
        // 展开一个域（模块数变化不影响节点数，但合并/新增域会）就可能让整棵树换边。
        // 交错分配只看序号，展开/折叠时不移动任何其它域，视线不用重新建立。
        let topLevel = graph.children(of: root.id).sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.classCount > rhs.classCount }
            return lhs.kind == .domain && rhs.kind != .domain
        }

        var leftNodes: [MindNode] = []
        var rightNodes: [MindNode] = []
        for (index, node) in topLevel.enumerated() {
            if index.isMultiple(of: 2) { leftNodes.append(node) } else { rightNodes.append(node) }
        }
        rebalance(
            left: &leftNodes,
            right: &rightNodes,
            graph: graph,
            expanded: expanded,
            showAll: showAll
        )

        for (nodes, direction, side) in [
            (leftNodes, CGFloat(-1), MindPlacement.Side.left),
            (rightNodes, CGFloat(1), MindPlacement.Side.right)
        ] where !nodes.isEmpty {
            placements.append(contentsOf: layoutSide(
                nodes: nodes,
                graph: graph,
                expanded: expanded,
                showAll: showAll,
                rootCenter: center,
                direction: direction,
                side: side,
                availableHeight: size.height - contentPadding * 2
            ))
        }

        return MindLayoutResult(
            placements: placements,
            contentBounds: boundingBox(of: placements)
        )
    }

    /// 一侧的垂直堆叠。每块的高度由「域自身」和「展开后的模块数」共同决定，
    /// 这样展开一个域时不会压到相邻的域。
    private static func layoutSide(
        nodes: [MindNode],
        graph: MindGraph,
        expanded: Set<String>,
        showAll: Set<String>,
        rootCenter: CGPoint,
        direction: CGFloat,
        side: MindPlacement.Side,
        availableHeight: CGFloat
    ) -> [MindPlacement] {
        struct Block {
            var node: MindNode
            var children: [MindNode]
            var hidden: Int
            var height: CGFloat
        }

        let blocks: [Block] = nodes.map { node in
            let (visible, hidden) = visibleChildren(
                of: node, graph: graph, expanded: expanded, showAll: showAll
            )
            return Block(
                node: node,
                children: visible,
                hidden: hidden,
                height: blockHeight(children: visible.count, hidden: hidden)
            )
        }

        let contentHeight = blocks.reduce(0) { $0 + $1.height }
        var gap = domainBlockGap
        let gaps = CGFloat(max(0, blocks.count - 1))
        if gaps > 0, contentHeight + gaps * gap > availableHeight {
            // 挤不下时只压缩间距，不压卡片——卡片一变矮文字就截断了。
            gap = max(2, (availableHeight - contentHeight) / gaps)
        }

        let totalHeight = contentHeight + gaps * gap
        var cursor = rootCenter.y - totalHeight / 2

        var result: [MindPlacement] = []
        for block in blocks {
            let blockCenterY = cursor + block.height / 2
            let domainX = rootCenter.x + direction * rootGap

            result.append(MindPlacement(
                id: block.node.id,
                node: block.node,
                center: CGPoint(x: domainX, y: blockCenterY),
                side: side
            ))

            // 模块在域的外侧继续向外排，垂直方向以域中心对称分布。
            if !block.children.isEmpty || block.hidden > 0 {
                let moduleX = domainX + direction * levelGap
                let startY = blockCenterY - block.height / 2 + moduleRow / 2

                for (childIndex, child) in block.children.enumerated() {
                    result.append(MindPlacement(
                        id: child.id,
                        node: child,
                        center: CGPoint(
                            x: moduleX,
                            y: startY + CGFloat(childIndex) * moduleRow
                        ),
                        side: side
                    ))
                }

                if block.hidden > 0 {
                    let summaryID = "summary:" + block.node.id
                    var summaryNode = MindNode(
                        id: summaryID,
                        title: "还有 \(block.hidden) 个模块",
                        kind: .module
                    )
                    summaryNode.parentID = block.node.id
                    result.append(MindPlacement(
                        id: summaryID,
                        node: summaryNode,
                        center: CGPoint(
                            x: moduleX,
                            y: startY + CGFloat(block.children.count) * moduleRow
                        ),
                        side: side,
                        isSummary: true,
                        hiddenCount: block.hidden
                    ))
                }
            }
            cursor += block.height + gap
        }
        return result
    }

    private static func boundingBox(of placements: [MindPlacement]) -> CGRect {
        guard let first = placements.first else { return .zero }
        var box = first.rect
        for placement in placements.dropFirst() {
            box = box.union(placement.rect)
        }
        return box
    }

    /// 一个域实际画出哪些模块、折叠了几个。
    private static func visibleChildren(
        of node: MindNode,
        graph: MindGraph,
        expanded: Set<String>,
        showAll: Set<String>
    ) -> (children: [MindNode], hidden: Int) {
        guard expanded.contains(node.id) else { return ([], 0) }
        let all = graph.children(of: node.id)
        guard all.count > maxVisibleModules, !showAll.contains(node.id) else {
            return (all, 0)
        }
        return (Array(all.prefix(maxVisibleModules)), all.count - maxVisibleModules)
    }

    /// 块高度：模块行数决定高度，汇总卡也算一行。
    private static func blockHeight(children: Int, hidden: Int) -> CGFloat {
        let rows = children + (hidden > 0 ? 1 : 0)
        guard rows > 0 else { return minBlockHeight }
        return max(minBlockHeight, CGFloat(rows) * moduleRow - 4)
    }

    /// 两侧高度失衡时，把「挪过去能让差值最小」的块换边。
    ///
    /// 为什么需要：模块只挂在被识别为域的节点下，实测本仓库三个有模块的域
    /// 全落在同一侧——一侧 1400pt、另一侧 230pt，只能靠缩小整张图去妥协，
    /// 字就没了。这里只在失衡超过 1.6 倍时动手，正常展开不动布局，
    /// 避免「点开一个模块，整棵树跳边」。
    private static func rebalance(
        left: inout [MindNode],
        right: inout [MindNode],
        graph: MindGraph,
        expanded: Set<String>,
        showAll: Set<String>
    ) {
        guard !left.isEmpty, !right.isEmpty else { return }

        func columnHeight(_ nodes: [MindNode]) -> CGFloat {
            let total = nodes.reduce(CGFloat(0)) { partial, node in
                let (visible, hidden) = visibleChildren(
                    of: node, graph: graph, expanded: expanded, showAll: showAll
                )
                return partial + blockHeight(children: visible.count, hidden: hidden)
            }
            return total + CGFloat(max(0, nodes.count - 1)) * domainBlockGap
        }

        for _ in 0..<3 {
            let leftHeight = columnHeight(left)
            let rightHeight = columnHeight(right)
            let maxHeight = max(leftHeight, rightHeight)
            let minHeight = max(1, min(leftHeight, rightHeight))
            guard maxHeight / minHeight > imbalanceLimit else { return }

            let heavyIsLeft = leftHeight > rightHeight
            let heavy = heavyIsLeft ? left : right
            let lightHeight = heavyIsLeft ? rightHeight : leftHeight

            // 找一个块：挪过去后两侧的最大值最小。
            var bestIndex: Int?
            var bestPeak = maxHeight
            for (index, node) in heavy.enumerated() {
                let (visible, hidden) = visibleChildren(
                    of: node, graph: graph, expanded: expanded, showAll: showAll
                )
                let height = blockHeight(children: visible.count, hidden: hidden)
                let heavyAfter = maxHeight - height
                let peak = max(heavyAfter, lightHeight + height)
                if peak < bestPeak {
                    bestPeak = peak
                    bestIndex = index
                }
            }
            guard let index = bestIndex else { return }

            let moved = heavy[index]
            if heavyIsLeft {
                left.remove(at: index)
                right.append(moved)
                right.sort { $0.classCount > $1.classCount }
            } else {
                right.remove(at: index)
                left.append(moved)
                left.sort { $0.classCount > $1.classCount }
            }
        }
    }
}

// MARK: - 布局缓存

/// 布局的缓存键。任何一项变化都要重算，其余情况直接用上次结果。
struct MindLayoutKey: Equatable {
    var width: CGFloat
    var height: CGFloat
    var token: String
    var expanded: Set<String>
    var showAll: Set<String>

    init(size: CGSize, token: String, expanded: Set<String>, showAll: Set<String>) {
        // 尺寸取到 0.5 点，避免拖拽窗口时每像素都重算一次。
        width = (size.width * 2).rounded() / 2
        height = (size.height * 2).rounded() / 2
        self.token = token
        self.expanded = expanded
        self.showAll = showAll
    }
}

/// 纯缓存对象：在 body 里被读写，但不参与 SwiftUI 的状态比较。
///
/// 为什么需要它：缩放/平移会高频触发 body 重算，而布局本身只跟
/// 「图、尺寸、展开状态」有关。没有这层缓存时，捏合缩放的每一帧
/// 都会重新遍历整棵树并分配上百个 placement。
final class MindMapLayoutMemo {
    private var key: MindLayoutKey?
    private var cached: MindLayoutResult = .empty

    func result(for key: MindLayoutKey, compute: () -> MindLayoutResult) -> MindLayoutResult {
        if self.key == key { return cached }
        let value = compute()
        self.key = key
        cached = value
        return value
    }
}
