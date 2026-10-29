//
//  WikiArchitectureBuilder.swift
//  CodeEdit
//
//  把「扫代码 → 建依赖图 → 归一化命名 → 模型划分域」串成一条链路。
//
//  单独拆出来是因为这四步各有代价：扫描要遍历整个文件树、建图要读每个文件的头部、
//  归一化是纯计算、划分要跑一次模型。全部放主线程会卡住界面，所以要能整体挪到后台。
//

import Foundation

@MainActor
enum WikiArchitectureBuilder {

    struct Result {
        var architecture: WikiArchitecture
        var domainEdges: [WikiDomainEdge]
        var moduleCount: Int
    }

    /// 生成（或重建）架构视图。耗时主要在扫描与一次模型调用。
    static func build(root: URL) async throws -> Result {
        let (units, _) = await Task.detached(priority: .userInitiated) {
            WikiRepoIngest.scan(root: root, maxFiles: 100_000, maxModules: 600)
        }.value
        guard !units.isEmpty else {
            throw WikiCuratorError.emptyContent
        }

        let names = units.map(\.name)
        let shortNames = WikiPathNormalizer.normalize(names)

        let graph = await Task.detached(priority: .userInitiated) {
            WikiDependencyGraph.build(root: root, modules: units)
        }.value

        // 图的边用的是原始模块名，统一换成短名，后面域聚合才对得上。
        let map = Dictionary(uniqueKeysWithValues: zip(names, shortNames))
        let edges = graph.edges.map {
            WikiModuleEdge(
                from: map[$0.from] ?? $0.from,
                to: map[$0.to] ?? $0.to,
                count: $0.count,
                samples: $0.samples
            )
        }
        let architectureUnits = units.enumerated().map {
            ArchitectureUnit(name: shortNames[$0.offset], fileCount: $0.element.files.count)
        }

        var architecture = try await WikiArchitecturePlanner.plan(
            units: architectureUnits,
            edges: edges,
            modelLabel: AINarrativeStore.shared.providerLabel
        )
        architecture.domainEdges = architecture.aggregate(edges)
        architecture.save(root: root)

        return Result(
            architecture: architecture,
            domainEdges: architecture.aggregate(edges),
            moduleCount: architectureUnits.count
        )
    }
}
