//
//  ViewProjector.swift
//  CodeEdit
//
//  把同一份领域模型投影成不同视角的图。
//
//  核心约束：投影只读，不改原模型。产出的是一份新的 MindGraph，
//  节点 id 加 `view:` 前缀，避免与编辑中的模型混淆——
//  在业务视图里拖动节点不应该改变技术视图的结构。
//
//  共享依赖的处理是这套设计的关键：
//  业务视角把它上提到「基础设施」，技术视角让它作为代码与各层并列。
//  同一个包，两张图里位置不同，但都来自同一个 nodes 数组。
//

import Foundation

enum ViewProjector {

    /// 投影入口。
    static func project(_ graph: MindGraph, spec: ViewSpec) -> MindGraph {
        guard !graph.isEmpty else { return .empty }
        switch spec.axis {
        case .business:
            return businessView(graph, spec: spec)
        case .technical:
            return technicalView(graph, spec: spec)
        case .ownership:
            return ownershipView(graph, spec: spec)
        case .impact:
            // 变更影响需要 change 数据；在没有变更输入时退化成业务视图，
            // 保留结构供后续接入 ImpactPropagator。
            return businessView(graph, spec: spec)
        case .data:
            return dataView(graph, spec: spec)
        }
    }

    // MARK: 业务视角

    /// 根 → 业务域 → 模块；共享依赖按策略处理，默认上提到「基础设施」。
    private static func businessView(_ graph: MindGraph, spec: ViewSpec) -> MindGraph {
        var nodes: [MindNode] = []
        var root = MindNode(id: "view:root", title: graph.root?.displayTitle ?? "系统", kind: .system)
        root.classCount = graph.root?.classCount ?? 0
        nodes.append(root)

        // 业务域
        for domain in graph.domains {
            let domainID = "view:" + domain.id
            var node = copy(domain, id: domainID, parentID: "view:root")
            root.childIDs.append(domainID)

            if spec.granularity != .domainOnly {
                for child in graph.children(of: domain.id) {
                    let childID = "view:" + child.id
                    var childNode = copy(child, id: childID, parentID: domainID)
                    node.childIDs.append(childID)
                    nodes.append(childNode)
                }
            }
            nodes.append(node)
        }

        // 共享依赖
        let shared = graph.sharedNodes
        if !shared.isEmpty {
            switch spec.sharedPolicy {
            case .hoist:
                let infraID = "view:infra"
                var infra = MindNode(id: infraID, title: "基础设施", kind: .domain)
                infra.parentID = "view:root"
                infra.classCount = shared.reduce(0) { $0 + $1.classCount }
                infra.evidence = [Evidence(.dataBoundary, "被多个域共用的依赖，统一沉到基建层", weight: 0.8)]
                for item in shared {
                    let id = "view:" + item.id
                    var child = copy(item, id: id, parentID: infraID)
                    infra.childIDs.append(id)
                    nodes.append(child)
                }
                nodes.append(infra)
                root.childIDs.append(infraID)

            case .keep:
                for item in shared {
                    let id = "view:" + item.id
                    var child = copy(item, id: id, parentID: "view:root")
                    nodes.append(child)
                    root.childIDs.append(id)
                }

            case .hide:
                break

            case .duplicate:
                // 复制到每个域下，用虚线引用表示「用的是同一个东西」。
                for domain in graph.domains where shared.count <= 6 {
                    let domainID = "view:" + domain.id
                    for item in shared {
                        let id = "view:dup:" + domain.id + ":" + item.id
                        var child = copy(item, id: id, parentID: domainID)
                        child.title = item.displayTitle
                        child.evidence.append(Evidence(.callClosure, "被该域引用（共享）", weight: 0.5))
                        nodes.append(child)
                        if let index = nodes.firstIndex(where: { $0.id == domainID }) {
                            nodes[index].childIDs.append(id)
                        }
                    }
                }
            }
        }

        if let index = nodes.firstIndex(where: { $0.id == "view:root" }) {
            nodes[index] = root
        }
        return finish(nodes: nodes, rootID: "view:root", graph: graph)
    }

    // MARK: 技术视角

