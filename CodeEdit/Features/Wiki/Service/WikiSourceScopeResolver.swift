import Foundation

struct WikiSourceScopeResolution: Sendable {
    var scopes: [String] = []
    var sources: [String] = []
    var issues: [WikiEvidenceIssue] = []
    var mappings: [String: String] = [:]
}

/// 只按结构扫描还原 Java 业务简称；完整 repo 路径优先，多源码模块同名时不猜。
struct WikiSourceScopeResolver {
    private let root: URL
    private let javaSourcePrefixes: [String]

    init(root: URL) {
        self.root = root
        let scans = DomainAnalyzer.scanModules(javaRoots: DomainAnalyzer.findJavaRoots(root))
        javaSourcePrefixes = scans.map { scan in
            let sourceRoot = WikiRepoIngest.relativePath(of: scan.root, root: root)
            return ([sourceRoot] + scan.prefix).filter { !$0.isEmpty }.joined(separator: "/")
        }.sorted()
    }

    func resolve(_ paths: [String]) throws -> WikiSourceScopeResolution {
        var result = WikiSourceScopeResolution()
        for path in Array(Set(paths)).sorted() {
            try Task.checkCancellation()
            guard let direct = WikiSourceInspector.resolvedFile(path, root: root) else {
                result.issues.append(.init(kind: .scopeUnbound, path: path, detail: "不是安全的仓库相对路径"))
                continue
            }
            var isDirectory: ObjCBool = false
            var candidates: [String] = []
            if FileManager.default.fileExists(atPath: direct.path, isDirectory: &isDirectory) {
                candidates = [path]
            } else {
                for prefix in javaSourcePrefixes {
                    let candidate = prefix + "/" + path
                    guard let url = WikiSourceInspector.resolvedFile(candidate, root: root) else { continue }
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        candidates.append(candidate)
                    }
                }
            }
            candidates = Array(Set(candidates)).sorted()
            guard candidates.count == 1, let resolved = candidates.first else {
                result.issues.append(.init(kind: .scopeUnbound, path: path,
                    detail: candidates.isEmpty ? "未找到实际目录；请补充完整源码路径" : "多个源码模块都有这个业务包，不能自动选择：" + candidates.joined(separator: "、")))
                continue
            }
            result.scopes.append(resolved)
            result.mappings[path] = resolved
        }
        // 一个完整父目录已经包含子目录，避免重复读取与膨胀的范围快照。
        let ordered = Array(Set(result.scopes)).sorted { $0.count < $1.count }
        var minimal: [String] = []
        for scope in ordered where !minimal.contains(where: { WikiKnowledgeContext.matches(source: $0, path: scope) }) {
            minimal.append(scope)
        }
        result.scopes = minimal.sorted()
        result.sources = try WikiGenerationSources.files(in: result.scopes, root: root)
        return result
    }
}

extension WikiStore {
    /// 只在用户点击时生成来源绑定建议，不直接重写已有确认内容，更不自动转绿。
    func proposeSourceBinding(for entry: WikiEntry) async throws -> WikiEntry {
        guard entry.proposalFor == nil, !entry.scopePaths.isEmpty, entry.sources.isEmpty else {
            throw WikiGenerationError.invalidOutput("此入口用于尚未绑定实际文件的范围型知识；其它变化请对照原文手动核对。")
        }
        try requireUnchangedOnDisk(entry)
        let root = root
        let prepared = try await WikiBackgroundWork.run {
            let resolution = try WikiSourceScopeResolver(root: root).resolve(entry.scopePaths)
            guard resolution.issues.isEmpty, !resolution.sources.isEmpty else {
                throw WikiGenerationError.invalidOutput(resolution.issues.prefix(3).map {
                    ($0.path ?? "范围") + "：" + $0.detail
                }.joined(separator: "\n") + (resolution.sources.isEmpty ? "\n未找到实际文件来源" : ""))
            }
            let receipts = try WikiGenerationSources.capture(paths: resolution.sources, root: root)
            let scopes = try resolution.scopes.map { try WikiGenerationSources.scopeSnapshot($0, root: root) }
            let provenance = WikiGenerationProvenance(
                inputDigest: WikiGenerationPolicy.fingerprint(resolution.mappings.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }),
                pipeline: "manual-source-binding-v1", sources: receipts, scopeSnapshots: scopes,
                basis: "业务包简称唯一映射到实际源码范围；正文保留，是否成立仍需人工核对"
            )
            return (resolution, provenance)
        }
        try Task.checkCancellation()
        try requireUnchangedOnDisk(entry)
        guard let current = self.entry(id: entry.id),
              WikiKnowledgeReview.contentDigest(current) == WikiKnowledgeReview.contentDigest(entry) else {
            throw WikiKnowledgeError.changedOnDisk
        }
        let draft = WikiDraft(action: .update, target: entry.title, title: entry.title, type: entry.type,
            tags: entry.tags, relations: entry.relations, body: entry.body,
            reason: "只补全真实来源与范围，原文未改；请对照后接受更新", sources: prepared.0.sources,
            mergeMode: .replace, targetID: entry.id, scopePaths: prepared.0.scopes, provenance: prepared.1)
        return try applyDraft(draft, generatedBy: entry.generatedBy, sources: draft.sources)
    }
}
