//
//  WikiArchitecturePlanner.swift
//  CodeEdit
//
//  让模型读依赖图，把模块聚成「域」，并给每个域定层。
//
//  为什么不是直接按目录切：
//  目录只表达「文件放在哪」，不表达「谁和谁是一件事」。
//  实测 saas 仓库 232 个单元里，`agent/memory/{mapper,entity,service}` 目录上分三处，
//  但依赖上高度内聚，人看应该是同一个「Agent 记忆」域；
//  反过来 `service/db/mapper` 下几十个 Mapper 目录上是一处，依赖上却分别服务不同业务。
//
//  做法是两阶段，避免把 232 个模块直接丢给模型：
//  1. 代码先按归一化路径的前两段粗分，得到 30–60 个候选组（确定性、零成本）；
//  2. 模型只看「候选组 + 组间依赖」，做合并、重命名、定层。
//     输入缩小一个数量级，模型的任务也从「聚类 232 个点」变成「合并 40 个块」，
//     稳定得多。
//

import Foundation

// MARK: - 输入单元

struct ArchitectureUnit: Sendable {
    /// 归一化后的模块名（如 `agent/memory/mapper`）。
    let name: String
    let fileCount: Int
}

// MARK: - 规划器

@MainActor
enum WikiArchitecturePlanner {

    /// 候选组：由目录粗分出来的块，交给模型合并。
    struct CandidateGroup: Sendable {
        let key: String
        var modules: [String]
        var fileCount: Int
        var fanIn: Int
        var fanOut: Int
        /// 指向其它候选组的边（组名, 权重）。
        var edges: [(String, Int)]
    }

    /// 域数量上限。低于 5 个通常说明合过头了，高于 9 个人记不住。
    static let maxDomains = 8
    static let minDomains = 4

    // MARK: 入口

    static func plan(
        units: [ArchitectureUnit],
        edges: [WikiModuleEdge],
        modelLabel: String
    ) async throws -> WikiArchitecture {
        let groups = candidateGroups(units: units, edges: edges)
        guard !groups.isEmpty else {
            throw WikiCuratorError.emptyContent
        }

        // 组本来就少，说明这个仓库结构简单，不必动用模型。
        if groups.count <= minDomains + 1 {
            return directAssembly(groups: groups, modelLabel: modelLabel)
        }

        let object = try await askModel(groups: groups)
        var architecture = assemble(object: object, groups: groups)
        if architecture.domains.isEmpty {
            architecture = directAssembly(groups: groups, modelLabel: modelLabel)
        }
        architecture.generatedBy = modelLabel
        architecture.generatedAt = Date().timeIntervalSince1970
        architecture.moduleCount = units.count
        return architecture
    }

    // MARK: 阶段一：确定性粗分

    static func candidateGroups(
        units: [ArchitectureUnit],
        edges: [WikiModuleEdge]
    ) -> [CandidateGroup] {
        // 模块 → 组
        var groupOfModule: [String: String] = [:]
        var buckets: [String: [String]] = [:]
        for unit in units {
            let key = groupKey(for: unit.name)
            groupOfModule[unit.name] = key
            buckets[key, default: []].append(unit.name)
        }

        var groups: [String: CandidateGroup] = [:]
        for (key, modules) in buckets {
            let files = units.filter { modules.contains($0.name) }.reduce(0) { $0 + $1.fileCount }
            groups[key] = CandidateGroup(
                key: key, modules: modules, fileCount: files,
                fanIn: 0, fanOut: 0, edges: []
            )
        }

        // 跨组的边
        var crossWeight: [String: [String: Int]] = [:]
        for edge in edges {
            guard let from = groupOfModule[edge.from],
                  let to = groupOfModule[edge.to],
                  from != to else { continue }
            crossWeight[from, default: [:]][to, default: 0] += edge.count
            groups[from]?.fanOut += edge.count
            groups[to]?.fanIn += edge.count
        }
        for (from, targets) in crossWeight {
            groups[from]?.edges = targets
                .sorted { $0.value > $1.value }
                .prefix(4)
                .map { ($0.key, $0.value) }
        }

        // 小分组并入「其他」，避免几十个只有一两个文件的碎块稀释模型注意力。
        let sorted = groups.values.sorted { $0.fileCount > $1.fileCount }
        var result: [CandidateGroup] = []
        var overflowModules: [String] = []
        for (index, group) in sorted.enumerated() {
            if index < 60 || group.fileCount >= 4 {
                result.append(group)
            } else {
                overflowModules.append(contentsOf: group.modules)
            }
        }
        if !overflowModules.isEmpty {
            result.append(CandidateGroup(
                key: "其他", modules: overflowModules,
                fileCount: overflowModules.count, fanIn: 0, fanOut: 0, edges: []
            ))
        }
        return result
    }

    /// 归一化名取前两段做组键；只有一段就用它本身。
    static func groupKey(for name: String) -> String {
        let parts = name.split(separator: "/")
        if parts.count <= 1 { return name }
        return parts.prefix(2).joined(separator: "/")
    }

    // MARK: 阶段二：模型合并

