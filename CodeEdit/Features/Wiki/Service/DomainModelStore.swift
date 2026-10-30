//
//  DomainModelStore.swift
//  CodeEdit
//
//  领域建模的状态容器：识别、编辑、锁定、漂移检测。
//
//  为什么锁定要单独存一份文件：
//  自动识别每次扫描都会重算，而人工锚定（改名、改归属、指定负责人）是团队共识，
//  不能被下一次扫描覆盖。所以「锁定模型」写 domains.locked.json，
//  与自动结果分开放；只有人工点「重新识别」才会替换。
//

import Foundation
import SwiftUI

/// 锁定后代码又发生了变化，提示哪些包没被纳入模型。
struct DriftReport: Sendable {
    /// 模型里没有的包（新增）。
    var uncoveredPackages: [String] = []
    /// 模型里有、但仓库里已经找不到的包（删除或改名）。
    var missingPackages: [String] = []
    /// 锁定时基于的 commit 与当前 HEAD 不同。
    var baseCommitChanged: Bool = false

    var isEmpty: Bool {
        uncoveredPackages.isEmpty && missingPackages.isEmpty && !baseCommitChanged
    }
}

@MainActor
final class DomainModelStore: ObservableObject {

    @Published private(set) var graph: MindGraph = .empty
    @Published private(set) var isLocked = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progressText = ""
    @Published private(set) var lastAnalyzedAt: Date?
    @Published private(set) var drift: DriftReport?
    @Published var errorMessage: String?

    /// 模型版本号。每次结构变化递增，供视图缓存投影图与布局。
    ///
    /// 为什么不直接比较 `graph`：`MindGraph` 不算轻量（含上百个节点与索引），
    /// 每帧做深比较比重新投影还贵。一个整数就够表达「变了没有」。
    @Published private(set) var revision: Int = 0

    /// 上次识别时的全部包，用于漂移比较。
    private var knownPackages: Set<String> = []

    let root: URL

    init(root: URL) {
        self.root = root
        loadLockedIfPresent()
    }

    // MARK: 加载与保存

    private var lockedURL: URL { LockedDomainModel.url(root: root) }

    private func loadLockedIfPresent() {
        guard let data = try? Data(contentsOf: lockedURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let locked = try? decoder.decode(LockedDomainModel.self, from: data) else {
            errorMessage = "domains.locked.json 解析失败，可能是手工编辑时格式出错"
            return
        }
        graph = locked.graph
        isLocked = true
        lastAnalyzedAt = locked.lockedAt
    }

    /// 锁定当前模型。锁定后自动识别不会覆盖它。
    func lock() {
        guard !graph.isEmpty else { return }
        var model = LockedDomainModel()
        model.lockedAt = Date()
        model.baseCommit = graph.baseCommit
        model.graph = graph

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: lockedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(model).write(to: lockedURL, options: .atomic)
            isLocked = true
            drift = nil
        } catch {
            errorMessage = "锁定失败：\(error.localizedDescription)"
        }
    }

    /// 解除锁定，回到可重新识别的状态。文件保留，便于恢复。
    func unlock() {
        isLocked = false
    }

    // MARK: 识别

    func analyze() async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        errorMessage = nil
        progressText = "准备扫描…"

        let result = await DomainAnalyzer.analyze(root: root) { [weak self] text in
            self?.progressText = text
        }

        // 已锁定时不覆盖人工结果，只算漂移。
        if isLocked {
            drift = makeDrift(from: result)
        } else {
            graph = result.graph
            knownPackages = Set(result.graph.nodes.flatMap(\.packages))
            revision &+= 1
        }

        lastAnalyzedAt = Date()
        if !result.warnings.isEmpty {
            errorMessage = result.warnings.joined(separator: "；")
        }
        isAnalyzing = false
        progressText = ""

        #if DEBUG
        // 识别结果打到 stderr，便于在没有界面的情况下核对算法输出。
        let summary = graph.domains
            .map { "\($0.displayTitle)(\($0.classCount)类)" }
            .joined(separator: " ")
        NSLog(
            "[Qiyide][domain] 识别完成 包=%d 类=%d 域=%d %@ 耗时=%.1fs",
            result.packageCount,
            result.classCount,
            graph.domains.count,
            summary,
            result.elapsed
        )
        #endif
    }

    /// 比较「模型已覆盖的包」与「本次扫描到的包」。
    private func makeDrift(from result: DomainAnalysisResult) -> DriftReport {
        let covered = Set(graph.nodes.flatMap(\.packages).filter { !$0.isEmpty })
        let scanned = Set(result.graph.nodes.flatMap(\.packages).filter { !$0.isEmpty })
        return DriftReport(
            uncoveredPackages: Array(scanned.subtracting(covered)).sorted(),
            missingPackages: Array(covered.subtracting(scanned)).sorted(),
            baseCommitChanged: result.graph.baseCommit != graph.baseCommit
        )
    }

    // MARK: 编辑

    func rename(_ id: String, to title: String) {
        graph.rename(id, to: title)
        revision &+= 1
    }

    func assignOwner(_ id: String, to name: String?) {
        graph.assignOwner(id, to: name)
        revision &+= 1
    }

    func setShared(_ id: String, _ shared: Bool) {
        graph.setShared(id, shared)
        revision &+= 1
    }

    func merge(_ sourceID: String, into targetID: String) {
        graph.merge(sourceID, into: targetID)
        revision &+= 1
    }

    func move(_ id: String, toParent parentID: String) {
        graph.move(id, toParent: parentID)
        revision &+= 1
    }

    /// 编辑后立刻落盘（仅锁定的模型）。未锁定时改动只存在内存里。
    func persistIfLocked() {
        guard isLocked else { return }
        lock()
    }

    // MARK: 查询

    var domains: [MindNode] { graph.domains }
    var sharedDependencies: [MindNode] { graph.sharedNodes }

    func node(_ id: String) -> MindNode? { graph.node(id) }

    /// 供导出用的 Markdown 大纲：缩进即层级。
    func markdownOutline() -> String {
        var lines: [String] = []
        func walk(_ id: String, depth: Int) {
            guard let node = graph.node(id) else { return }
            let indent = String(repeating: "  ", count: depth)
            var suffix = ""
            if node.classCount > 0 { suffix += "（\(node.classCount) 类）" }
            if !node.owner.primary.isEmpty { suffix += " · \(node.owner.primary)" }
            lines.append("\(indent)- \(node.displayTitle)\(suffix)")
            for child in graph.children(of: id) {
                walk(child.id, depth: depth + 1)
            }
        }
        walk(graph.rootID, depth: 0)
        return lines.joined(separator: "\n")
    }
}
