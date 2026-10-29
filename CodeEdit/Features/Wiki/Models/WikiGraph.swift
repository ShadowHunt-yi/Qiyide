//
//  WikiGraph.swift
//  CodeEdit
//
//  知识图谱：节点、边，以及确定性布局。
//
//  布局必须可复现：同一份数据每次打开位置一致，否则用户的空间记忆失效，
//  图就退化成一张每次都不一样的装饰画。因此初始位置由 id 的稳定散列决定，
//  迭代过程不带随机数。
//

import CoreGraphics
import Foundation

// MARK: - 节点与边

struct WikiNode: Identifiable, Hashable {
    let id: String
    var title: String
    /// 图上标签用的短名：完整路径在画布上挤成一团，取末两段即可辨认。
    var label: String = ""
    var type: WikiEntryType
    var degree: Int
    var position: CGPoint
    /// AI 起草、待人确认的节点在图上用虚线环标出。
    var isDraft: Bool = false
}

struct WikiEdge: Identifiable, Hashable {
    let id: String
    let from: String
    let to: String
    /// 关系词（属于/导致/依赖…）或「提及」。
    let kind: String
    /// 来自前置声明的关系为 true，来自正文 `[[链接]]` 的为 false。
    let isExplicit: Bool
}

/// 图谱数据 + 预建索引。
///
/// 为什么要预建索引：
/// 图谱每帧要按 id 取节点坐标（每条边两次）、取某节点的邻居、取某节点的度数。
/// 第一版全部用 `nodes.first { $0.id == id }`，是 O(n) 线性查找——
/// 232 个节点、800+ 条边，一帧就是三十多万次字符串比较，滚动和 hover 直接卡死。
/// 左侧列表每行还要再调一次 `node(id)`，整体退化成 O(n²)。
///
/// 现在索引在构造时算一次（只在数据变更时发生），绘制热路径全部 O(1)。
struct WikiGraph {
    private(set) var nodes: [WikiNode] = []
    private(set) var edges: [WikiEdge] = []

    private(set) var nodesByID: [String: WikiNode] = [:]
    /// id → 在 `nodes` 里的下标。绘制时要按下标复用预计算的屏幕坐标。
    private(set) var indexByID: [String: Int] = [:]
    /// 邻接表：悬停高亮时不再全量扫边。
    private(set) var neighborsByID: [String: Set<String>] = [:]
    /// 节点 → 相接边的下标（用下标数组，比存边副本省内存）。
    private(set) var edgeIndexesByNode: [String: [Int]] = [:]

    static let empty = WikiGraph()

    init(nodes: [WikiNode] = [], edges: [WikiEdge] = []) {
        self.nodes = nodes
        self.edges = edges

        var byID: [String: WikiNode] = [:]
        byID.reserveCapacity(nodes.count)
        var indexOf: [String: Int] = [:]
        indexOf.reserveCapacity(nodes.count)
        for (index, node) in nodes.enumerated() {
            byID[node.id] = node
            indexOf[node.id] = index
        }
        self.nodesByID = byID
        self.indexByID = indexOf

        var neighbors: [String: Set<String>] = [:]
        var touching: [String: [Int]] = [:]
        neighbors.reserveCapacity(min(nodes.count, 512))
        touching.reserveCapacity(min(nodes.count, 512))
        for (index, edge) in edges.enumerated() {
            neighbors[edge.from, default: []].insert(edge.to)
            neighbors[edge.to, default: []].insert(edge.from)
            touching[edge.from, default: []].append(index)
            touching[edge.to, default: []].append(index)
        }
        self.neighborsByID = neighbors
        self.edgeIndexesByNode = touching
    }

    func node(_ id: String) -> WikiNode? {
        nodesByID[id]
    }

    /// 列表行要显示「N 个关联」，放在 body 里逐行调用，必须 O(1)。
    func degree(of id: String) -> Int {
        edgeIndexesByNode[id]?.count ?? 0
    }

    func neighbors(of id: String) -> Set<String> {
        neighborsByID[id] ?? []
    }

    func edges(touching id: String) -> [WikiEdge] {
        (edgeIndexesByNode[id] ?? []).map { edges[$0] }
    }
}

// MARK: - 布局

enum WikiLayout {

    /// 力导向布局，坐标归一化到 [-1, 1]。
    ///
    /// 这是知识库最热的计算路径：条目每变一次就要重算一遍。
    /// 第一版全程用 `[String: CGPoint]` 做累加，每帧上万次字符串哈希，
    /// 159 个节点要一秒多——于是建档时每写一条就卡一次。
    ///
    /// 现在改成索引数组：id→下标只建一次，之后全部是浮点数组运算。
    /// 同样的确定性（不引入随机数），但没有字符串哈希。
    static func compute(nodes: [String], edges: [(String, String)]) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        if nodes.count == 1 { return [nodes[0]: .zero] }