    private static func askModel(groups: [CandidateGroup]) async throws -> [String: Any] {
        var lines: [String] = []
        lines.append("候选分组（由目录粗分得出，可能过细，也可能把同一件事切碎了）：")
        for group in groups.sorted(by: { $0.fileCount > $1.fileCount }) {
            lines.append(
                "- \(group.key) | 模块 \(group.modules.count) 个 | 文件 \(group.fileCount) | 被依赖 \(group.fanIn) 次 | 依赖他人 \(group.fanOut) 次"
            )
            if !group.edges.isEmpty {
                let text = group.edges.map { "\($0.0)(\($0.1))" }.joined(separator: "、")
                lines.append("    依赖：\(text)")
            }
        }

        let system = """
        你在为一个代码仓库做架构划分。输入是静态分析得到的「候选分组」及其依赖关系。
        把这些分组合并成 \(minDomains)–\(maxDomains) 个「域」，每个域回答：它负责什么、属于哪一层、边界在哪。

        分层只有五种，按依赖方向从外到内：
        entry=对外接口（controller/router/handler）
        business=编排多个领域完成一个用例（service/manager/biz）
        domain=核心业务逻辑与模型
        data=存储访问（mapper/repository/dao/entity）
        infrastructure=被所有层依赖的工具、配置、异常、过滤器

        只输出 JSON，不要解释：
        {"domains":[{"name":"4-8字中文域名","layer":"entry|business|domain|data|infrastructure",
        "purpose":"一句话说明负责什么，不超过40字",
        "groups":["候选组名"],"keyRules":["最多3条，每条不超过25字"]}]}

        规则：
        - 每个候选组必须且只能出现在一个域的 groups 里，不要遗漏、不要编造新组名
        - 优先按「依赖内聚」合并，而不是按目录名字相似
        - keyRules 写这个域的硬约束（改了会出事的那种），没有就给空数组
        """

        let request = AINarrativeStore.shared.makeRequest(
            system: system,
            user: lines.joined(separator: "\n")
        )
        guard let request, let kind = providerKind() else {
            throw WikiCuratorError.notConfigured(
                AINarrativeStore.shared.blockedReason ?? "模型未配置"
            )
        }
        return try await completeJSON(kind: kind, request: request)
    }

    // MARK: 组装

    private static func assemble(
        object: [String: Any],
        groups: [CandidateGroup]
    ) -> WikiArchitecture {
        guard let items = object["domains"] as? [[String: Any]] else {
            return .empty
        }
        let byKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })

        var architecture = WikiArchitecture()
        var used = Set<String>()

        for item in items {
            guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            let layer = WikiLayer(rawValue: item["layer"] as? String ?? "") ?? .domain
            let purpose = (item["purpose"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let keys = (item["groups"] as? [String] ?? []).filter { byKey[$0] != nil }
            guard !keys.isEmpty else { continue }

            var modules: [String] = []
            for key in keys {
                guard let group = byKey[key] else { continue }
                modules.append(contentsOf: group.modules)
                used.insert(key)
            }
            let rules = (item["keyRules"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(3)

            architecture.domains.append(WikiDomain(
                name: name,
                layer: layer,
                purpose: purpose,
                modules: modules,
                keyRules: Array(rules)
            ))
            for module in modules {
                architecture.domainOfModule[module] = name
            }
        }

        // 模型漏掉的组不能丢：单独归入「其他」，并标注层为领域。
        let leftovers = groups.filter { !used.contains($0.key) }
        if !leftovers.isEmpty {
            let modules = leftovers.flatMap(\.modules)
            architecture.domains.append(WikiDomain(
                name: "其他",
                layer: .domain,
                purpose: "模型划分未覆盖的模块，建议人工确认",
                modules: modules,
                keyRules: []
            ))
            for module in modules {
                architecture.domainOfModule[module] = "其他"
            }
        }
        // 模型编造了不存在的组名时，上面会静默丢弃；这里补齐所有模块的归属。
        for group in groups {
            for module in group.modules where architecture.domainOfModule[module] == nil {
                architecture.domainOfModule[module] = architecture.domains.first?.name ?? "其他"
            }
        }
        return architecture
    }

    /// 分组少时的直连路径：一组一域，层由名字启发式判断。
    private static func directAssembly(
        groups: [CandidateGroup],
        modelLabel: String
    ) -> WikiArchitecture {
        var architecture = WikiArchitecture()
        for group in groups.sorted(by: { $0.fileCount > $1.fileCount }) {
            let name = group.key
            architecture.domains.append(WikiDomain(
                name: name,
                layer: inferredLayer(for: name),
                purpose: "\(group.fileCount) 个文件",
                modules: group.modules,
                keyRules: []
            ))
            for module in group.modules {
                architecture.domainOfModule[module] = name
            }
        }
        architecture.generatedBy = modelLabel
        architecture.generatedAt = Date().timeIntervalSince1970
        return architecture
    }

    /// 名字启发式定层，只在没有模型结果时兜底。
    static func inferredLayer(for name: String) -> WikiLayer {
        let lower = name.lowercased()
        if ["controller", "api", "router", "handler", "endpoint", "web"].contains(where: lower.contains) {
            return .entry
        }
        if ["mapper", "repository", "dao", "entity", "db", "sql", "jdbc"].contains(where: lower.contains) {
            return .data
        }
        if ["config", "util", "common", "exception", "filter", "constant", "helper"].contains(where: lower.contains) {
            return .infrastructure
        }
        if ["service", "manager", "biz", "usecase"].contains(where: lower.contains) {
            return .business
        }
        return .domain
    }

    // MARK: 模型调用

    private static func providerKind() -> AIProviderKind? {
        let config = AINarrativeStore.shared.configuration
        return config.mode == .ccSwitchProxy ? .anthropic : config.provider
    }

    private static func completeJSON(
        kind: AIProviderKind,
        request: AINarrativeRequest
    ) async throws -> [String: Any] {
        do {
            // 一次要输出 6 个域的完整描述，4096 常被推理吃光，这里给足。
            return try await WikiModelClient.callJSON(
                kind: kind,
                request: request,
                budgets: [8192, 8192]
            )
        } catch {
            throw WikiCuratorError.invalidResponse(AINarrativeError.describe(error))
        }
    }
}
