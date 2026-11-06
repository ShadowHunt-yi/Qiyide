//
//  StructureDiff.swift
//  CodeEdit
//
//  分支相对目标分支的「结构增量」：叠在结构地图上的那一层。
//
//  它回答的不是「改了多少行」——AI 写代码天然产出大量行数，行数说明不了问题——
//  而是「结构有没有变」。按结构意义分四类：
//
//  - 模块内实现：只动了一个模块内部，接口和依赖都没变。只计数，不打扰人。
//  - 接口：被别的域引用的类，公开签名变了。
//  - 依赖：两个模块之间多了或少了引用。跨域的要人确认；域内的只标记。
//  - 地图：出现了新模块、文件跨域移动。
//
//  后三类里需要人拿主意的，各生成一条「待确认」。把控一个分支的工作量
//  就等于待确认的条数，和它改了多少文件无关。
//

import Foundation

// MARK: - 标记

/// 一个节点（域 / 模块 / 子包）上的改动计数。
struct StructureMarks: Hashable, Sendable {
    var added = 0
    var modified = 0
    var deleted = 0

    var isEmpty: Bool { added == 0 && modified == 0 && deleted == 0 }
    var total: Int { added + modified + deleted }

    static func + (lhs: StructureMarks, rhs: StructureMarks) -> StructureMarks {
        StructureMarks(
            added: lhs.added + rhs.added,
            modified: lhs.modified + rhs.modified,
            deleted: lhs.deleted + rhs.deleted
        )
    }

    mutating func count(_ kind: StructureFileChange.Kind) {
        switch kind {
        case .added: added += 1
        case .modified: modified += 1
        case .deleted: deleted += 1
        }
    }
}

// MARK: - 文件改动

struct StructureFileChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added
        case modified
        case deleted

        var sign: String {
            switch self {
            case .added: return "+"
            case .modified: return "~"
            case .deleted: return "−"
            }
        }

        var title: String {
            switch self {
            case .added: return "新增"
            case .modified: return "变更"
            case .deleted: return "删除"
            }
        }
    }

    /// 仓库相对路径。删除的文件是它原来的路径。
    var path: String
    var kind: Kind
    /// 改名或移动时的另一端：新增一侧记来处，删除一侧记去处。
    var counterpart: String?
    /// 还没提交（工作区或暂存区里的改动）。
    var isUncommitted = false
    var domainID: String
    var moduleID: String
    /// 相对模块的子包路径。
    var subpath: [String] = []
    /// 卷入了哪几类待确认。空集合表示纯粹的模块内实现改动。
    var tags: Set<StructureAsk.Kind> = []

    var id: String { kind.rawValue + ":" + path }
    var fileName: String { (path as NSString).lastPathComponent }
}

/// 整个模块在本分支里被删光了。索引里已经没有它，地图上要单独补一行才看得见。
struct StructureRemovedModule: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var key: String
    var domainID: String
}

// MARK: - 依赖变化

struct StructureEdgeChange: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case added
        case removed
    }

    var kind: Kind
    var fromDomain: String
    var toDomain: String
    var fromModule: String
    var toModule: String
    /// 证据。新增的是现在的 import，消失的是基准版本里的 import。
    var references: [StructureReference]
    /// 两个域之间此前没有任何直接依赖（新增时），或此后不再有（消失时）。
    var changesDomainPair = false

    var id: String { "\(kind.rawValue):\(fromModule)->\(toModule)" }
    var crossesDomains: Bool { fromDomain != toDomain }
}

// MARK: - 待确认

/// 一行证据。
struct StructureEvidence: Hashable, Sendable {
    var file: String
    var line: Int
    /// `+` 新增、`-` 删除、空格表示上下文。
    var sign: String
    var text: String
}

struct StructureAsk: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable, Codable {
        case map
        case dependency
        case interface
        case scope

        var title: String {
            switch self {
            case .map: return "地图"
            case .dependency: return "依赖"
            case .interface: return "接口"
            case .scope: return "范围"
            }
        }
    }

    /// 稳定标识：同一件事在两次计算里标识相同，人做过的决定才对得上。
    let id: String
    var kind: Kind
    var title: String
    var detail: String
    /// 它出现在地图上的哪些位置。每个锚点是一条路径 `[域, 模块, 子包…]`；
    /// 面包屑走到任何一个锚点的上级，这条待确认都在范围内。
    var anchors: [[String]]
    var evidence: [StructureEvidence] = []
    /// 标成违规时交给 AI 的修改要求。
    var remedy: String = ""
    /// 新包待归属时的建议：往来最多的那个域，以及这个包的业务路径。
    var adoption: Adoption?

    struct Adoption: Hashable, Sendable {
        var moduleKey: String
        var moduleTitle: String
        var domainID: String
        var domainTitle: String
    }

    /// 当前位置 `path` 的范围内有没有它。
    func isInside(_ path: [String]) -> Bool {
        path.isEmpty || anchors.contains { $0.count >= path.count && Array($0.prefix(path.count)) == path }
    }
}

