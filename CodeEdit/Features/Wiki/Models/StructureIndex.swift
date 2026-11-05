//
//  StructureIndex.swift
//  CodeEdit
//
//  结构索引：一棵「全仓 › 域 › 模块 › 文件」的树。
//
//  它由两样东西合成：
//  - 领域模型（`MindGraph`）是「决定」：哪些包算一个域、人把哪个模块挪到了哪里；
//  - 一次目录扫描是「事实」：现在仓库里到底有哪些文件。
//
//  为什么不直接读 `MindGraph` 里的模块节点：
//  模型是某一次识别的快照，还可能被锁定。代码在变，模型不一定跟着变——
//  新加的包模型里没有，删掉的包模型里还在。结构地图要回答的是「现在的代码长什么样」，
//  所以文件一律以当下的扫描为准，模型只用来决定「这个文件归谁」。
//  模型里没有的新包按路径规则自动落位，不会因为模型旧了就从图上消失。
//
//  三条不变量（`violations` 逐条检查）：
//  1. 全覆盖：扫描到的每个文件恰好属于一个模块；
//  2. 守恒：域的类数等于它所有模块的类数之和；
//  3. 唯一：模块标识全图唯一，一个模块只挂在一个域下。
//

import Foundation

// MARK: - 节点

struct StructureFile: Identifiable, Hashable, Sendable {
    /// 仓库相对路径。
    let path: String

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var name: String { (fileName as NSString).deletingPathExtension }
    /// 所在目录的仓库相对路径。
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct StructureModule: Identifiable, Hashable, Sendable {
    /// `module:agent/customerservice/biz`。和 `MindNode.id` 同一套标识。
    let id: String
    var title: String
    /// 业务路径。域根模块的 key 就是域的路径。
    var key: String
    /// 域根目录直属的类。
    var isRoot: Bool
    /// 领域模型里有对应节点。false 表示模型里没有、按路径规则推出来的（通常是识别之后新加的包）。
    var isModeled: Bool
    var files: [StructureFile]

    var classCount: Int { files.count }

    /// 文件所在的目录，去重后排序。一个模块可能跨多个 Maven 模块，也可能有多层子包。
    var directories: [String] {
        Array(Set(files.map(\.directory))).sorted()
    }
}

struct StructureDomain: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        /// 识别出来的业务域。
        case domain
        /// 按一级包聚合出来的兜底域：没有被认领的包都落在这里。
        case catchAll
        /// 人工标成共享依赖的模块。
        case shared
        /// 不属于任何域的包。
        case unassigned
    }

    let id: String
    var title: String
    /// 域的包路径。合并过的域可能有多个。
    var keys: [String]
    var kind: Kind
    /// 按类数降序。
    var modules: [StructureModule]

    var classCount: Int { modules.reduce(0) { $0 + $1.classCount } }
}

/// 模块里的一个子包。模块下面可以继续按包路径往下走。
struct StructurePackage: Identifiable, Hashable, Sendable {
    /// 这一段的包名。
    var name: String
    /// 相对模块的路径段，含自己。
    var subpath: [String]
    /// 类数，含更深的子包。
    var classCount: Int

    var id: String { subpath.joined(separator: "/") }
}

/// 某个包位置上能看到的东西：下一级子包，加上直接放在这一级的文件。
struct StructureContents: Sendable {
    var packages: [StructurePackage] = []
    var files: [StructureFile] = []
    /// 模块跨多个源码根时，文件路径 → 源码根短名（`app`、`client`）。
    var rootLabels: [String: String] = [:]

    var classCount: Int { files.count + packages.reduce(0) { $0 + $1.classCount } }
}

// MARK: - 归属规则

/// 给定一个包的业务路径，决定它归哪个域、哪个模块。
///
/// 规则按「路径越长越具体」取胜：
/// 1. 模型里的模块节点认领的路径（人工挪过的模块跟着节点走）；
/// 2. 域认领的路径，域下面取第一级子包当模块；
/// 3. 都不匹配的归「未划分」，按一级包分模块。
struct StructureAssigner: Sendable {

    static let sharedDomainID = "structure:shared"
    static let unassignedDomainID = "structure:unassigned"

    struct Assignment: Hashable, Sendable {
        var domainID: String
        var moduleID: String
        var moduleTitle: String
        var moduleKey: String
        var isRoot: Bool
        var isModeled: Bool
    }

