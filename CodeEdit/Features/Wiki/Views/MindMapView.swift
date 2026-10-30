//
//  MindMapView.swift
//  CodeEdit
//
//  领域建模的思维导图。根在中间，领域往两侧展开，模块再往外。
//
//  为什么不用 Canvas 一把梭（像 WikiGraphView 那样）：
//  图谱动辄几百个节点，必须自己画；导图只有几十个，
//  每个节点用独立 View 反而更划算——右键菜单、双击改名、悬停提示
//  都是现成的，省掉一整套命中测试和手势分发。
//
//  布局取舍：不做力导向。导图的价值在于「层级可读」，
//  弹簧布局会把域和模块搅在一起，反而看不出从属关系。
//
//  可读性的三件事（这三件不做，图再准也没法用）：
//  1. 缩放/平移/适应窗口——模块一定比一屏宽，不能靠改窗口大小去凑；
//  2. 选中时高亮祖先链——「我在哪一层」必须一眼看出，所以要压暗无关分支；
//  3. 模块数量封顶——一个域挂 30 个模块会把整侧拉到屏外，
//     超过上限折叠成「还有 N 个模块」，点一下再全展开。
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
private struct MindLayoutKey: Equatable {
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
private final class MindMapLayoutMemo {
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

// MARK: - 视图

struct MindMapView: View {

    @ObservedObject var store: DomainModelStore
    @Binding var selection: String?
    /// 渲染用的图。传 nil 时用 `store.graph`（建模模式，可编辑）。
    /// 投影视图把 `ViewProjector` 的产物放这里，编辑依然作用于原模型。
    var displayGraph: MindGraph?
    /// 投影视图下只读：右键只保留查看类操作，避免在 `view:` 前缀的节点上改原模型。
    var isReadOnly: Bool = false
    /// 上游判断「换了一张图」的标记（模型 revision + 视角 id）。
    var graphToken: String = ""

    init(
        store: DomainModelStore,
        selection: Binding<String?>,
        displayGraph: MindGraph? = nil,
        isReadOnly: Bool = false,
        graphToken: String = "",
        initiallyExpanded: Set<String> = []
    ) {
        self.store = store
        self._selection = selection
        self.displayGraph = displayGraph
        self.isReadOnly = isReadOnly
        self.graphToken = graphToken
        // 初始展开只能在这里给：它是 @State 的初值，离屏渲染时 onAppear 不会跑。
        _expanded = State(initialValue: initiallyExpanded)
    }

    /// 展开的域节点，模块只有展开后才画，避免一屏塞满。
    @State private var expanded: Set<String> = []
    /// 被「显示全部模块」放开的域（绕过单域模块上限）。
    @State private var expandedAll: Set<String> = []
    @State private var editingID: String?
    @State private var editingTitle: String = ""

    // 视图变换：捏合/拖动过程中先存临时值，手势结束再并入最终值。
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var pinchZoom: CGFloat = 1
    @State private var dragPan: CGSize = .zero
    @State private var fittedToken: String = ""

    @State private var memo = MindMapLayoutMemo()

    private var graph: MindGraph { displayGraph ?? store.graph }

    private var effectiveZoom: CGFloat { clampZoom(zoom * pinchZoom) }
    private var effectivePan: CGSize {
        CGSize(width: pan.width + dragPan.width, height: pan.height + dragPan.height)
    }

    /// 选中节点的祖先链。非 nil 时无关分支压暗。
    private var highlightedIDs: Set<String>? {
        guard let selection, graph.node(selection) != nil else { return nil }
        return Set(graph.path(to: selection).map(\.id))
    }