/// 一个计算阶段的耗时。
struct StructureTiming: Hashable, Sendable {
    var stage: String
    var milliseconds: Double
}

// MARK: - 结果

struct StructureDiff: Sendable {

    /// 当前分支名；游离 HEAD 时是短提交号。
    var headName = ""
    var targetName = ""
    /// 与目标分支的分叉点（短提交号）。
    var baseCommit = ""
    var commitCount = 0
    var includesWorkingTree = true
    /// 计算时用的声明范围（域标识）。
    var scope: Set<String> = []

    private(set) var changes: [StructureFileChange] = []
    /// 不参与结构判断、只计数的文件。
    var testFiles = 0
    var documentFiles = 0
    var otherFiles = 0

    var newModules: Set<String> = []
    private(set) var removedModules: [StructureRemovedModule] = []
    var edges: [StructureEdgeChange] = []
    var asks: [StructureAsk] = []

    /// 精度指标：扫了多少文件、多少条指向仓库内部的 import 没解析出来。
    var scannedFiles = 0
    var unresolvedImports = 0
    /// 各阶段耗时（毫秒），按执行顺序。只用于验证入口打印，定位「慢在哪一步」。
    var timings: [StructureTiming] = []

    private var byModule: [String: [Int]] = [:]
    private var byDomain: [String: StructureMarks] = [:]
    private var moduleMarks: [String: StructureMarks] = [:]

    static let empty = StructureDiff()

    mutating func setChanges(_ changes: [StructureFileChange], removedModules: [StructureRemovedModule]) {
        self.changes = changes.sorted { $0.path != $1.path ? $0.path < $1.path : $0.kind.rawValue < $1.kind.rawValue }
        self.removedModules = removedModules.sorted { $0.key < $1.key }
        byModule = [:]
        byDomain = [:]
        moduleMarks = [:]
        for (offset, change) in self.changes.enumerated() {
            byModule[change.moduleID, default: []].append(offset)
            byDomain[change.domainID, default: StructureMarks()].count(change.kind)
            moduleMarks[change.moduleID, default: StructureMarks()].count(change.kind)
        }
    }

    // MARK: 查询

    var isEmpty: Bool { changes.isEmpty && testFiles + documentFiles + otherFiles == 0 }
    /// 文件总数（含只计数的）。
    var fileCount: Int { changes.count + testFiles + documentFiles + otherFiles }
    var touchedDomains: Set<String> { Set(byDomain.keys) }
    var touchedModules: Set<String> { Set(moduleMarks.keys) }
    /// 纯粹的模块内实现改动：没有卷入任何待确认。
    var innerChanges: [StructureFileChange] { changes.filter(\.tags.isEmpty) }

    func marks(domain id: String) -> StructureMarks {
        byDomain[id] ?? StructureMarks()
    }

    func marks(module id: String) -> StructureMarks {
        moduleMarks[id] ?? StructureMarks()
    }

    /// 模块内某个子包（含更深层）的改动计数。
    func marks(module id: String, under subpath: [String]) -> StructureMarks {
        var marks = StructureMarks()
        for change in changes(module: id) where change.subpath.starts(with: subpath) {
            marks.count(change.kind)
        }
        return marks
    }

    func changes(module id: String) -> [StructureFileChange] {
        (byModule[id] ?? []).map { changes[$0] }
    }

    /// 恰好放在这一级的文件改动（不含更深的子包）。
    func changes(module id: String, at subpath: [String]) -> [StructureFileChange] {
        changes(module: id).filter { $0.subpath == subpath }
    }

    func removedModules(domain id: String) -> [StructureRemovedModule] {
        removedModules.filter { $0.domainID == id }
    }

    func asks(inside path: [String]) -> [StructureAsk] {
        asks.filter { $0.isInside(path) }
    }

    func edges(touching path: [String]) -> [StructureEdgeChange] {
        guard let domain = path.first else { return edges.filter(\.crossesDomains) }
        guard path.count > 1 else {
            return edges.filter { $0.fromDomain == domain || $0.toDomain == domain }
        }
        return edges.filter { $0.fromModule == path[1] || $0.toModule == path[1] }
    }
}
