//
//  WikiArchitecture.swift
//  CodeEdit
//
//  结构层：整个仓库的架构视图。
//
//  为什么单独成层：
//  依赖关系是静态分析算出来的事实，每次代码改动都会变。上一版把它写进知识正文，
//  结果占了正文 34.5% 的篇幅，而且 56% 的边指向还没建档的模块，成了永远修不好的死链。
//
//  现在依赖只存在于结构层：渲染架构图、给 AI 做邻域检索都从这里读，
//  知识正文只写「为什么」。
//

import Foundation

// MARK: - 分层

/// 系统层次。顺序即渲染顺序：入口在最上，基建在最下。
enum WikiLayer: String, Codable, Sendable, CaseIterable {
    case entry
    case business
    case domain
    case data
    case infrastructure

    var title: String {
        switch self {
        case .entry: return "入口"
        case .business: return "业务编排"
        case .domain: return "领域"
        case .data: return "数据访问"
        case .infrastructure: return "基础设施"
        }
    }

    /// 0 = 最上层。
    var order: Int {
        switch self {
        case .entry: return 0
        case .business: return 1
        case .domain: return 2
        case .data: return 3
        case .infrastructure: return 4
        }
    }
}

// MARK: - 域

/// 一个「域」= 人理解系统时的基本单位，通常 3–15 个模块。
struct WikiDomain: Codable, Sendable, Identifiable, Hashable {
    var name: String
    var layer: WikiLayer
    /// 一句话说明这个域负责什么，≤40 字。
    var purpose: String
    /// 成员模块（归一化后的名字）。
    var modules: [String]
    /// 最多 3 条硬规则，每条 ≤25 字。
    var keyRules: [String]

    var id: String { name }
}

// MARK: - 域间边

struct WikiDomainEdge: Codable, Sendable, Hashable {
    let from: String
    let to: String
    /// 底层模块边权之和，用来区分「偶尔调用」与「强依赖」。
    let weight: Int
    let samples: [String]
}

// MARK: - 架构

struct WikiArchitecture: Codable, Sendable {

    var domains: [WikiDomain] = []
    /// 域间依赖，随架构一起落盘，视图直接读。
    var domainEdges: [WikiDomainEdge] = []
    /// 模块名 → 域名的映射，用于把模块边聚合成域边。
    var domainOfModule: [String: String] = [:]
    /// 生成时的全仓模块数，用于判断是否需要重算。
    var moduleCount: Int = 0
    var generatedAt: Double = 0
    /// 产出这份划分的模型标识，换模型后可以判断是否重算。
    var generatedBy: String = ""

    static let empty = WikiArchitecture()

    var isEmpty: Bool { domains.isEmpty }

    // MARK: 查询

    func domain(of module: String) -> WikiDomain? {
        guard let name = domainOfModule[module] else { return nil }
        return domains.first { $0.name == name }
    }

    func domains(in layer: WikiLayer) -> [WikiDomain] {
        domains.filter { $0.layer == layer }
    }

    /// 按层分组，供架构图按行渲染。
    var layered: [(layer: WikiLayer, domains: [WikiDomain])] {
        WikiLayer.allCases
            .sorted { $0.order < $1.order }
            .map { ($0, domains(in: $0)) }
            .filter { !$0.1.isEmpty }
    }

    /// 把模块级依赖聚合成域级边，忽略域内边。
    func aggregate(_ moduleEdges: [WikiModuleEdge]) -> [WikiDomainEdge] {
        var weight: [String: Int] = [:]
        var samples: [String: [String]] = [:]

        for edge in moduleEdges {
            guard let from = domainOfModule[edge.from],
                  let to = domainOfModule[edge.to],
                  from != to else { continue }
            let key = "\(from)\u{1}\(to)"
            weight[key, default: 0] += edge.count
            if samples[key, default: []].count < 2 {
                samples[key, default: []].append("\(edge.from) → \(edge.to)")
            }
        }

        return weight.compactMap { key, value in
            let parts = key.split(separator: "\u{1}").map(String.init)
            guard parts.count == 2 else { return nil }
            return WikiDomainEdge(
                from: parts[0],
                to: parts[1],
                weight: value,
                samples: samples[key] ?? []
            )
        }
        .sorted { $0.weight > $1.weight }
    }

    /// 全局摘要：给 AI 的「系统分几层、每层有哪些域」，控制在 1200 token 内。
    func summaryText() -> String {
        var lines: [String] = []
        for (layer, domains) in layered {
            let names = domains.map { "\($0.name)（\($0.purpose)）" }.joined(separator: "；")
            lines.append("\(layer.title)：\(names)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 存取

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/architecture.json")
    }

    static func load(root: URL) -> WikiArchitecture {
        guard let data = try? Data(contentsOf: url(root: root)),
              let value = try? JSONDecoder().decode(WikiArchitecture.self, from: data) else {
            return .empty
        }
        return value
    }

    func save(root: URL) {
        let target = Self.url(root: root)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: target, options: .atomic)
    }
}
