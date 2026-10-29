//
//  MindMap.swift
//  CodeEdit
//
//  领域建模的思维导图模型。
//
//  为什么不复用 WikiArchitecture：
//  - WikiArchitecture 是「分析结果」，域和模块只是字符串，改不了、也没法记录为什么这么分；
//  - 导图是「可编辑的建模过程」，节点要能改名、能拖动改归属、能记录每条判定依据，
//    还要能在人工改动后和自动识别结果做对比。
//  所以这里单独建模，字段围绕「可编辑 + 可追溯」设计。
//
//  节点位置不存绝对坐标：布局由视图按当前展开状态现算，模型只存人工拖动产生的偏移。
//  否则窗口尺寸一变，存下来的坐标就全错位了。
//

import Foundation

// MARK: - 节点类型

/// 导图节点的语义类型。决定图标、颜色与可执行的操作。
enum MindNodeKind: String, Codable, Sendable, CaseIterable {
    /// 仓库本身，导图根节点。
    case system
    /// 业务领域，人工锚定的主要对象。
    case domain
    /// 域内部的分组（混合粒度下才会出现）。
    case subdomain
    /// 代码模块，通常对应一个包。
    case module
    /// 被多个域共用的依赖。在业务视角下会被上提到基建层。
    case shared

    var title: String {
        switch self {
        case .system: return "系统"
        case .domain: return "领域"
        case .subdomain: return "子域"
        case .module: return "模块"
        case .shared: return "共享依赖"
        }
    }

    /// 是否可以作为一个「领域」参与后续的知识库生成。
    var isDomainLike: Bool { self == .domain }
}

// MARK: - 判定依据

/// 一条判定依据。`detail` 是给人看的原文，`weight` 用于加权汇总。
struct Evidence: Hashable, Sendable {
    var kind: EvidenceKind
    /// 例如「agent/AGENTS.md 明示销售搭子一期 M0-M2」。
    var detail: String
    /// 归一化后的权重 0...1。
    var weight: Double

    init(_ kind: EvidenceKind, _ detail: String, weight: Double) {
        self.kind = kind
        self.detail = detail
        self.weight = weight
    }
}

enum EvidenceKind: String, Codable, Sendable, CaseIterable {
    /// 目录级文档（AGENTS.md、docs/tech-business）里出现过领域名。
    case documentation
    /// 同包内类名前缀一致（`CustomerService*` 占比高）。
    case naming
    /// 中文业务词在注释里高频出现（「画像」1460 次）。
    case chineseTerm
    /// 与兄弟包几乎零互引，说明业务独立。
    case callClosure
    /// 有独立的 mapper / domain / 表命名空间。
    case dataBoundary
    /// git 作者集中，存在明确负责人。
    case gitOwnership

    var title: String {
        switch self {
        case .documentation: return "文档"
        case .naming: return "命名"
        case .chineseTerm: return "中文词频"
        case .callClosure: return "调用闭合"
        case .dataBoundary: return "数据边界"
        case .gitOwnership: return "作者集中"
        }
    }
}

// MARK: - 人名锚定

/// 单个作者的提交统计。
struct AuthorStat: Hashable, Sendable, Codable {
    var name: String
    var commits: Int
}

/// 负责人归属。
///
/// 人名有两个来源：自动从 git 历史统计、人工在导图上指定。
/// 人工值优先——统计只能说明「谁改得多」，不能说明「谁该负责」。
struct OwnerInfo: Hashable, Sendable, Codable {
    /// 按提交数降序。
    var authors: [AuthorStat] = []
    /// 人工指定，优先级最高。
    var manual: String?

    var primary: String {
        if let manual, !manual.isEmpty { return manual }
        return authors.first?.name ?? ""
    }

    var isEmpty: Bool { authors.isEmpty && (manual?.isEmpty ?? true) }
}

// MARK: - 节点

