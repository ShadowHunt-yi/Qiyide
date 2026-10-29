//
//  ViewSpec.swift
//  CodeEdit
//
//  视角规格：描述「同一份领域模型应该被画成哪张图」。
//
//  为什么需要它：
//  业务方和技术方看的是同一批代码，但关心的问题不同——
//  业务方要「有哪些能力、共享的支撑沉在基建层」，
//  技术方要「分了哪些层、基建代码和各层并列」。
//  差异集中在一点：**共享依赖算谁的**。所以把它单独抽成一个字段，
//  而不是维护两份数据——数据只改一处，视图按规格现投影。
//

import Foundation

// MARK: - 维度

/// 顶层怎么分组。
enum ViewAxis: String, Codable, CaseIterable, Sendable {
    /// 业务能力：域平铺，共享依赖沉到基建层。
    case business
    /// 技术分层：入口 / 业务 / 领域 / 数据 / 基建。
    case technical
    /// 变更影响：以改动模块为起点向外扩散。
    case impact
    /// 数据契约：围绕表与实体。
    case data
    /// 团队归属：以负责人为中心。
    case ownership

    var title: String {
        switch self {
        case .business: return "业务能力"
        case .technical: return "技术分层"
        case .impact: return "变更影响"
        case .data: return "数据契约"
        case .ownership: return "团队归属"
        }
    }
}

/// 共享依赖（被 ≥2 个域引用的包）在图上放哪。
enum SharedDependencyPolicy: String, Codable, CaseIterable, Sendable {
    /// 上提到「基础设施」层，各域不再重复出现。业务视角用这个。
    case hoist
    /// 作为普通代码模块留在原处。技术视角用这个。
    case keep
    /// 复制到每个引用它的域下（虚线引用）。影响分析用这个。
    case duplicate
    /// 隐藏，边折叠。用于简化视图。
    case hide

    var title: String {
        switch self {
        case .hoist: return "上提到基建层"
        case .keep: return "作为代码保留"
        case .duplicate: return "复制到各域"
        case .hide: return "隐藏"
        }
    }
}

/// 节点展开到哪一层。
enum ViewGranularity: String, Codable, CaseIterable, Sendable {
    /// 只看域。
    case domainOnly
    /// 域 + 模块。
    case domainAndModule
    /// 直接看模块，不聚合到域。
    case moduleOnly

    var title: String {
        switch self {
        case .domainOnly: return "仅领域"
        case .domainAndModule: return "领域 + 模块"
        case .moduleOnly: return "仅模块"
        }
    }
}

/// 边的语义。决定连线怎么解释、要不要按权重加粗。
enum ViewEdgeSemantics: String, Codable, CaseIterable, Sendable {
    /// 静态 import 依赖。
    case dependency
    /// 影响传播方向（反向依赖）。
    case propagation
    /// 读写关系。
    case dataFlow
    /// 提交共同出现（隐性耦合）。
    case coChange
    /// 归属关系（owner）。
    case ownership

    var title: String {
        switch self {
        case .dependency: return "依赖"
        case .propagation: return "影响传播"
        case .dataFlow: return "数据读写"
        case .coChange: return "共同变更"
        case .ownership: return "归属"
        }
    }
}

// MARK: - 规格

struct ViewSpec: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var axis: ViewAxis
    var granularity: ViewGranularity
    var sharedPolicy: SharedDependencyPolicy
    var edgeSemantics: ViewEdgeSemantics

    var summary: String {
        "\(axis.title) · \(granularity.title) · 共享依赖\(sharedPolicy.title)"
    }

    // MARK: 预设

    /// 五个常用视角。字段顺序即切换器里的顺序。
    static let presets: [ViewSpec] = [
        ViewSpec(
            id: "preset.business",
            name: "业务能力图",
            axis: .business,
            granularity: .domainAndModule,
            sharedPolicy: .hoist,
            edgeSemantics: .dependency
        ),
        ViewSpec(
            id: "preset.technical",
            name: "技术架构图",
            axis: .technical,
            granularity: .domainAndModule,
            sharedPolicy: .keep,
            edgeSemantics: .dependency
        ),
        ViewSpec(
            id: "preset.impact",
            name: "变更影响图",
            axis: .impact,
            granularity: .moduleOnly,
            sharedPolicy: .duplicate,
            edgeSemantics: .propagation
        ),
        ViewSpec(
            id: "preset.data",
            name: "数据契约图",
            axis: .data,
            granularity: .moduleOnly,
            sharedPolicy: .hide,
            edgeSemantics: .dataFlow
        ),
        ViewSpec(
            id: "preset.ownership",
            name: "团队归属图",
            axis: .ownership,
            granularity: .domainAndModule,
            sharedPolicy: .keep,
            edgeSemantics: .ownership
        )
    ]

    static var defaultSpec: ViewSpec { presets[0] }

    /// 自定义视角的空白模板，界面上让用户填完再保存。
    static func custom(name: String) -> ViewSpec {
        ViewSpec(
            id: "custom." + UUID().uuidString.prefix(8),
            name: name,
            axis: .business,
            granularity: .domainAndModule,
            sharedPolicy: .hoist,
            edgeSemantics: .dependency
        )
    }
}

// MARK: - 存取

/// 自定义视角存到 `.qiyide/wiki/viewspec/`，可以随仓库分享给团队。
enum ViewSpecStore {

    static func directory(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/viewspec", directoryHint: .isDirectory)
    }

    static func loadAll(root: URL) -> [ViewSpec] {
        let dir = directory(root: root)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ViewSpec.self, from: data)
            }
            .sorted { $0.name < $1.name }
    }

    static func save(_ spec: ViewSpec, root: URL) {
        let dir = directory(root: root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(spec) else { return }
        let name = spec.name.replacingOccurrences(of: "/", with: "-")
        try? data.write(to: dir.appending(path: "\(name).json"), options: .atomic)
    }

    static func delete(_ spec: ViewSpec, root: URL) {
        let name = spec.name.replacingOccurrences(of: "/", with: "-")
        try? FileManager.default.removeItem(at: directory(root: root).appending(path: "\(name).json"))
    }
}