    private struct Rule: Sendable {
        var parts: [String]
        var domainID: String
        /// 模块节点的规则才有；域的规则为 nil。
        var moduleID: String?
        var moduleTitle: String = ""
        /// 域根模块只认领「恰好等于」的路径，不认领子包——
        /// 否则模型之后新加的子包会全被域根吞掉，看不出是新模块。
        var exact: Bool = false
    }

    private var rules: [Rule] = []
    /// 源码根，长的在前。
    private var sourceRoots: [String] = []

    init(graph: MindGraph, sourceRoots: [String]) {
        self.sourceRoots = Array(Set(sourceRoots)).sorted { $0.count > $1.count }

        var rules: [Rule] = []
        for node in graph.nodes {
            switch node.kind {
            case .domain:
                for package in node.packages where !package.isEmpty {
                    rules.append(Rule(parts: Self.split(package), domainID: node.id))
                }
            case .module, .subdomain, .shared:
                // 往上找到所属的域。人工把模块拖到别的域下之后，这里拿到的就是新域。
                let owner = graph.path(to: node.id).last { $0.kind == .domain }
                let domainID = node.kind == .shared ? Self.sharedDomainID : owner?.id
                guard let domainID else { continue }
                for package in node.packages where !package.isEmpty {
                    rules.append(Rule(
                        parts: Self.split(package),
                        domainID: domainID,
                        moduleID: node.id,
                        moduleTitle: node.displayTitle,
                        exact: DomainAnalyzer.isRootModule(node.id)
                    ))
                }
            case .system:
                break
            }
        }
        // 长路径优先；同长时模块规则优先于域规则。
        self.rules = rules.sorted { lhs, rhs in
            if lhs.parts.count != rhs.parts.count { return lhs.parts.count > rhs.parts.count }
            return lhs.moduleID != nil && rhs.moduleID == nil
        }
    }

    func assign(parts: [String]) -> Assignment {
        for rule in rules {
            if rule.exact {
                guard rule.parts == parts else { continue }
            } else {
                guard parts.count >= rule.parts.count, Array(parts.prefix(rule.parts.count)) == rule.parts else {
                    continue
                }
            }
            let key = rule.parts.joined(separator: "/")
            if let moduleID = rule.moduleID {
                return Assignment(
                    domainID: rule.domainID,
                    moduleID: moduleID,
                    moduleTitle: rule.moduleTitle,
                    moduleKey: key,
                    isRoot: rule.exact,
                    isModeled: true
                )
            }
            // 命中的是域：域下面的第一级子包当模块。
            if parts.count > rule.parts.count {
                let segment = parts[rule.parts.count]
                let moduleKey = key + "/" + segment
                return Assignment(
                    domainID: rule.domainID,
                    moduleID: "module:" + moduleKey,
                    moduleTitle: segment,
                    moduleKey: moduleKey,
                    isRoot: false,
                    isModeled: false
                )
            }
            return Assignment(
                domainID: rule.domainID,
                moduleID: "module:" + key + DomainAnalyzer.rootModuleSuffix,
                moduleTitle: DomainAnalyzer.rootModuleTitle,
                moduleKey: key,
                isRoot: true,
                isModeled: false
            )
        }

        let segment = parts.first ?? "?"
        return Assignment(
            domainID: Self.unassignedDomainID,
            moduleID: "module:" + segment,
            moduleTitle: segment,
            moduleKey: segment,
            isRoot: false,
            isModeled: false
        )
    }

    /// 仓库相对的文件路径 → 业务路径段。不在任何源码根下返回 nil。
    ///
    /// 用于扫描里没有的文件：分支 diff 里被删掉或改名前的路径，磁盘上已经不存在，
    /// 但仍然要知道它原来属于哪个模块。
    func parts(forFile path: String) -> [String]? {
        for root in sourceRoots where path.hasPrefix(root + "/") {
            let rest = path.dropFirst(root.count + 1)
            let parts = rest.split(separator: "/").dropLast().map(String.init)
            return parts.isEmpty ? nil : parts
        }
        return nil
    }

    func assign(file path: String) -> Assignment? {
        parts(forFile: path).map(assign(parts:))
    }

