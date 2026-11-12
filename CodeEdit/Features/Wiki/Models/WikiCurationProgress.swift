// 一次明确启动的有限额度与长期任务成本是两个量；历史缓存也不是当前模块完成数。
import Foundation

enum WikiCurationPauseReason: String, Codable, Sendable {
    case requestBudget, timeBudget, userPause, userCancel, noProgress
}

struct WikiCurationRun: Codable, Equatable, Sendable {
    var id = UUID()
    var startedAt: Double
    var requestLimit: Int
    var minutesLimit: Int
    var requestsUsed = 0
    var endedAt: Double?
    var pauseReason: WikiCurationPauseReason?

    var remainingRequests: Int { max(requestLimit - requestsUsed, 0) }
}

struct WikiLegacyCurationProgress: Codable, Equatable, Sendable {
    var filesDone: Int
    var filesTotal: Int
    var recordedAt: Double
}

struct WikiCurationCoverage: Equatable, Sendable {
    var totalFiles = 0
    var understoodFiles = 0
    var outputFiles = 0
    var skippedFiles = 0
    var completedModules = 0
    var pendingModules = 0
    var legacyObservations = 0
    var archivedLegacyObservations = 0
    var outdatedObservations = 0
    var savedEntries = 0
    var updateProposals = 0

    var pendingOutputFiles: Int { max(totalFiles - outputFiles, 0) }
    var understandingProgress: Double { totalFiles > 0 ? Double(understoodFiles) / Double(totalFiles) : 0 }
    var outputProgress: Double { totalFiles > 0 ? Double(outputFiles) / Double(totalFiles) : 0 }

    static func evaluate(
        evidence: [WikiModuleEvidence], totalFiles: Int, insights: WikiInsightStore,
        pipelineKey: String, job: WikiCurationJob, entries: [WikiEntry]
    ) -> Self {
        let receipts = Dictionary(evidence.flatMap(\.sources).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let understood = receipts.values.filter { insights.insight(for: $0, pipelineKey: pipelineKey) != nil }.count
        let processed = evidence.filter { $0.isProcessed(job: job, entries: entries) }
        let outputPaths = Set(processed.flatMap { $0.sources.map(\.path) })
        let skippedPaths = Set(processed.filter { job.moduleCheckpoints?[$0.module.name]?.noKnowledgeReason != nil }
            .flatMap { $0.sources.map(\.path) })
        let legacy = insights.allInsights.filter { $0.sourceDigest == nil || $0.pipelineKey == nil }.count
        let outdated = insights.allInsights.filter { record in
            guard record.sourceDigest != nil, record.pipelineKey != nil, let source = receipts[record.path] else { return false }
            return insights.insight(for: source, pipelineKey: pipelineKey) == nil
        }.count
        return .init(totalFiles: totalFiles, understoodFiles: understood, outputFiles: outputPaths.count,
                     skippedFiles: skippedPaths.count, completedModules: processed.count,
                     pendingModules: max(evidence.count - processed.count, 0), legacyObservations: legacy,
                     archivedLegacyObservations: insights.archivedLegacyCount, outdatedObservations: outdated, savedEntries: entries.filter { $0.proposalFor == nil }.count,
                     updateProposals: entries.filter { $0.proposalFor != nil }.count)
    }
}
