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

    /// 上次扫描时的文件总数，用于界面概览与「是否还有剩余」的判定。
    var filesTotal: Int = 0
    var filesDone: Int = 0

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
    func knownModuleContext(excluding module: String) -> String {
        let items = moduleNotes
            .filter { $0.key != module }
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
        guard let data = try? Data(contentsOf: url(root: root)),
              let job = try? JSONDecoder().decode(WikiCurationJob.self, from: data) else {
            return WikiCurationJob()
        }
        return job
    }

    func save(root: URL) {
        let target = Self.url(root: root)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: target, options: .atomic)
    }
}