    /// 文件所在源码根的短名。多 Maven 模块的仓库里用来区分同名包来自哪个模块：
    /// `saas-plus-ai-platform-app`、`saas-plus-ai-platform-client` → `app`、`client`。
    /// 只有一个源码根时返回空串，界面上不必显示。
    func rootLabel(forFile path: String) -> String {
        guard sourceRoots.count > 1 else { return "" }
        let heads = sourceRoots.map { String($0.split(separator: "/").first ?? "") }
        guard let root = sourceRoots.first(where: { path.hasPrefix($0 + "/") }) else { return "" }
        let head = String(root.split(separator: "/").first ?? "")
        // 去掉所有源码根共有的前缀，剩下的才有区分度。
        var common = heads.first ?? ""
        for other in heads.dropFirst() {
            common = String(common.commonPrefix(with: other))
        }
        let short = String(head.dropFirst(common.count))
        return short.isEmpty ? head : short
    }

    private static func split(_ package: String) -> [String] {
        package.split(separator: "/").map(String.init)
    }
}

// MARK: - 索引

struct StructureIndex: Sendable {

    /// 业务域在前（按类数降序），随后是共享基建、未划分。
    private(set) var domains: [StructureDomain] = []
    private(set) var assigner = StructureAssigner(graph: .empty, sourceRoots: [])

    private var domainIndex: [String: Int] = [:]
    private var moduleIndex: [String: (domain: Int, module: Int)] = [:]
    private var fileModule: [String: String] = [:]

    static let empty = StructureIndex()

    var isEmpty: Bool { domains.isEmpty }
    var classCount: Int { domains.reduce(0) { $0 + $1.classCount } }
    var moduleCount: Int { domains.reduce(0) { $0 + $1.modules.count } }
    /// 真正的业务域（含兜底域），不含「共享基建」「未划分」这两个容器。
    var modeledDomains: [StructureDomain] {
        domains.filter { $0.kind == .domain || $0.kind == .catchAll }
    }

    func domain(_ id: String) -> StructureDomain? {
        domainIndex[id].map { domains[$0] }
    }

    func module(_ id: String) -> StructureModule? {
        moduleIndex[id].map { domains[$0.domain].modules[$0.module] }
    }

    func domain(ofModule id: String) -> StructureDomain? {
        moduleIndex[id].map { domains[$0.domain] }
    }

    func moduleID(forFile path: String) -> String? {
        fileModule[path]
    }

    /// 模块内某个子路径下的内容。`subpath` 为空表示模块目录本身。
    ///
    /// 大模块下面还有多层子包（基准仓库的 `agent/suggest` 有十几个），
    /// 平铺成一列根本找不到东西。这里沿真实包路径一层层往下给，
    /// 每一层只有「下一级子包 + 这一级的文件」，和上面几级是同一种画法。
    func contents(of module: StructureModule, at subpath: [String]) -> StructureContents {
        // 域根模块的 key 就是域的路径，直属文件的相对路径自然是空的。
        let depth = module.key.split(separator: "/").count
        var counts: [String: Int] = [:]
        var result = StructureContents()
        var roots = Set<String>()

        for file in module.files {
            let relative = Array((assigner.parts(forFile: file.path) ?? []).dropFirst(depth))
            guard relative.count >= subpath.count, Array(relative.prefix(subpath.count)) == subpath else {
                continue
            }
            roots.insert(assigner.rootLabel(forFile: file.path))
            if relative.count == subpath.count {
                result.files.append(file)
            } else {
                counts[relative[subpath.count], default: 0] += 1
            }
        }

        result.packages = counts
            .map { StructurePackage(name: $0.key, subpath: subpath + [$0.key], classCount: $0.value) }
            .sorted { $0.classCount != $1.classCount ? $0.classCount > $1.classCount : $0.name < $1.name }
        result.files.sort { $0.fileName != $1.fileName ? $0.fileName < $1.fileName : $0.path < $1.path }
        // 只有真的跨了源码根才标出处，否则每个文件后面都挂同一个词只是噪音。
        if roots.count > 1 {
            for file in result.files {
                result.rootLabels[file.path] = assigner.rootLabel(forFile: file.path)
            }
        }
        return result
    }

    // MARK: 构建

