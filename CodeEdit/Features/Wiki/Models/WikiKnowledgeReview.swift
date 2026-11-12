//
//  WikiKnowledgeReview.swift
//  CodeEdit
//
//  人的确认与来源新鲜度是两件事。确认只适用于当时的内容和来源，不能永久背书。
//

import CryptoKit
import Foundation

struct WikiSourceSnapshot: Codable, Hashable, Sendable {
    var path: String
    var digest: String?
    var issue: String?
}

struct WikiConfirmation: Codable, Hashable, Sendable {
    var version = 1
    var contentDigest: String
    var sources: [WikiSourceSnapshot]
    var confirmedAt: Date
    /// 无代码来源的规则/决策/术语只能作为人工约定，不能当作实现证明。
    var isAgreement: Bool
    var scopeSnapshots: [WikiSourceSnapshot]?
}

enum WikiKnowledgeState: String, CaseIterable, Sendable {
    case checking, draft, unreviewed, current, agreement, stale, unverifiable

    var title: String {
        switch self {
        case .checking: return "待校验"
        case .draft: return "待确认"
        case .unreviewed: return "历史待核验"
        case .current: return "已确认 · 来源未变"
        case .agreement: return "人工约定"
        case .stale: return "需重新核对"
        case .unverifiable: return "来源未核验"
        }
    }

    var canReference: Bool { self == .current || self == .agreement }
}

struct WikiKnowledgeAssessment: Hashable, Sendable {
    var state: WikiKnowledgeState
    var detail: String
    var changedSources: [String] = []
    var issues: [WikiEvidenceIssue] = []

    var nextStep: String {
        switch issues.first?.kind {
        case .emptyBody: return "先填写有实际含义的正文与来源，空正文不能作为依据。"
        case .scopeUnbound, .sourcesUnbound: return "先绑定仓库内的实际文件与范围，再对照原文接受来源更新；反复校验不能补出确认基线。"
        case .contentChanged: return "对照上次确认的内容核对改动，确认无误后重新确认。"
        case .scopeChanged, .sourceChanged: return "查看变化路径，核对知识是否仍成立；校验不会自动替你重新确认。"
        case .unreadable: return "检查文件是否存在、路径是否完整及读取预算；无法读取不等于代码发生了变化。"
        case .confirmationMissing: return "对照正文与来源，补充人工确认记录。"
        case nil: return state == .draft ? "人工核对正文和来源后确认；校验只检查版本，不确认业务含义。" : ""
        }
    }

    static let checking = Self(state: .checking, detail: "正在校验内容和来源；校验完成前不作为 AI 的依据。")
}

struct WikiKnowledgeReport: Sendable {
    var assessments: [String: WikiKnowledgeAssessment] = [:]
    var checkedAt: Date?
    var sourcesChecked = 0

    func assessment(for entry: WikiEntry) -> WikiKnowledgeAssessment {
        assessments[entry.id] ?? .checking
    }
}

