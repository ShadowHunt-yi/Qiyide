//
//  WikiGeneration.swift
//  CodeEdit
//
//  来源属于读取时的版本，不属于模型返回时的文件时间戳。
//

import CryptoKit
import Foundation

struct WikiGenerationProvenance: Codable, Hashable, Sendable {
    var version = 1
    var inputDigest: String
    var pipeline: String
    var sources: [WikiSourceSnapshot]
    var scopeSnapshots: [WikiSourceSnapshot] = []
    var contextFingerprint: String?
    var basis = "代码观察或待核对推断，不是业务已实现的证明"
    var contextPaths: [String]?
    var additionalInputs: [WikiSourceSnapshot]?

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    func validate(root: URL, includeContext: Bool = true) throws {
        try WikiGenerationSources.validate(sources + (additionalInputs ?? []), root: root)
        try WikiGenerationSources.validateScopes(scopeSnapshots, root: root)
        if includeContext, let contextFingerprint {
            let current = WikiKnowledgeContext.loadNow(
                root: root, paths: contextPaths ?? sources.map(\.path), referenceOnly: true
            )
            guard current.fingerprint == contextFingerprint else { throw WikiGenerationError.changedContext }
        }
    }
}

/// 同一模型别名不能代表同一提取策略。键不含密钥或原始提示词。
enum WikiGenerationPolicy {
    static let filePromptVersion = "file-facts-v3"
    static let extractorVersion = "head-and-declarations-v2"
    static let redactionVersion = "shared-redaction-v1"
    static let modulePromptVersion = "module-evidence-v3"

    static func key(
        for request: AINarrativeRequest, kind: AIProviderKind? = nil,
        promptVersion: String = filePromptVersion
    ) -> String {
        fingerprint([
            promptVersion, extractorVersion, redactionVersion, kind?.rawValue ?? "unspecified",
            request.baseURL, request.model, String(request.temperature),
            digest(Data(request.systemPrompt.utf8))
        ])
    }

    static func fingerprint(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func isSingleLine(_ value: String, limit: Int = 200) -> Bool {
        value.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !value.contains("\u{2028}") && !value.contains("\u{2029}")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum WikiGenerationError: LocalizedError {
    case changedSource(String)
    case changedContext
    case invalidPath(String)
    case unreadableSource(String)
    case invalidOutput(String)
    case requestLimit
    case noKnowledge(String)

    var errorDescription: String? {
        switch self {
        case .changedSource(let path): return "来源已变化：\(path)。本次旧结果未写入，请重新生成。"
        case .changedContext: return "知识依据或模型配置在生成期间变化，本次结果未写入，请重新生成。"
        case .invalidPath(let path): return "不是仓库内的有效来源路径：\(path)"
        case .unreadableSource(let path): return "来源无法读取或超过读取上限：\(path)"
        case .invalidOutput(let reason): return "模型输出未通过校验：\(reason)"
        case .requestLimit: return "已达本次运行预算，未发送下一次请求；进度已保留，再次点击继续可开启新的有限额度。"
        case .noKnowledge(let reason): return "本次没有可沉淀的知识：\(reason)"
        }
    }
}

/// 先读一个版本并哈希，再从相同字节提取模型输入。不能另读文件给旧结果盖章。
enum WikiGenerationSources {
    static let maxFileBytes = 16 * 1_024 * 1_024

    static func read(path: String, root: URL) throws -> (data: Data, source: WikiSourceSnapshot) {
        guard let url = WikiSourceInspector.resolvedFile(path, root: root) else {
            throw WikiGenerationError.invalidPath(path)
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maxFileBytes else {
            throw WikiGenerationError.unreadableSource(path)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw WikiGenerationError.unreadableSource(path) }
        return (data, .init(path: path, digest: WikiGenerationPolicy.digest(data), issue: nil))
    }

    static func capture(paths: [String], root: URL, allowMissing: Bool = false) throws -> [WikiSourceSnapshot] {
        try Array(Set(paths)).sorted().map { path in
            try Task.checkCancellation()
            guard let url = WikiSourceInspector.resolvedFile(path, root: root) else {
                throw WikiGenerationError.invalidPath(path)
            }
            if allowMissing && !FileManager.default.fileExists(atPath: url.path) {
                return .init(path: path, digest: nil, issue: "读取时文件不存在；仅作为变更范围")
            }
            return try read(path: path, root: root).source
        }
    }

    static func validate(_ sources: [WikiSourceSnapshot], root: URL) throws {
        for old in sources {
            try Task.checkCancellation()
            guard let url = WikiSourceInspector.resolvedFile(old.path, root: root) else {
                throw WikiGenerationError.invalidPath(old.path)
            }
            if old.digest == nil {
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw WikiGenerationError.changedSource(old.path)
                }
            } else {
                guard try read(path: old.path, root: root).source.digest == old.digest else {
                    throw WikiGenerationError.changedSource(old.path)
                }
            }
        }
    }

    /// 范围是目录/域，不冒充文件。范围快照还要发现新增和删除的源文件。
    static func files(in scopes: [String], root: URL) throws -> [String] {
        var paths = Set<String>()
        for scope in Set(scopes) {
            try Task.checkCancellation()
            let directory = scope == "." ? root.standardizedFileURL.resolvingSymlinksInPath()
                : WikiSourceInspector.resolvedFile(scope, root: root)
            guard let directory else {
                throw WikiGenerationError.invalidPath(scope)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
                throw WikiGenerationError.unreadableSource(scope)
            }
            if !isDirectory.boolValue {
                paths.insert(scope)
                continue
            }
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in failure = error; return false }
            ) else { throw WikiGenerationError.unreadableSource(scope) }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                if WikiRepoIngest.skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
                guard WikiRepoIngest.sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                paths.insert(WikiRepoIngest.relativePath(of: url, root: root))
                guard paths.count <= 5_000 else { throw WikiGenerationError.unreadableSource(scope) }
            }
            if let failure { throw failure }
        }
        return paths.sorted()
    }

    static func scopeSnapshot(_ scope: String, root: URL) throws -> WikiSourceSnapshot {
        let files = try files(in: [scope], root: root)
        let receipts = try capture(paths: files, root: root)
        let parts = receipts.map { $0.path + "=" + ($0.digest ?? "missing") }
        return .init(path: scope, digest: WikiGenerationPolicy.fingerprint(parts), issue: nil)
    }

    static func validateScopes(_ snapshots: [WikiSourceSnapshot], root: URL) throws {
        for old in snapshots {
            guard try scopeSnapshot(old.path, root: root).digest == old.digest else {
                throw WikiGenerationError.changedSource(old.path)
            }
        }
    }
}