    /// 纯函数：同样的包清单和模型，必得同样的索引。
    static func build(packages: [ScannedPackage], graph: MindGraph) -> StructureIndex {
        let assigner = StructureAssigner(graph: graph, sourceRoots: packages.map(\.sourceRoot))

        struct Draft {
            var assignment: StructureAssigner.Assignment
            var files: [StructureFile] = []
        }
        var drafts: [String: Draft] = [:]
        for package in packages {
            let assignment = assigner.assign(parts: package.parts)
            var draft = drafts[assignment.moduleID] ?? Draft(assignment: assignment)
            draft.files.append(contentsOf: package.files.map(StructureFile.init(path:)))
            drafts[assignment.moduleID] = draft
        }

        var modulesByDomain: [String: [StructureModule]] = [:]
        for (moduleID, draft) in drafts {
            modulesByDomain[draft.assignment.domainID, default: []].append(StructureModule(
                id: moduleID,
                title: draft.assignment.moduleTitle,
                key: draft.assignment.moduleKey,
                isRoot: draft.assignment.isRoot,
                isModeled: draft.assignment.isModeled,
                files: draft.files.sorted { $0.path < $1.path }
            ))
        }
        func sorted(_ modules: [StructureModule]) -> [StructureModule] {
            modules.sorted {
                $0.classCount != $1.classCount ? $0.classCount > $1.classCount : $0.title < $1.title
            }
        }

        var domains: [StructureDomain] = graph.domains.map { node in
            StructureDomain(
                id: node.id,
                title: node.displayTitle,
                keys: node.packages,
                kind: node.id.hasPrefix("domain:leftover:") ? .catchAll : .domain,
                modules: sorted(modulesByDomain[node.id] ?? [])
            )
        }
        // 模型里的类数是识别那一刻的；这里按现在的文件数重排，和地图上显示的数字一致。
        domains.sort { $0.classCount != $1.classCount ? $0.classCount > $1.classCount : $0.title < $1.title }

        if let shared = modulesByDomain[StructureAssigner.sharedDomainID], !shared.isEmpty {
            domains.append(StructureDomain(
                id: StructureAssigner.sharedDomainID,
                title: "共享基建",
                keys: [],
                kind: .shared,
                modules: sorted(shared)
            ))
        }
        if let rest = modulesByDomain[StructureAssigner.unassignedDomainID], !rest.isEmpty {
            domains.append(StructureDomain(
                id: StructureAssigner.unassignedDomainID,
                title: "未划分",
                keys: [],
                kind: .unassigned,
                modules: sorted(rest)
            ))
        }

        var index = StructureIndex()
        index.domains = domains
        index.assigner = assigner
        index.rebuildLookup()
        return index
    }

    private mutating func rebuildLookup() {
        domainIndex = [:]
        moduleIndex = [:]
        fileModule = [:]
        for (domainOffset, domain) in domains.enumerated() {
            domainIndex[domain.id] = domainOffset
            for (moduleOffset, module) in domain.modules.enumerated() {
                moduleIndex[module.id] = (domainOffset, moduleOffset)
                for file in module.files {
                    fileModule[file.path] = module.id
                }
            }
        }
    }

    // MARK: 自检

    /// 检查三条不变量，返回违反项。空数组表示全部通过。
    func violations(packages: [ScannedPackage]) -> [String] {
        var problems: [String] = []

        // 1. 全覆盖：每个扫描到的文件恰好出现一次。
        let scanned = packages.flatMap(\.files)
        let indexed = domains.flatMap { $0.modules.flatMap { $0.files.map(\.path) } }
        if indexed.count != scanned.count {
            problems.append("全覆盖：扫描到 \(scanned.count) 个文件，索引里有 \(indexed.count) 个")
        }
        let unique = Set(indexed)
        if unique.count != indexed.count {
            problems.append("全覆盖：有 \(indexed.count - unique.count) 个文件出现在多个模块里")
        }
        let missing = Set(scanned).subtracting(unique)
        if !missing.isEmpty {
            let sample = missing.sorted().prefix(2).joined(separator: "、")
            problems.append("全覆盖：\(missing.count) 个文件没有落到任何模块，例如 \(sample)")
        }

        // 2. 守恒：域的类数等于模块类数之和。按构造恒成立，这里防的是以后有人改了口径。
        for domain in domains {
            let sum = domain.modules.reduce(0) { $0 + $1.files.count }
            if sum != domain.classCount {
                problems.append("守恒：\(domain.title) 的类数 \(domain.classCount) 不等于模块之和 \(sum)")
            }
        }

        // 3. 唯一：模块标识全图唯一。
        var seen = Set<String>()
        for module in domains.flatMap(\.modules) where !seen.insert(module.id).inserted {
            problems.append("唯一：模块 \(module.id) 出现在多个域下")
        }
        return problems
    }
}

// MARK: - 加载

extension StructureIndex {

    /// 扫一遍目录并建索引。扫描在后台线程跑。
    static func load(root: URL, graph: MindGraph) async -> StructureIndex {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let packages = DomainAnalyzer.scanPackages(root: root)
                continuation.resume(returning: build(packages: packages, graph: graph))
            }
        }
    }
}