        let count = nodes.count
        var indexOf: [String: Int] = [:]
        indexOf.reserveCapacity(count)
        for (index, id) in nodes.enumerated() { indexOf[id] = index }

        // 边转成下标对，顺带丢掉指向未知节点的边。
        var pairs: [(Int, Int)] = []
        pairs.reserveCapacity(edges.count)
        for (a, b) in edges {
            guard let i = indexOf[a], let j = indexOf[b], i != j else { continue }
            pairs.append((i, j))
        }

        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        var dxs = [Double](repeating: 0, count: count)
        var dys = [Double](repeating: 0, count: count)

        // 初始位置：黄金角螺旋 + 稳定哈希抖动，保证同一份数据每次一致。
        for index in 0..<count {
            let start = initialPosition(index: index, count: count, id: nodes[index])
            xs[index] = start.x
            ys[index] = start.y
        }

        let area = 4.0
        let k = (area / Double(count)).squareRoot()
        // 规模越大迭代越少：力导向的收敛在前几十轮就基本完成，
        // 继续迭代只是让主线程多等，肉眼分辨不出差别。
        let iterations: Int
        switch count {
        case ...120: iterations = 320
        case ...300: iterations = 160
        case ...600: iterations = 80
        default: iterations = 40
        }
        var temperature = 0.12

        for _ in 0..<iterations {
            for index in 0..<count {
                dxs[index] = 0
                dys[index] = 0
            }

            // 斥力 O(n²)
            for i in 0..<count {
                let xi = xs[i]
                let yi = ys[i]
                for j in (i + 1)..<count {
                    var dx = xi - xs[j]
                    var dy = yi - ys[j]
                    var distance = (dx * dx + dy * dy).squareRoot()
                    if distance < 0.001 {
                        dx = 0.001 * Double((i % 3) - 1)
                        dy = 0.001 * Double((j % 3) - 1)
                        distance = 0.0015
                    }
                    let force = (k * k) / distance
                    let ux = dx / distance
                    let uy = dy / distance
                    dxs[i] += ux * force
                    dys[i] += uy * force
                    dxs[j] -= ux * force
                    dys[j] -= uy * force
                }
            }

            // 引力（仅有边相连的节点对）
            for (i, j) in pairs {
                let dx = xs[i] - xs[j]
                let dy = ys[i] - ys[j]
                let distance = max((dx * dx + dy * dy).squareRoot(), 0.0001)
                let force = (distance * distance) / k
                let ux = dx / distance
                let uy = dy / distance
                dxs[i] -= ux * force
                dys[i] -= uy * force
                dxs[j] += ux * force
                dys[j] += uy * force
            }

            // 向心力 + 温度限幅后应用
            for index in 0..<count {
                dxs[index] -= xs[index] * 0.6
                dys[index] -= ys[index] * 0.6
                let length = (dxs[index] * dxs[index] + dys[index] * dys[index]).squareRoot()
                guard length > 0 else { continue }
                let scale = min(length, temperature) / length
                xs[index] = clamp(xs[index] + dxs[index] * scale)
                ys[index] = clamp(ys[index] + dys[index] * scale)
            }

            temperature = max(temperature * 0.985, 0.006)
        }

        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(count)
        for index in 0..<count {
            positions[nodes[index]] = CGPoint(x: xs[index], y: ys[index])
        }
        return positions
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, -1), 1)
    }

    /// 螺旋初值。力导向从它出发收敛，所以它本身就是「还没算完时的合法布局」——
    /// 先上屏这一版、后台算完再换成收敛结果，用户就不用盯着空画布等。
    static func initialPosition(index: Int, count: Int, id: String) -> CGPoint {
        let angle = Double(index) * 2.399963
        let radius = 0.15 + 0.85 * Double(index) / Double(max(count, 1))
        let jitter = stableJitter(id)
        return CGPoint(x: cos(angle) * radius + jitter.x * 0.02, y: sin(angle) * radius + jitter.y * 0.02)
    }

    /// 由字符串决定的稳定抖动，替代随机数。
    private static func stableJitter(_ id: String) -> CGPoint {
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let angle = Double(hash % 6283) / 1000.0
        let radius = Double((hash / 6283) % 1000) / 1000.0
        return CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }
}