    /// 根 → 技术层 → 模块。共享依赖不特殊对待，和普通代码一起归层。
    private static func technicalView(_ graph: MindGraph, spec: ViewSpec) -> MindGraph {
        // 判定顺序很重要：`service/db` 既是 service 又是 db，
        // 必须让「数据访问」先命中，否则整片持久化代码会被算进业务层。
        let layers: [(id: String, title: String, match: (String) -> Bool)] = [
            ("data", "数据访问", { path in
                ["db", "mapper", "repository", "dao", "entity"].contains { path.contains($0) }
            }),
            ("entry", "入口层", { path in
                ["controller", "/api", "/web", "endpoint"].contains { path.contains($0) }
            }),
            ("business", "业务编排", { path in
                ["agent", "service", "orchestration", "workflow"].contains { path.contains($0) }
            }),
            ("domain", "领域模型", { path in
                ["domain", "model", "portrait", "dto"].contains { path.contains($0) }
            }),
            ("infra", "基础设施", { _ in true })
        ]

        var nodes: [MindNode] = []
        var root = MindNode(id: "view:root", title: graph.root?.displayTitle ?? "系统", kind: .system)
        root.classCount = graph.root?.classCount ?? 0
        nodes.append(root)

        // 先建 5 个层节点，再往里放。
        var layerNodes: [String: MindNode] = [:]
        for layer in layers {
            var node = MindNode(id: "view:layer:" + layer.id, title: layer.title, kind: .subdomain)
            node.parentID = "view:root"
            layerNodes[layer.id] = node
        }

        // 需要放进图里的节点：域（按 granularity）+ 共享。
        var candidates: [MindNode] = []
        if spec.granularity == .moduleOnly {
            for item in graph.nodes where item.kind == .module || item.kind == .shared {
                candidates.append(item)
            }
        } else {
            candidates = graph.domains + graph.sharedNodes
        }

        for item in candidates {
            let path = (item.packages.first ?? "").lowercased()
            let layer = layers.first { $0.match(path) } ?? layers.last!
            let id = "view:" + item.id
            var node = copy(item, id: id, parentID: "view:layer:" + layer.id)
            // 技术视角下共享依赖就是普通代码，去掉「共享」的视觉强调。
            if spec.sharedPolicy == .keep { node.isShared = false }
            nodes.append(node)
            layerNodes[layer.id]?.childIDs.append(id)
        }

        for layer in layers {
            guard var node = layerNodes[layer.id] else { continue }
            guard !node.childIDs.isEmpty else { continue }   // 空层不画
            node.classCount = node.childIDs
                .compactMap { id in nodes.first { $0.id == id } }
                .reduce(0) { $0 + $1.classCount }
            nodes.append(node)
            root.childIDs.append(node.id)
        }

        if let index = nodes.firstIndex(where: { $0.id == "view:root" }) {
            nodes[index] = root
        }
        return finish(nodes: nodes, rootID: "view:root", graph: graph)
    }

    // MARK: 归属视角

    /// 根 → 负责人 → 其负责的域。
    private static func ownershipView(_ graph: MindGraph, spec: ViewSpec) -> MindGraph {
        var nodes: [MindNode] = []
        var root = MindNode(id: "view:root", title: graph.root?.displayTitle ?? "系统", kind: .system)
        root.classCount = graph.root?.classCount ?? 0
        nodes.append(root)

        var byOwner: [String: [MindNode]] = [:]
        for domain in graph.domains {
            let owner = domain.owner.primary
            let key = owner.isEmpty ? "未指定负责人" : owner
            byOwner[key, default: []].append(domain)
        }

        for (owner, domains) in byOwner.sorted(by: { $0.value.reduce(0) { $0 + $1.classCount } > $1.value.reduce(0) { $0 + $1.classCount } }) {
            let ownerID = "view:owner:" + owner
            var ownerNode = MindNode(id: ownerID, title: owner, kind: .subdomain)
            ownerNode.parentID = "view:root"
            ownerNode.classCount = domains.reduce(0) { $0 + $1.classCount }
            ownerNode.evidence = [Evidence(.gitOwnership, "\(domains.count) 个领域", weight: 0.7)]

            for domain in domains {
                let id = "view:" + domain.id
                var node = copy(domain, id: id, parentID: ownerID)
                ownerNode.childIDs.append(id)
                nodes.append(node)
            }
            nodes.append(ownerNode)
            root.childIDs.append(ownerID)
        }

        if let index = nodes.firstIndex(where: { $0.id == "view:root" }) {
            nodes[index] = root
        }
        return finish(nodes: nodes, rootID: "view:root", graph: graph)
    }

    // MARK: 数据视角

    /// 只保留有独立数据层（mapper/domain/entity）的节点，便于 DBA 与后端对齐。
    private static func dataView(_ graph: MindGraph, spec: ViewSpec) -> MindGraph {
        let markers = ["db", "mapper", "domain", "entity", "repository", "dao", "schema"]
        var nodes: [MindNode] = []
        var root = MindNode(id: "view:root", title: graph.root?.displayTitle ?? "系统", kind: .system)
        nodes.append(root)

        for item in graph.nodes where item.kind != .system {
            let path = (item.packages.first ?? "").lowercased()
            guard markers.contains(where: { path.contains($0) }) else { continue }
            let id = "view:" + item.id
            var node = copy(item, id: id, parentID: "view:root")
            nodes.append(node)
            root.childIDs.append(id)
        }

        if root.childIDs.isEmpty {
            // 没有命中任何数据层包时，退回完整的业务视图，避免出现空图。
            return businessView(graph, spec: spec)
        }
        if let index = nodes.firstIndex(where: { $0.id == "view:root" }) {
            nodes[index] = root
        }
        return finish(nodes: nodes, rootID: "view:root", graph: graph)
    }

    // MARK: 工具

    private static func copy(_ node: MindNode, id: String, parentID: String) -> MindNode {
        var result = MindNode(id: id, title: node.title, kind: node.kind, parentID: parentID)
        result.packages = node.packages
        result.classCount = node.classCount
        result.fileCount = node.fileCount
        result.owner = node.owner
        result.evidence = node.evidence
        result.isShared = node.isShared
        result.isManual = node.isManual
        return result
    }

    private static func finish(nodes: [MindNode], rootID: String, graph: MindGraph) -> MindGraph {
        var result = MindGraph(
            nodes: nodes,
            rootID: rootID,
            generatedAt: graph.generatedAt,
            baseCommit: graph.baseCommit
        )
        result.rebuildIndex()
        return result
    }
}