    var body: some View {
        GeometryReader { proxy in
            let layoutKey = MindLayoutKey(
                size: proxy.size,
                token: graphToken + "|\(graph.nodes.count)",
                expanded: expanded,
                showAll: expandedAll
            )
            let layout = memo.result(for: layoutKey) {
                MindMapLayout.compute(
                    graph: graph,
                    size: proxy.size,
                    expanded: expanded,
                    showAll: expandedAll
                )
            }

            ZStack(alignment: .topLeading) {
                if layout.placements.isEmpty {
                    emptyHint
                } else {
                    panSurface
                    canvas(layout.placements)
                    legend
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(10)
                    zoomControls(layout, size: proxy.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(10)
                }
            }
            .onAppear {
                syncViewport(layoutKey: layoutKey, layout: layout, size: proxy.size)
            }
            .onChange(of: layoutKey) { _, newKey in
                syncViewport(layoutKey: newKey, layout: layout, size: proxy.size)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .onChange(of: graph.nodes.count) { _, _ in
            // 重新识别后旧的展开状态可能指向已不存在的节点，清掉。
            let alive = Set(graph.nodes.map(\.id))
            expanded.formIntersection(alive)
            expandedAll.formIntersection(alive)
        }
    }

    // MARK: 画布

    private func canvas(_ placements: [MindPlacement]) -> some View {
        let highlighted = highlightedIDs
        return ZStack(alignment: .topLeading) {
            connectionLayer(placements, highlighted: highlighted)
            ForEach(placements) { placement in
                nodeView(placement, highlighted: highlighted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(effectiveZoom)
        .offset(effectivePan)
    }

    /// 背景层：拖动平移、双指缩放、点击取消选中。
    ///
    /// 单独一层而不是挂在整张图上：节点的点击和高亮的 hover 都会被
    /// 上层手势吞掉，只有把平移放在最底层才互不干扰。
    private var panSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { dragPan = $0.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                        dragPan = .zero
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { pinchZoom = $0 }
                    .onEnded { value in
                        zoom = clampZoom(zoom * value)
                        pinchZoom = 1
                    }
            )
            .onTapGesture {
                selection = nil
                editingID = nil
            }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendItem(Color.accentColor.opacity(0.55), "领域")
            legendItem(Color.secondary.opacity(0.32), "模块")
            legendItem(Color.orange.opacity(0.6), "共享依赖")
            Text("拖动平移 · 双指缩放 · 双击展开")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .allowsHitTesting(false)
    }

    private func legendItem(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
                .frame(width: 9, height: 9)
            Text(text)
        }
    }

    private func zoomControls(_ layout: MindLayoutResult, size: CGSize) -> some View {
        HStack(spacing: 2) {
            MapChipButton(systemImage: "minus", help: "缩小") {
                zoom = clampZoom(zoom * 0.83)
                pinchZoom = 1
            }

            Text("\(Int((effectiveZoom * 100).rounded()))%")
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 32)

            MapChipButton(systemImage: "plus", help: "放大") {
                zoom = clampZoom(zoom * 1.2)
                pinchZoom = 1
            }

            Divider().frame(height: 11)

            MapChipButton(title: "适应", help: "缩放到能看见整棵树") {
                fit(layout, size: size)
            }
            MapChipButton(title: "复位", help: "回到 100% 并居中") {
                zoom = 1
                pan = .zero
                pinchZoom = 1
                dragPan = .zero
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }

    // MARK: 连线

    private func connectionLayer(_ placements: [MindPlacement], highlighted: Set<String>?) -> some View {
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
                // 高亮「根 → 选中节点」这条链，其余连线淡出。
                let onPath = highlighted.map {
                    $0.contains(placement.id) && $0.contains(parentID)
                } ?? true
                let opacity = onPath ? 1.0 : 0.22

                context.stroke(
                    path,
                    with: .color(
                        (isSharedBranch ? Color.orange.opacity(0.55) : Color.secondary.opacity(0.5))
                            .opacity(opacity)
                    ),
                    style: StrokeStyle(
                        lineWidth: onPath && highlighted != nil ? 1.6 : 1,
                        dash: isSharedBranch ? [4, 3] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 节点

    @ViewBuilder
    private func nodeView(_ placement: MindPlacement, highlighted: Set<String>?) -> some View {
        let node = placement.node
        let isSelected = selection == node.id
        let children = graph.children(of: node.id)
        let isExpanded = expanded.contains(node.id)
        let dimmed = highlighted.map { !$0.contains(node.id) } ?? false

        MindNodeCard(
            node: node,
            isSelected: isSelected,
            isExpanded: isExpanded,
            childCount: children.count,
            isSummary: placement.isSummary,
            hiddenCount: placement.hiddenCount,
            isEditing: editingID == node.id,
            editingTitle: $editingTitle,
            onCommitEdit: { commitEdit(node) }
        )
        .frame(width: placement.size.width, height: placement.size.height)
        .opacity(dimmed ? 0.34 : 1)
        .position(placement.center)
        .onTapGesture(count: 2) {
            if placement.isSummary {
                expandAll(placement)
            } else if !children.isEmpty {
                if isExpanded { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } else {
                beginEdit(node)
            }
        }
        .onTapGesture {
            if placement.isSummary {
                expandAll(placement)
            } else {
                selection = node.id
            }
        }
        .contextMenu {
            if placement.isSummary {
                Button("显示全部 \(placement.hiddenCount) 个模块") { expandAll(placement) }
            } else if isReadOnly {
                // 投影视图是只读快照：节点 id 带 `view:` 前缀，改它会影响不到原模型，
                // 所以这里只保留查看与展开，不给编辑入口。
                Button("查看判定依据") { selection = node.id }
                if !children.isEmpty {
                    Button(isExpanded ? "折叠模块" : "展开模块") { toggleExpand(node.id, isExpanded) }
                }
            } else {
                Button("重命名…") { beginEdit(node) }
                if !children.isEmpty {
                    Button(isExpanded ? "折叠模块" : "展开模块") { toggleExpand(node.id, isExpanded) }
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

    private func toggleExpand(_ id: String, _ isExpanded: Bool) {
        if isExpanded {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    /// 汇总卡：放开单域模块上限，并把该域展开。
    private func expandAll(_ placement: MindPlacement) {
        guard let domainID = placement.node.parentID else { return }
        expandedAll.insert(domainID)
        expanded.insert(domainID)
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

    // MARK: 视图变换

    private func clampZoom(_ value: CGFloat) -> CGFloat {
        min(2.5, max(0.35, value))
    }

    /// 让视口跟着布局走。
    ///
    /// 两条规则：
    /// - 换图（首次显示 / 切视角 / 重新识别）：适配一次，但**不放大**——
    ///   小树放大到 130% 只会让下一次展开时又缩回去，画面一直在跳；
    /// - 展开/折叠：只在「已经装不下」时缩小。用户手动放大过的比例要保住，
    ///   否则点开一个模块，整张图就自己缩回去了。
    private func syncViewport(layoutKey: MindLayoutKey, layout: MindLayoutResult, size: CGSize) {
        guard !layout.placements.isEmpty else { return }

        if fittedToken != layoutKey.token {
            fittedToken = layoutKey.token
            fit(layout, size: size, allowUpscale: false)
            return
        }

        let bounds = layout.contentBounds
        let overflow = max(
            bounds.width / max(1, size.width - 20),
            bounds.height / max(1, size.height - 20)
        )
        if overflow * zoom > 1.02 {
            fit(layout, size: size, allowUpscale: false)
        }
    }

    private func fit(_ layout: MindLayoutResult, size: CGSize, allowUpscale: Bool = true) {
        let bounds = layout.contentBounds
        guard !layout.placements.isEmpty, bounds.width > 8, bounds.height > 8,
              size.width > 8, size.height > 8 else { return }

        // 留 20pt 边距，避免卡片贴着窗口边缘看不清描边。
        var target = clampZoom(min(
            (size.width - 20) / bounds.width,
            (size.height - 20) / bounds.height
        ))
        if allowUpscale { target = min(target, 1.6) } else { target = min(target, 1) }
        zoom = target
        pinchZoom = 1

        // scaleEffect 以画布中心为锚点，所以要把内容包围盒的中心拉到画布中心。
        let canvasCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        pan = CGSize(
            width: -(bounds.midX - canvasCenter.x) * target,
            height: -(bounds.midY - canvasCenter.y) * target
        )
        dragPan = .zero
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

// MARK: - 浮动控件

/// 自绘的小按钮。
///
/// 不用 `Button`：它在这里既会带出焦点环，也让离屏渲染（ImageRenderer）
/// 画不出内容、退化成占位符。三个内联样式（图标 / 文字 / hover 底色）
/// 完全够用，还能和自绘的导图保持同一套视觉。
private struct MapChipButton: View {
    var systemImage: String?
    var title: String?
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            } else if let title {
                Text(title).font(.system(size: 10))
            }
        }
        .foregroundStyle(hovering ? .primary : .secondary)
        .frame(width: title == nil ? 16 : nil, height: 16)
        .padding(.horizontal, title == nil ? 0 : 5)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(hovering ? Color.secondary.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(help)
    }
}
