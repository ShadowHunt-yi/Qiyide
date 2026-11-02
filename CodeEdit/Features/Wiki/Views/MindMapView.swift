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
    @State var expanded: Set<String> = []
    /// 被「显示全部模块」放开的域（绕过单域模块上限）。
    @State var expandedAll: Set<String> = []
    @State var editingID: String?
    @State var editingTitle: String = ""

    // 视图变换：捏合/拖动过程中先存临时值，手势结束再并入最终值。
    @State var zoom: CGFloat = 1
    @State var pan: CGSize = .zero
    @State var pinchZoom: CGFloat = 1
    @State var dragPan: CGSize = .zero
    @State var fittedToken: String = ""

    @State var memo = MindMapLayoutMemo()

    private var graph: MindGraph { displayGraph ?? store.graph }

    var effectiveZoom: CGFloat { clampZoom(zoom * pinchZoom) }
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

    func clampZoom(_ value: CGFloat) -> CGFloat {
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

    func fit(_ layout: MindLayoutResult, size: CGSize, allowUpscale: Bool = true) {
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