struct MindNode: Identifiable, Hashable, Sendable {
    /// 稳定标识。用包路径或人工命名后的 slug，重命名标题不影响它。
    let id: String
    /// 显示名，可人工改。
    var title: String
    var kind: MindNodeKind
    var parentID: String? = nil
    var childIDs: [String] = []

    /// 归属的代码包（仓库相对路径）。共享依赖节点也有。
    var packages: [String] = []
    /// 类数量，用于在导图上标注规模。
    var classCount: Int = 0
    var fileCount: Int = 0

    var owner: OwnerInfo = OwnerInfo()
    var evidence: [Evidence] = []

    /// 被 ≥2 个域引用。
    var isShared: Bool = false
    /// 人工改过（改名/改归属/改类型）。用于在界面上和自动结果区分。
    var isManual: Bool = false
    /// 人工操作与自动识别不一致，需要提示。
    var hasConflict: Bool = false

    /// 人工拖动的偏移，单位为点。布局基准由视图现算。
    var manualOffset: CGSize = .zero

    var displayTitle: String { title.isEmpty ? id : title }

    /// 综合置信度，用于给节点排序或标灰低分项。
    var confidence: Double {
        guard !evidence.isEmpty else { return 0 }
        let sum = evidence.reduce(0) { $0 + $1.weight }
        return min(1, sum / Double(evidence.count))
    }
}

// MARK: - 图

/// 领域建模的完整结果。
struct MindGraph: Sendable {
    var nodes: [MindNode] = []
    var rootID: String = ""
    /// 生成时间。领域划分是快照，代码变了要重算。
    var generatedAt: Date = .distantPast
    /// 识别时所基于的 commit，便于判断结果是否过期。
    var baseCommit: String = ""

    // 索引：导图交互是逐帧的，按 id 找节点必须 O(1)。
    private(set) var nodesByID: [String: MindNode] = [:]
    private(set) var childrenByParent: [String: [String]] = [:]

    static let empty = MindGraph()

    init(
        nodes: [MindNode] = [],
        rootID: String = "",
        generatedAt: Date = .distantPast,
        baseCommit: String = ""
    ) {
        self.nodes = nodes
        self.rootID = rootID
        self.generatedAt = generatedAt
        self.baseCommit = baseCommit
        self.rebuildIndex()
    }

    var isEmpty: Bool { nodes.isEmpty }
    var root: MindNode? { nodesByID[rootID] }

    /// 领域节点（根的直接子节点），按类数降序。
    var domains: [MindNode] {
        children(of: rootID)
            .filter { $0.kind == .domain }
            .sorted { $0.classCount > $1.classCount }
    }

    /// 全部共享依赖节点，按被引用度排序。
    var sharedNodes: [MindNode] {
        nodes.filter { $0.kind == .shared }.sorted { $0.classCount > $1.classCount }
    }

    func node(_ id: String) -> MindNode? { nodesByID[id] }

    func children(of id: String) -> [MindNode] {
        (childrenByParent[id] ?? []).compactMap { nodesByID[$0] }
    }

    /// 从某节点向上的路径，用于「面包屑」与定位。
    func path(to id: String) -> [MindNode] {
        var result: [MindNode] = []
        var cursor = nodesByID[id]
        while let node = cursor {
            result.append(node)
            cursor = node.parentID.flatMap { nodesByID[$0] }
        }
        return result.reversed()
    }

