import Foundation

struct WikiEvidenceIssue: Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case emptyBody, contentChanged, confirmationMissing, scopeUnbound, scopeChanged, sourcesUnbound, sourceChanged, unreadable
        var title: String {
            switch self {
            case .emptyBody: return "正文为空"
            case .contentChanged: return "内容与确认版本不同"
            case .confirmationMissing: return "缺少人工确认记录"
            case .scopeUnbound: return "范围没有完整基线"
            case .scopeChanged: return "范围成员或内容变化"
            case .sourcesUnbound: return "未绑定实际文件来源"
            case .sourceChanged: return "文件来源已变化"
            case .unreadable: return "来源无法读取或超过预算"
            }
        }
    }
    var kind: Kind
    var path: String?
    var detail: String
}

struct WikiKnowledgeCheckProgress: Equatable, Sendable {
    var checkedEntries = 0
    var totalEntries = 0
    var checkedSources = 0
    var currentEntry = ""
    var currentPath = ""
    var fraction: Double { totalEntries > 0 ? Double(checkedEntries) / Double(totalEntries) : 0 }
}

struct WikiKnowledgeCheckSnapshot: Equatable, Sendable {
    enum Status: String, Sendable { case idle, checking, completed, cancelled, failed }
    var id = UUID()
    var status: Status = .idle
    var progress = WikiKnowledgeCheckProgress()
    var startedAt: Date?
    var finishedAt: Date?
    var message = ""
}

typealias WikiKnowledgeCheckWorker = @Sendable (
    [WikiEntry], URL, @escaping @Sendable (WikiKnowledgeCheckProgress) -> Void
) async throws -> WikiKnowledgeReport

struct WikiKnowledgeCheckCounts: Equatable, Sendable {
    var ready = 0
    var drafts = 0
    var review = 0
    var checking = 0
    var reasons: [WikiEvidenceIssue.Kind: Int] = [:]

    static func count(entries: [WikiEntry], report: WikiKnowledgeReport) -> Self {
        var counts = Self()
        for entry in entries {
            let assessment = report.assessment(for: entry)
            if assessment.state.canReference { counts.ready += 1 }
            else if assessment.state == .draft { counts.drafts += 1 }
            else if assessment.state == .checking { counts.checking += 1 }
            else { counts.review += 1 }
            if let primary = assessment.issues.first { counts.reasons[primary.kind, default: 0] += 1 }
        }
        return counts
    }

    var resultText: String {
        "校验完成：\(ready) 条可作参考，\(drafts) 条待人工确认，\(review) 条仍需处理。"
    }
}
