// 文件理解只绑定读取时的内容与提取策略；时间戳不能替旧结果背书。
import Foundation

struct RepoFileInsight: Codable, Sendable {
    var path: String
    var purpose: String
    var keyPoints: [String]
    // 保留旧字段以读取历史文件；它们不再参与缓存命中。
    var modified: Double = 0
    var size: Int = 0
    var model: String = ""
    var recordedAt: Double = 0
    var sourceDigest: String?
    var pipelineKey: String?
    var noKnowledgeReason: String?

    init(path: String, purpose: String, keyPoints: [String]) {
        self.path = path; self.purpose = purpose; self.keyPoints = keyPoints
    }

    var receipt: WikiSourceSnapshot { .init(path: path, digest: sourceDigest) }
}

struct WikiInsightStore: Codable, Sendable {
    private(set) var records: [String: RepoFileInsight] = [:]
    /// 升级覆盖当前记录前，保留旧格式观察；它们仍不能作为新鲜缓存命中。
    private(set) var legacyRecords: [String: RepoFileInsight]?
    /// 旧数据保留可读，损坏的数据不允许被空缓存静默覆盖。
    private(set) var loadIssue: String?
    var count: Int { records.count }

    static func url(root: URL) -> URL { root.appending(path: ".qiyide/wiki/.insights.json") }

    static func load(root: URL) -> WikiInsightStore {
        let target = url(root: root)
        guard FileManager.default.fileExists(atPath: target.path) else { return .init() }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: target)) }
        catch {
            var failed = Self()
            failed.loadIssue = "文件理解缓存无法读取：\(error.localizedDescription)；原文件未覆盖。"
            return failed
        }
    }

    func save(root: URL) throws {
        guard loadIssue == nil else { throw WikiGenerationError.invalidOutput(loadIssue ?? "缓存无法读取") }
        let target = Self.url(root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }

    func insight(for source: WikiSourceSnapshot, pipelineKey: String) -> RepoFileInsight? {
        guard let record = records[source.path], let digest = source.digest,
              record.sourceDigest == digest, record.pipelineKey == pipelineKey else { return nil }
        return record
    }

    /// 只读概览兼容入口。model 必须是策略键，模型显示名不能命中旧缓存。
    func insight(for path: String, url: URL, model: String) -> RepoFileInsight? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= WikiGenerationSources.maxFileBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: WikiGenerationSources.maxFileBytes + 1),
              data.count <= WikiGenerationSources.maxFileBytes else { return nil }
        return insight(for: .init(path: path, digest: WikiGenerationPolicy.digest(data)), pipelineKey: model)
    }

    /// 这里不再读磁盘：收到的是生成前、从实际输入字节取得的凭据。
    mutating func record(_ insight: RepoFileInsight, source: WikiSourceSnapshot, pipelineKey: String, model: String) throws {
        guard insight.path == source.path, source.digest != nil, !pipelineKey.isEmpty else {
            throw WikiGenerationError.invalidOutput("文件结论缺少读取时的版本凭据")
        }
        if let old = records[insight.path], old.sourceDigest == nil || old.pipelineKey == nil {
            preserveLegacy(old)
        }
        var recorded = insight
        recorded.sourceDigest = source.digest
        recorded.pipelineKey = pipelineKey
        recorded.model = model
        recorded.recordedAt = Date().timeIntervalSince1970
        records[insight.path] = recorded
    }

    private mutating func preserveLegacy(_ insight: RepoFileInsight) {
        var history = legacyRecords ?? [:]
        if history[insight.path] == nil { history[insight.path] = insight }
        legacyRecords = history
    }

    mutating func prune(existingPaths: Set<String>) {
        for record in records.values where !existingPaths.contains(record.path)
            && (record.sourceDigest == nil || record.pipelineKey == nil) {
            preserveLegacy(record)
        }
        records = records.filter { existingPaths.contains($0.key) }
    }

    var archivedLegacyCount: Int { legacyRecords?.count ?? 0 }
    var allInsights: [RepoFileInsight] { records.values.sorted { $0.path < $1.path } }
}