    /// 关键字检索：标题或包路径命中即返回。
    func search(_ keyword: String) -> [MindNode] {
        let key = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }
        return nodes.filter {
            $0.title.lowercased().contains(key)
                || $0.packages.contains { $0.lowercased().contains(key) }
        }
    }

    /// 重建索引。所有修改节点的方法最后都要调它。
    mutating func rebuildIndex() {
        nodesByID = [:]
        childrenByParent = [:]
        for node in nodes {
            nodesByID[node.id] = node
            if let parent = node.parentID {
                childrenByParent[parent, default: []].append(node.id)
            }
        }
    }

    /// 更新单个节点并同步索引。
    mutating func update(_ node: MindNode) {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index] = node
            nodesByID[node.id] = node
        }
    }

    // MARK: 编辑操作

    /// 改名。`id` 不变，保证与知识条目的关联不因改名而断。
    mutating func rename(_ id: String, to title: String) {
        guard var node = nodesByID[id] else { return }
        node.title = title
        node.isManual = true
        update(node)
    }

    /// 把节点挂到新父节点下（拖拽改归属）。
    mutating func move(_ id: String, toParent newParentID: String) {
        guard var node = nodesByID[id], newParentID != id else { return }
        // 不允许挂到自己的后代下，否则会形成环。
        if path(to: newParentID).contains(where: { $0.id == id }) { return }

        if let oldParent = node.parentID {
            childrenByParent[oldParent]?.removeAll { $0 == id }
            if var parent = nodesByID[oldParent] {
                parent.childIDs.removeAll { $0 == id }
                update(parent)
            }
        }
        node.parentID = newParentID
        node.isManual = true
        update(node)
        if var parent = nodesByID[newParentID] {
            if !parent.childIDs.contains(id) {
                parent.childIDs.append(id)
                update(parent)
            }
        }
        rebuildIndex()
    }

    /// 合并：把 `sourceID` 的包与子节点并入 `targetID`，然后移除 source。
    mutating func merge(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID,
              let source = nodesByID[sourceID],
              var target = nodesByID[targetID] else { return }

        target.packages.append(contentsOf: source.packages.filter { !target.packages.contains($0) })
        target.classCount += source.classCount
        target.fileCount += source.fileCount
        target.evidence.append(contentsOf: source.evidence)
        target.isManual = true

        // 子节点改挂到目标下。
        for childID in childrenByParent[sourceID] ?? [] {
            if var child = nodesByID[childID] {
                child.parentID = targetID
                update(child)
                target.childIDs.append(childID)
            }
        }

        update(target)
        if let parent = source.parentID {
            childrenByParent[parent]?.removeAll { $0 == sourceID }
            if var parentNode = nodesByID[parent] {
                parentNode.childIDs.removeAll { $0 == sourceID }
                update(parentNode)
            }
        }
        nodes.removeAll { $0.id == sourceID }
        rebuildIndex()
    }

    /// 指定负责人。传 nil 清空人工值，回落到 git 统计结果。
    mutating func assignOwner(_ id: String, to name: String?) {
        guard var node = nodesByID[id] else { return }
        node.owner.manual = name
        update(node)
    }

    /// 标记/取消共享依赖。
    mutating func setShared(_ id: String, _ shared: Bool) {
        guard var node = nodesByID[id] else { return }
        node.isShared = shared
        node.kind = shared ? .shared : .module
        node.isManual = true
        update(node)
    }
}

// MARK: - 持久化

/// 人工锚定后锁定的模型。与自动识别结果分开存，避免下次扫描被覆盖。
struct LockedDomainModel: Codable, Sendable {
    var revision: Int = 1
    var lockedAt: Date = Date()
    var baseCommit: String = ""
    var graph: MindGraph = .empty

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/domains.locked.json")
    }
}

/// `MindGraph` 的编解码。
///
/// 索引字段是派生数据，不参与序列化：`nodesByID` 里存的是节点副本，
/// 一旦落盘就会和 `nodes` 重复，读回来还可能不一致。解码后统一重建。
extension MindGraph: Codable {
    enum CodingKeys: String, CodingKey {
        case nodes, rootID, generatedAt, baseCommit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.nodes = try container.decode([MindNode].self, forKey: .nodes)
        self.rootID = try container.decode(String.self, forKey: .rootID)
        self.generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
        self.baseCommit = try container.decodeIfPresent(String.self, forKey: .baseCommit) ?? ""
        self.rebuildIndex()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(rootID, forKey: .rootID)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(baseCommit, forKey: .baseCommit)
    }
}

extension MindNode: Codable {}
extension Evidence: Codable {}
