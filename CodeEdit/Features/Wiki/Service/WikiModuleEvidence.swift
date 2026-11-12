// 模块调度按完整输入版本判断，文件缓存只决定哪些文件需要重新理解。
import Foundation

struct WikiModuleEvidence: Sendable {
    let module: RepoModule
    let sources: [WikiSourceSnapshot]
    let scopePaths: [String]
    let scopes: [WikiSourceSnapshot]
    let knowledge: WikiContextSnapshot
    let domainInputs: [WikiSourceSnapshot]
    let basisDigest: String

    static func capture(module: RepoModule, root: URL, graph: WikiDependencyGraph, pipelineKey: String) throws -> Self {
        let paths = module.files.map(\.path).sorted()
        let sources = try WikiGenerationSources.capture(paths: paths, root: root)
        let scopePaths: [String]
        if module.granularity == .singleFile { scopePaths = [] }
        else {
            let directory = module.granularity == .folder ? module.name : module.files.first?.directory ?? ""
            scopePaths = [directory.isEmpty ? "." : directory]
        }
        let scopes = try scopePaths.map { try WikiGenerationSources.scopeSnapshot($0, root: root) }
        let domainInputs = try WikiGenerationSources.capture(
            paths: [".qiyide/wiki/domains.locked.json"], root: root, allowMissing: true
        )
        let knowledge = WikiKnowledgeContext.loadNow(root: root, paths: paths, referenceOnly: true)
        let parts = sources.map { $0.path + "=" + ($0.digest ?? "missing") }
            + scopes.map { "scope:" + $0.path + "=" + ($0.digest ?? "missing") }
            + domainInputs.map { $0.path + "=" + ($0.digest ?? "missing") }
            + [module.name, pipelineKey, WikiGenerationPolicy.modulePromptVersion, graph.context(for: module.name), knowledge.fingerprint]
        return .init(module: module, sources: sources, scopePaths: scopePaths, scopes: scopes,
                     knowledge: knowledge, domainInputs: domainInputs, basisDigest: WikiGenerationPolicy.fingerprint(parts))
    }

    /// 源码删除、目录新增、模型/提取策略改变或人类依据改变，都使模块重新进入队列。
    func isProcessed(job: WikiCurationJob, entries: [WikiEntry]) -> Bool {
        guard let checkpoint = job.moduleCheckpoints?[module.name], checkpoint.basisDigest == basisDigest else { return false }
        if checkpoint.noKnowledgeReason != nil { return true }
        guard let id = checkpoint.entryID, let entry = entries.first(where: { $0.id == id }),
              checkpoint.entryDigest == WikiKnowledgeReview.contentDigest(entry),
              Set(entry.sources).isSuperset(of: Set(sources.map(\.path))) else { return false }
        return true
    }

    func provenance(pipeline: String, input: String) -> WikiGenerationProvenance {
        .init(inputDigest: WikiGenerationPolicy.fingerprint([basisDigest, input]), pipeline: pipeline,
              sources: sources, scopeSnapshots: scopes, contextFingerprint: knowledge.fingerprint,
              contextPaths: sources.map(\.path), additionalInputs: domainInputs)
    }
}