enum WikiKnowledgeReview {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 不包含更新时间与确认本身；业务内容、来源、范围或生成者改变都会使确认失效。
    static func contentDigest(_ entry: WikiEntry) -> String {
        var object: [String: Any] = [
            "id": entry.id, "title": entry.title, "type": entry.type.rawValue,
            "tags": entry.tags.sorted(), "sources": entry.sources.sorted(),
            "domains": entry.domains.sorted(), "body": WikiEntry.canonicalBody(entry.body),
            "generated": entry.generatedBy,
            "relations": entry.relations.map { [$0.kind, $0.target] }.sorted { $0.lexicographicallyPrecedes($1) }
        ]
        // 空新增字段不改变旧文件摘要；旧确认不因格式兼容字段而全量失效。
        if !entry.scopePaths.isEmpty { object["scopePaths"] = entry.scopePaths.sorted() }
        if let provenance = entry.provenance, let data = try? provenance.encoded() {
            object["provenance"] = digest(data)
        }
        return digest((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    static func confirmationDigest(_ entry: WikiEntry) -> String {
        guard let receipt = entry.confirmation else { return "none" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return digest((try? encoder.encode(receipt)) ?? Data())
    }

    static func confirmation(for entry: WikiEntry, root: URL) -> WikiConfirmation {
        var inspector = WikiSourceInspector(root: root)
        return WikiConfirmation(
            contentDigest: contentDigest(entry),
            sources: Array(Set(entry.sources)).sorted().map { inspector.inspect($0) },
            confirmedAt: Date(),
            isAgreement: entry.sources.isEmpty && [.rule, .decision, .term].contains(entry.type),
            scopeSnapshots: entry.scopePaths.isEmpty ? nil : entry.scopePaths.map { scope in
                (try? WikiGenerationSources.scopeSnapshot(scope, root: root))
                    ?? .init(path: scope, digest: nil, issue: "范围无法核验")
            }
        )
    }

    static func evaluate(entries: [WikiEntry], root: URL) -> WikiKnowledgeReport {
        (try? evaluateChecked(entries: entries, root: root)) ?? .init()
    }

    /// 校验按条目和来源反馈；取消时不发布部分报告为完成，也不沿用旧绿色状态。
    static func evaluateChecked(
        entries: [WikiEntry], root: URL,
        onProgress: (@Sendable (WikiKnowledgeCheckProgress) -> Void)? = nil
    ) throws -> WikiKnowledgeReport {
        var inspector = WikiSourceInspector(root: root)
        var result: [String: WikiKnowledgeAssessment] = [:]
        var progress = WikiKnowledgeCheckProgress(totalEntries: entries.count)
        var lastNotification = Date.distantPast
        func emit(_ force: Bool = false) {
            let date = Date()
            if force || date.timeIntervalSince(lastNotification) >= 0.08 {
                onProgress?(progress)
                lastNotification = date
            }
        }
        emit(true)
        for entry in entries.sorted(by: { $0.id < $1.id }) {
            try Task.checkCancellation()
            progress.currentEntry = entry.title
            progress.currentPath = ""
            emit(true)
            result[entry.id] = try evaluate(entry, inspector: &inspector) { path in
                progress.checkedSources += 1
                progress.currentPath = path
                emit()
            }
            try Task.checkCancellation()
            progress.checkedEntries += 1
            emit(true)
        }
        progress.currentPath = ""
        emit(true)
        return WikiKnowledgeReport(assessments: result, checkedAt: Date(), sourcesChecked: progress.checkedSources)
    }

    private static func evaluate(
        _ entry: WikiEntry, inspector: inout WikiSourceInspector, sourceChecked: (String) -> Void
    ) throws -> WikiKnowledgeAssessment {
        if entry.isDraft || entry.proposalFor != nil {
            var changed: [String] = []
            for old in entry.provenance?.sources ?? [] {
                try Task.checkCancellation()
                let current = inspector.inspect(old.path)
                sourceChecked(old.path)
                if let oldDigest = old.digest, let digest = current.digest, oldDigest != digest { changed.append(old.path) }
            }
            if !changed.isEmpty {
                return .init(state: .draft, detail: "来源在生成后变化，请重新生成或人工核对后再确认。",
                             changedSources: changed, issues: changed.map { .init(kind: .sourceChanged, path: $0, detail: "生成后的来源已变化") })
            }
            return .init(state: .draft, detail: "尚未由人确认，不作为业务约定或当前实现的依据。")
        }
        guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(state: .unverifiable, detail: "正文为空，不能作为业务依据。",
                         issues: [.init(kind: .emptyBody, detail: "请先补充正文和实际来源")])
        }
        guard let receipt = entry.confirmation, receipt.version == 1 else {
            return .init(state: .unreviewed, detail: "保留原条目，但没有可核验的确认记录；不会自动带入 AI 上下文。",
                         issues: [.init(kind: .confirmationMissing, detail: "没有可核验的人工确认记录")])
        }
        guard receipt.contentDigest == contentDigest(entry) else {
            return .init(state: .stale, detail: "正文、范围或来源列表与确认时不同，请核对后重新确认。",
                         issues: [.init(kind: .contentChanged, detail: "当前内容摘要与确认版本不同")])
        }
        var issues: [WikiEvidenceIssue] = []
        var changed: [String] = []
        if !entry.scopePaths.isEmpty {
            let oldScopes = receipt.scopeSnapshots ?? []
            let byPath = Dictionary(oldScopes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            for scope in Array(Set(entry.scopePaths)).sorted() {
                try Task.checkCancellation()
                guard let old = byPath[scope], let oldDigest = old.digest else {
                    issues.append(.init(kind: .scopeUnbound, path: scope,
                        detail: "范围没有确认时的可核验快照；包简称不等于仓库实际路径。"))
                    sourceChecked(scope)
                    continue
                }
                let current = inspector.inspectScope(scope)
                sourceChecked(scope)
                if let digest = current.digest {
                    if oldDigest != digest {
                        changed.append(scope)
                        issues.append(.init(kind: .scopeChanged, path: scope, detail: "范围成员或内容与确认时不同"))
                    }
                } else {
                    issues.append(.init(kind: .unreadable, path: scope, detail: current.issue ?? "范围无法读取"))
                }
            }
            if Set(oldScopes.map(\.path)) != Set(entry.scopePaths) || oldScopes.count != Set(entry.scopePaths).count {
                issues.append(.init(kind: .scopeUnbound, detail: "范围列表与确认快照不完整对应"))
            }
        }
        // 无来源的人为规则可以是人工约定，但带范围的约定仍必须核验它声明的范围。
        if receipt.isAgreement && entry.sources.isEmpty && [.rule, .decision, .term].contains(entry.type), issues.isEmpty {
            return .init(state: .agreement, detail: "人工确认的约定，未绑定代码证据；不代表代码已实现或测试已通过。")
        }
        if entry.sources.isEmpty || Set(receipt.sources.map(\.path)) != Set(entry.sources)
            || receipt.sources.count != Set(entry.sources).count {
            issues.append(.init(kind: .sourcesUnbound, detail: "未绑定完整的仓库实际文件来源；点击校验不能自动生成来源或新的人工基线。"))
        } else {
            for old in receipt.sources {
                try Task.checkCancellation()
                let current = inspector.inspect(old.path)
                sourceChecked(old.path)
                guard let oldDigest = old.digest, let currentDigest = current.digest else {
                    let reason = old.digest == nil ? "确认时没有来源内容摘要；请先补全来源再人工核对" : current.issue ?? "来源无法读取"
                    issues.append(.init(kind: old.digest == nil ? .sourcesUnbound : .unreadable, path: old.path, detail: reason))
                    continue
                }
                if oldDigest != currentDigest {
                    changed.append(old.path)
                    issues.append(.init(kind: .sourceChanged, path: old.path, detail: "文件内容与确认时不同"))
                }
            }
        }
        if !issues.isEmpty {
            let state: WikiKnowledgeState = changed.isEmpty ? .unverifiable : .stale
            let details = issues.prefix(3).map { issue in (issue.path.map { $0 + "：" } ?? "") + issue.detail }.joined(separator: "\n")
            return .init(state: state, detail: details + (issues.count > 3 ? "\n另有 \(issues.count - 3) 项，查看校验报告。" : ""),
                         changedSources: Array(Set(changed)).sorted(), issues: issues)
        }
        return .init(state: .current, detail: "内容已由人确认，关联文件本次校验未变；不是独立的业务正确性证明。")
    }
}

/// 严格按仓库相对路径读取普通文件。包别名、目录、越界路径不猜测匹配。
struct WikiSourceInspector {
    let root: URL
    private var cache: [String: WikiSourceSnapshot] = [:]
    private var scopeCache: [String: WikiSourceSnapshot] = [:]
    private var remainingBytes = 32 * 1_024 * 1_024
    private let maxFileBytes = 2 * 1_024 * 1_024

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    static func resolvedFile(_ path: String, root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains(":"), !path.contains(","), WikiGenerationPolicy.isSingleLine(path, limit: 4_096),
              !path.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        return url
    }

    mutating func inspect(_ path: String) -> WikiSourceSnapshot {
        if let cached = cache[path] { return cached }
        let result = read(path)
        cache[path] = result
        return result
    }

    mutating func inspectScope(_ path: String) -> WikiSourceSnapshot {
        if let cached = scopeCache[path] { return cached }
        let snapshot: WikiSourceSnapshot
        do { snapshot = try WikiGenerationSources.scopeSnapshot(path, root: root) }
        catch { snapshot = .init(path: path, digest: nil, issue: error.localizedDescription) }
        scopeCache[path] = snapshot
        return snapshot
    }

    private mutating func read(_ path: String) -> WikiSourceSnapshot {
        func unavailable(_ reason: String) -> WikiSourceSnapshot {
            .init(path: path, digest: nil, issue: reason)
        }
        guard let url = Self.resolvedFile(path, root: root) else { return unavailable("不是仓库内的安全相对路径") }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return unavailable("目录或业务包路径尚不支持内容核验") }
            let size = values.fileSize ?? 0
            guard size <= maxFileBytes else { return unavailable("文件超过 2 MiB，未校验") }
            guard size <= remainingBytes else { return unavailable("本次来源读取预算已用完，未校验") }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
            guard data.count <= maxFileBytes, data.count <= remainingBytes else {
                return unavailable("文件读取超过预算，未校验")
            }
            remainingBytes -= data.count
            return .init(path: path, digest: WikiKnowledgeReview.digest(data))
        } catch {
            return unavailable("文件缺失或无法读取")
        }
    }
}
