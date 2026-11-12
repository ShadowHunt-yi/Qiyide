//
//  WikiCurationJob.swift
//  CodeEdit
//
//  整仓建档的「任务」状态：跨轮次、跨进程重启都能续上的那一份。
//
//  与 WikiIngestState 的分工要分清：
//  - WikiIngestState 记「哪些文件读过了」，粒度是文件，服务于增量；
//  - WikiCurationJob 记「这个长任务跑到第几轮、花了多少调用、哪些模块已经有结论」，
//    粒度是任务与模块，服务于自动编排与跨轮上下文。
//
//  两者都落盘在 .qiyide/wiki/ 下，都随仓库走。
//

import Foundation

enum WikiCurationStatus: String, Codable {
    /// 还没开始过。
    case idle
    /// 正在跑。如果 App 启动时读到这个状态，说明上次是异常退出。
    case running
    /// 用户主动暂停，可以原样续跑。
    case paused
    /// 全部文件都已建档。
    case finished
    /// 连续失败过多而中止，需要人看一眼。
    case failed
}

struct WikiModuleCheckpoint: Codable, Sendable {
    var basisDigest: String
    var entryID: String?
    var noKnowledgeReason: String?
    var entryDigest: String?
}

struct WikiCurationJob: Codable {

    var status: WikiCurationStatus = .idle
    /// 已经完成的轮次。
    var round: Int = 0
    /// 累计模型调用次数（跨轮累计，是成本的主要指标）。
    var callsUsed: Int = 0
    var startedAt: Double = 0
    var updatedAt: Double = 0
    var lastError: String?

    /// 本轮失败的批次说明，下一轮优先重试。
    var failures: [String] = []

    /// 模块名 → 一句话职责。这是跨轮推断「模块关系」时唯一稳定的上下文：
    /// 只给模块名，模型只能瞎猜；给了已建模块的职责，才能写出「依赖 X」。
    var moduleNotes: [String: String] = [:]
    /// 新字段为 optional：旧检查点保留可读，但无版本的旧摘要不进入提示词。
    var moduleCheckpoints: [String: WikiModuleCheckpoint]?
    var pipelineKey: String?
    var loadIssue: String?
    /// 历史总成本永远保留；用户每次启动另开一份有限 run，不累加成永久门槛。
    var lastRun: WikiCurationRun?
    /// 升级旧格式时保留旧口径，不把预览的当前完成数写回成“旧记录为 0”。
    var legacyProgress: WikiLegacyCurationProgress?
    /// 旧模块摘要没有输入版本，不参与当前推断，但升级时也不能把已付费成果丢掉。
    var legacyModuleNotes: [String: String]?

    /// 上次扫描时的文件总数，用于界面概览与「是否还有剩余」的判定。
    var filesTotal: Int = 0
    var filesDone: Int = 0

    mutating func preserveLegacyProgressIfNeeded() {
        guard legacyProgress == nil, pipelineKey == nil, moduleCheckpoints == nil,
              round > 0 || callsUsed > 0 || filesDone > 0 else { return }
        legacyProgress = .init(filesDone: filesDone, filesTotal: filesTotal, recordedAt: updatedAt)
        if legacyModuleNotes == nil { legacyModuleNotes = moduleNotes }
    }

    mutating func beginRun(requestLimit: Int, minutesLimit: Int, at date: Date) {
        preserveLegacyProgressIfNeeded()
        lastRun = .init(startedAt: date.timeIntervalSince1970,
                        requestLimit: max(1, requestLimit), minutesLimit: max(1, minutesLimit))
        status = .running
        lastError = nil
    }

    mutating func note(_ module: String, responsibility: String) {
        let trimmed = responsibility.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 只留第一句，避免上下文随轮次膨胀。
        let firstSentence = trimmed
            .split(whereSeparator: { "。！？\n".contains($0) })
            .first
            .map(String.init) ?? trimmed
        moduleNotes[module] = String(firstSentence.prefix(120))
    }

    /// 供 relate 阶段使用的「已知模块」摘要，控制在 30 条以内。
    func knownModuleContext(excluding module: String, versions: [String: String] = [:]) -> String {
        let items = moduleNotes
            .filter { $0.key != module && moduleCheckpoints?[$0.key]?.basisDigest == versions[$0.key]
                && versions[$0.key] != nil }
            .sorted { $0.key < $1.key }
            .prefix(30)
            .map { "- \($0.key)：\($0.value)" }
        return items.joined(separator: "\n")
    }

    // MARK: 存取

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/.ingest-job.json")
    }

    static func load(root: URL) -> WikiCurationJob {
        let target = url(root: root)
        guard FileManager.default.fileExists(atPath: target.path) else { return .init() }
        do {
            var job = try JSONDecoder().decode(Self.self, from: Data(contentsOf: target))
            if job.status == .running { job.status = .paused }
            return job
        } catch {
            var failed = Self()
            failed.status = .failed
            failed.loadIssue = "建档检查点无法读取：\(error.localizedDescription)；原文件未覆盖。"
            failed.lastError = failed.loadIssue
            return failed
        }
    }

    func save(root: URL) throws {
        guard loadIssue == nil else { throw WikiGenerationError.invalidOutput(loadIssue ?? "检查点无法读取") }
        let target = Self.url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
}
