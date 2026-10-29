//
//  WikiGraphView.swift
//  CodeEdit
//
//  图谱画布：力导向布局的结果在这里被绘制与操作。
//
//  交互取舍：
//  - 节点半径不随缩放变化（保持可点、可读），只有坐标随缩放变化；
//  - 选中时高亮邻居、其余降到低透明度但不隐藏，保留上下文；
//  - 拖拽节点做的是「手动微调」，不改基础布局，刷新即复位。
//
//  性能取舍（这一版的重点）：
//  绘制是每帧都要跑的路径，一旦写错就会直接表现为「图谱很卡」。
//  旧实现有三个数量级上的浪费，现在都改掉了：
//  1. 每条边画一次 `context.stroke`——200 个节点 800 条边就是 800 次路径栅格化。
//     现在按「是否高亮 / 实线虚线」分桶，最多 4 次描边；节点按「类型 / 是否变暗」
//     分 12 桶，最多 12 次填充。
//  2. 按 id 取节点是 O(n) 线性查找（见 WikiGraph 的索引），现在全部 O(1)。
//  3. 视口外的节点和边照样画。现在先算屏幕坐标、顺带剔除，
//     放大后只看局部时开销和「看得到的东西」成正比。
//

import SwiftUI

struct WikiGraphView: View {

    let graph: WikiGraph
    @Binding var selection: String?

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var hovered: String?
    @State private var draggingNode: String?
    @State private var dragStartPoint: CGPoint = .zero
    @State private var nodeOffsets: [String: CGSize] = [:]
    @State private var lastDragTranslation: CGSize = .zero

