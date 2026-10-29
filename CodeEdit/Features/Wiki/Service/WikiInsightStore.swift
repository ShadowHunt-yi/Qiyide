//
//  WikiInsightStore.swift
//  CodeEdit
//
//  整仓建档的「文件理解」持久层。
//
//  为什么需要它：
//  第一版把 `insights` 写成 run() 的局部变量，轮末就丢了。后果有两个，
//  而且都很贵：一是下一轮把上轮读过的文件重读重付费；二是跨轮无法增量更新，
//  只知道「这个文件变过」，不知道「它原来写了什么」，只能整模块重来。
//
//  这里把每个文件的理解结论连同「读它时的 mtime/size + 模型指纹」一起落盘：
//  文件没变且模型没换，就直接复用，既不读文件也不发请求。
//

import Foundation

// MARK: - 单文件理解结论

struct RepoFileInsight: Codable, Sendable {
    var path: String
    var purpose: String
    var keyPoints: [String]

    /// 记录结论时目标的 mtime / size，用于判定文件是否变过。
    var modified: Double = 0
    var size: Int = 0
    /// 产出这条结论的模型标识：换模型后旧结论自动失效，避免不同模型的判断混在一起。
    var model: String = ""
    var recordedAt: Double = 0

    init(path: String, purpose: String, keyPoints: [String]) {
        self.path = path
        self.purpose = purpose
        self.keyPoints = keyPoints
    }
}

// MARK: - 存储

struct WikiInsightStore: Codable {

    /// 相对路径 → 结论。
    private(set) var records: [String: RepoFileInsight] = [:]

    var count: Int { records.count }

    // MARK: 存取

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/.insights.json")
    }

    static func load(root: URL) -> WikiInsightStore {
        guard let data = try? Data(contentsOf: url(root: root)),
              let store = try? JSONDecoder().decode(WikiInsightStore.self, from: data) else {
            return WikiInsightStore()
        }
        return store
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

    // MARK: 判定与写入

    /// 命中条件：文件没改过，且结论是同一个模型给的。
    func insight(for path: String, url: URL, model: String) -> RepoFileInsight? {
        guard let record = records[path] else { return nil }
        // 模型指纹不同说明判断标准变了，旧结论不能直接复用。
        guard record.model.isEmpty || record.model == model else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate?.timeIntervalSince1970,
              let size = values.fileSize else {
            return nil
        }
        // 容差不能给到 1 秒：同一秒内保存两次会漏判，而 APFS 的 mtime 是纳秒精度。
        guard abs(record.modified - modified) < 0.001, record.size == size else { return nil }
        return record
    }

    /// 写入一条结论，同时刻上目标文件当前的 mtime / size。
    mutating func record(
        path: String,
        purpose: String,
        keyPoints: [String],
        url: URL,
        model: String
    ) {
        var insight = RepoFileInsight(path: path, purpose: purpose, keyPoints: keyPoints)
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            insight.modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            insight.size = values.fileSize ?? 0
        }
        insight.model = model
        insight.recordedAt = Date().timeIntervalSince1970
        records[path] = insight
    }

    /// 清掉已经不存在的文件的结论，避免状态文件无限增长。
    mutating func prune(existingPaths: Set<String>) {
        records = records.filter { existingPaths.contains($0.key) }
    }

    var allInsights: [RepoFileInsight] {
        Array(records.values)
    }
}
