//
//  WikiArchitectureBuilder.swift
//  CodeEdit
//
//  生成候选与可靠提交分开。保存失败可重试，不重复调用模型；旧图一直保留。
//

import CryptoKit
import Foundation

@MainActor
enum WikiArchitectureBuilder {
    struct Result: Sendable {
        var architecture: WikiArchitecture
        var domainEdges: [WikiDomainEdge]
        var moduleCount: Int
        var sourceCount: Int = 0
        var inputDigest: String = ""
        /// 只保存在内存，不能写入产物或日志；用于拒绝配置变化后的旧结果。
        var modelSignature: String?
    }

    typealias ProgressHandler = @MainActor @Sendable (WikiOperationProgress) -> Void

    static func build(
        root: URL,
        mode: WikiArchitectureMode = .automatic,
        onProgress: @escaping ProgressHandler = { _ in }
    ) async throws -> Result {
        let result = try await prepare(root: root, mode: mode, onProgress: onProgress)
        try await commit(result, root: root, onProgress: onProgress)
        return result
    }

    static func prepare(
        root: URL,
        mode: WikiArchitectureMode,
        onProgress: @escaping ProgressHandler
    ) async throws -> Result {
        try Task.checkCancellation()
        onProgress(.init(.prepare, "检查项目可读性与执行方式"))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        if mode == .automatic, !AINarrativeStore.shared.isReady {
            throw WikiCuratorError.notConfigured(AINarrativeStore.shared.blockedReason ?? "模型未配置")
        }
        let signature = mode == .automatic ? try modelSignature() : nil
        let modelLabel = mode == .staticOnly ? "静态分析" : AINarrativeStore.shared.providerLabel
        onProgress(.init(.scan, "正在读取代码；总量尚未确定"))
        let input = try await WikiBackgroundWork.run {
            try WikiArchitectureInput.capture(root: root) { count in
                Task { @MainActor in
                    onProgress(.init(.scan, "已发现 \(count) 个源文件；总量尚未确定", completed: count))
                }
            }
        }
        try Task.checkCancellation()
        let units = try await WikiBackgroundWork.run {
            try Task.checkCancellation()
            let all = WikiKnowledgeSegmentation.segment(files: input.files)
            let selected = WikiRepoIngest.selectUnits(Array(all.prefix(600)), budget: 100_000)
            try Task.checkCancellation()
            return selected
        }
        guard !units.isEmpty else {
            throw WikiArchitectureBuildError.noSources
        }
        onProgress(.init(.dependencies, "扫描完成：\(input.files.count) 个源文件，\(units.count) 个模块"))
        let graph = try await WikiBackgroundWork.run {
            let graph = WikiDependencyGraph.build(root: root, modules: units) { count, total in
                Task { @MainActor in
                    onProgress(.init(.dependencies, "已解析 \(count)/\(total) 份文件证据", completed: count, total: total))
                }
            }
            try Task.checkCancellation()
            return graph
        }
        try Task.checkCancellation()
        try validateModelSignature(signature)
        let names = units.map(\.name)
        let shortNames = WikiPathNormalizer.normalize(names)
        let mapping = Dictionary(uniqueKeysWithValues: zip(names, shortNames))
        let edges = graph.edges.map {
            WikiModuleEdge(
                from: mapping[$0.from] ?? $0.from, to: mapping[$0.to] ?? $0.to,
                count: $0.count, samples: $0.samples
            )
        }
        let architectureUnits = units.enumerated().map {
            ArchitectureUnit(name: shortNames[$0.offset], fileCount: $0.element.files.count)
        }
        onProgress(.init(.plan, mode == .staticOnly ? "静态划分，不调用模型" : "检查候选分组；必要时使用 AI 增强"))
        var architecture = try await WikiArchitecturePlanner.plan(
            units: architectureUnits, edges: edges, modelLabel: modelLabel,
            staticOnly: mode == .staticOnly
        ) { attempt, attempts in
            await onProgress(.init(
                .plan, "等待 \(modelLabel) 返回结构化划分", attempt: attempt, attempts: attempts
            ))
        }
        try Task.checkCancellation()
        try validateModelSignature(signature)
        architecture.domainEdges = architecture.aggregate(edges)
        architecture.generation?.inputDigest = input.digest
        let selectedCount = units.reduce(0) { $0 + $1.files.count }
        if selectedCount < input.files.count {
            architecture.generation?.warnings.append(
                "已分析 \(selectedCount)/\(input.files.count) 个源文件；模块或文件预算限制了范围"
            )
        }
        return Result(
            architecture: architecture, domainEdges: architecture.domainEdges,
            moduleCount: architectureUnits.count, sourceCount: input.files.count,
            inputDigest: input.digest, modelSignature: signature
        )
    }

    static func commit(
        _ result: Result,
        root: URL,
        onProgress: @escaping ProgressHandler
    ) async throws {
        try Task.checkCancellation()
        onProgress(.init(.validate, "核对源码内容；生成期间的改动不会被旧结果覆盖"))
        let current = try await WikiBackgroundWork.run {
            try WikiArchitectureInput.capture(root: root)
        }
        guard current.digest == result.inputDigest else { throw WikiArchitectureBuildError.changedInput }
        try validateModelSignature(result.modelSignature)
        try Task.checkCancellation()
        onProgress(.init(.save, "暂存并读取验证，然后原子替换；此步骤暂不可取消"))
        // 只有这个短暂提交阶段禁用取消。验证前仍可以取消整仓读盘。
        try await WikiBackgroundWork.run {
            try result.architecture.save(root: root)
        }
    }

    private static func modelSignature() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(AINarrativeStore.shared.configuration)
        let endpoint = AINarrativeStore.shared.resolvedEndpoint()
        data.append(contentsOf: (endpoint.baseURL + "\0" + endpoint.model + "\0" + endpoint.apiKey).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateModelSignature(_ signature: String?) throws {
        if let signature, signature != (try modelSignature()) {
            throw WikiArchitectureBuildError.changedConfiguration
        }
    }
}

enum WikiArchitectureBuildError: LocalizedError {
    case noSources, changedInput, changedConfiguration

    var errorDescription: String? {
        switch self {
        case .noSources:
            return "没有发现可分析的源代码。请检查项目范围；不需要先创建知识条目。"
        case .changedInput:
            return "生成期间源码已变化，本次候选未写入。请基于当前代码重新生成。"
        case .changedConfiguration:
            return "生成期间 AI 配置已变化，本次候选未写入。请重新生成。"
        }
    }
}