    /// 一屏最多画多少个标签。超过这个数标签会糊成一片，反而看不清。
    private static let labelBudget = 150

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, canvasSize in
                draw(in: &context, size: canvasSize)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { location in
                selection = hitTest(location, size: size)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    // 命中没变就不要写 @State：鼠标每移动一像素都重绘一次整张图，
                    // 这是旧版「一动鼠标就卡」的直接原因。
                    let hit = hitTest(point, size: size)
                    if hit != hovered { hovered = hit }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
            .gesture(dragGesture(size: size))
            .simultaneousGesture(magnificationGesture)
            .overlay(alignment: .bottomLeading) { hint }
        }
    }

    // MARK: 手势

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingNode == nil && dragStartPoint == .zero {
                    dragStartPoint = value.startLocation
                    lastDragTranslation = .zero
                    if let node = hitTest(value.startLocation, size: size) {
                        draggingNode = node
                    } else {
                        panStart = offset
                    }
                }
                if let node = draggingNode {
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = value.translation
                    let current = nodeOffsets[node] ?? .zero
                    nodeOffsets[node] = CGSize(
                        width: current.width + delta.width,
                        height: current.height + delta.height
                    )
                } else {
                    offset = CGSize(
                        width: panStart.width + value.translation.width,
                        height: panStart.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                draggingNode = nil
                dragStartPoint = .zero
                lastDragTranslation = .zero
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(baseScale * value, 0.4), 4)
            }
            .onEnded { _ in
                baseScale = scale
            }
    }

    // MARK: 绘制

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let nodes = graph.nodes
        guard !nodes.isEmpty else { return }

        let layout = LayoutMetrics(size: size, scale: scale, offset: offset)
        let focus = selection ?? hovered
        let neighbors = focus.map { graph.neighbors(of: $0) } ?? []
        // 外扩一圈：节点有半径、标签在下方，贴着边的不能剔掉。
        let cullRect = CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)

        let count = nodes.count
        var points = [CGPoint](repeating: .zero, count: count)
        var onScreen = [Bool](repeating: false, count: count)
        let hasOffsets = !nodeOffsets.isEmpty

        for index in 0..<count {
            let node = nodes[index]
            let center = layout.point(
                node.position,
                nodeOffset: hasOffsets ? (nodeOffsets[node.id] ?? .zero) : .zero
            )
            points[index] = center
            onScreen[index] = cullRect.contains(center)
        }

        // MARK: 边（分桶 + 批量描边）

        // 桶的划分：先分「高亮 / 普通」，再分「实线 / 虚线」。
        var edgePaths = [Path](repeating: Path(), count: 4)
        let indexOf = graph.indexByID

        for edge in graph.edges {
            guard let from = indexOf[edge.from], let to = indexOf[edge.to] else { continue }
            // 两端都在视口外就跳过：力导向图里很少有边横穿整个视口而两端不可见。
            guard onScreen[from] || onScreen[to] else { continue }

            let isHot = focus.map { edge.from == $0 || edge.to == $0 } ?? false
            let bucket = (isHot ? 2 : 0) + (edge.isExplicit ? 0 : 1)
            edgePaths[bucket].move(to: points[from])
            edgePaths[bucket].addLine(to: points[to])
        }

        let plainColor = Color.secondary.opacity(focus == nil ? 0.28 : 0.12)
        let hotColor = Color.accentColor.opacity(0.85)
        context.stroke(edgePaths[0], with: .color(plainColor), lineWidth: 1)
        context.stroke(
            edgePaths[1],
            with: .color(plainColor),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        context.stroke(edgePaths[2], with: .color(hotColor), lineWidth: 1.6)
        context.stroke(
            edgePaths[3],
            with: .color(hotColor),
            style: StrokeStyle(lineWidth: 1.6, dash: [3, 3])
        )

        // MARK: 节点（按类型 / 明暗分桶）

        var fillPaths = [Path](repeating: Path(), count: 12)
        var rings: [(index: Int, style: RingStyle)] = []
        var labels: [(index: Int, center: CGPoint, radius: CGFloat, dimmed: Bool)] = []

        for index in 0..<count {
            guard onScreen[index] else { continue }
            let node = nodes[index]
            let center = points[index]
            let radius = nodeRadius(node)
            let isSelected = selection == node.id
            let isNeighbor = neighbors.contains(node.id)
            let isHovered = hovered == node.id
            let dimmed = focus != nil && !isSelected && !isNeighbor && !isHovered

            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            fillPaths[Self.typeIndex(node.type) * 2 + (dimmed ? 1 : 0)].addEllipse(in: rect)

            if isSelected || isHovered {
                rings.append((index, .focus))
            } else if isNeighbor {
                rings.append((index, .neighbor))
            } else if node.isDraft {
                rings.append((index, .draft(dimmed)))
            }

            let showsLabel = scale > 0.85 || isSelected || isNeighbor || isHovered
            if showsLabel {
                labels.append((index, center, radius, dimmed))
            }
        }

        let types = WikiEntryType.allCases
        for slot in 0..<12 {
            let path = fillPaths[slot]
            guard !path.isEmpty else { continue }
            let color = Self.color(for: types[slot / 2])
            let opacity: Double = slot % 2 == 0 ? 0.9 : 0.25
            context.fill(path, with: .color(color.opacity(opacity)))
        }

        // MARK: 描边（数量很少，可以逐个画）

        for ring in rings {
            let node = nodes[ring.index]
            let center = points[ring.index]
            let radius = nodeRadius(node)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            switch ring.style {
            case .focus:
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                    with: .color(Color.accentColor),
                    lineWidth: 2
                )
            case .neighbor:
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color.accentColor.opacity(0.6)),
                    lineWidth: 1.2
                )
            case .draft(let dimmed):
                // 草稿用虚线环：一眼能看出「这条是模型写的，还没人确认」。
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)),
                    with: .color(Color.orange.opacity(dimmed ? 0.35 : 0.9)),
                    style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])
                )
            }
        }

        // MARK: 标签

        drawLabels(labels, in: &context)
    }

    /// 标签是这一层最贵的绘制项：每个都要做一次文字布局。
    /// 所以先保证「选中/邻居」可见，剩下的按关联度数补到预算上限。
    private func drawLabels(
        _ labels: [(index: Int, center: CGPoint, radius: CGFloat, dimmed: Bool)],
        in context: inout GraphicsContext
    ) {
        guard !labels.isEmpty else { return }
        let nodes = graph.nodes

        var chosen: [(index: Int, center: CGPoint, radius: CGFloat, dimmed: Bool)]
        if labels.count <= Self.labelBudget {
            chosen = labels
        } else {
            // 度数高的先画：它们通常是域的中心，先保住信息量大的。
            let ranked = labels.sorted { graph.degree(of: nodes[$0.index].id) > graph.degree(of: nodes[$1.index].id) }
            chosen = Array(ranked.prefix(Self.labelBudget))
        }

        let selected = selection
        let hover = hovered
        for item in chosen {
            let node = nodes[item.index]
            // 选中的那条永远可读，用加粗和更实的颜色压在其他标签之上。
            let emphasized = hover == node.id || selected == node.id
            let text = Text(Self.shortTitle(node.label.isEmpty ? node.title : node.label))
                .font(.system(size: 10, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(
                    emphasized
                        ? Color.primary
                        : (item.dimmed ? Color.secondary.opacity(0.5) : Color.primary)
                )
            context.draw(
                text,
                at: CGPoint(x: item.center.x, y: item.center.y + item.radius + 3),
                anchor: .top
            )
        }
    }

    private enum RingStyle {
        case focus
        case neighbor
        case draft(Bool)
    }

    private var hint: some View {
        Text("滚轮或双指缩放 · 拖拽空白平移 · 拖拽节点微调")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(8)
    }

    private func nodeRadius(_ node: WikiNode) -> CGFloat {
        min(7 + CGFloat(node.degree) * 1.8, 20)
    }

    // MARK: 命中测试

    private func hitTest(_ location: CGPoint, size: CGSize) -> String? {
        let layout = LayoutMetrics(size: size, scale: scale, offset: offset)
        let hasOffsets = !nodeOffsets.isEmpty
        var best: (id: String, distance: CGFloat)?
        for node in graph.nodes {
            let center = layout.point(
                node.position,
                nodeOffset: hasOffsets ? (nodeOffsets[node.id] ?? .zero) : .zero
            )
            let dx = center.x - location.x
            let dy = center.y - location.y
            let reach = nodeRadius(node) + 6
            // 先用平方距离比，命中候选才开方，省掉一次 sqrt。
            let squared = dx * dx + dy * dy
            guard squared <= reach * reach else { continue }
            let distance = squared.squareRoot()
            if best == nil || distance < best!.distance {
                best = (node.id, distance)
            }
        }
        return best?.id
    }

    // MARK: 工具

    /// 长路径取末段：`.../agent/memory/mapper` 里有用的是 `mapper`，
    /// 截前 12 个字只会得到 `saas-plus-ai`，全仓库看起来都一样。
    private static func shortTitle(_ title: String) -> String {
        let last = (title as NSString).lastPathComponent
        let base = last.isEmpty ? title : last
        return base.count > 14 ? String(base.prefix(13)) + "…" : base
    }

    /// 填充分桶用的槽位。顺序必须和 `WikiEntryType.allCases` 一致。
    private static func typeIndex(_ type: WikiEntryType) -> Int {
        switch type {
        case .topic: return 0
        case .decision: return 1
        case .module: return 2
        case .rule: return 3
        case .term: return 4
        case .incident: return 5
        }
    }

    static func color(for type: WikiEntryType) -> Color {
        switch type {
        case .topic: return Color(red: 0.23, green: 0.54, blue: 0.85)
        case .decision: return Color(red: 0.33, green: 0.29, blue: 0.72)
        case .module: return Color(red: 0.06, green: 0.55, blue: 0.44)
        case .rule: return Color(red: 0.72, green: 0.46, blue: 0.09)
        case .term: return Color(red: 0.55, green: 0.55, blue: 0.53)
        case .incident: return Color(red: 0.76, green: 0.24, blue: 0.24)
        }
    }
}

/// 图坐标（[-1,1]）到屏幕坐标的换算，绘制与命中测试共用，避免两处公式漂移。
private struct LayoutMetrics {
    let size: CGSize
    let scale: CGFloat
    let offset: CGSize

    var base: CGFloat {
        min(size.width, size.height) * 0.42
    }

    func point(_ position: CGPoint, nodeOffset: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2 + offset.width + position.x * base * scale + nodeOffset.width,
            y: size.height / 2 + offset.height + position.y * base * scale + nodeOffset.height
        )
    }
}
