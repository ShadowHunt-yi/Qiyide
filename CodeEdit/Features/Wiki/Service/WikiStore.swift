//
//  WikiStore.swift
//  CodeEdit
//
//  知识库的数据层：扫描 `.qiyide/wiki/*.md`，维护标题索引、反向链接与图谱。
//
//  索引全部在内存里重建（百级条目量级，一次扫描是毫秒级），
//  不引入数据库——知识条目本来就该是能用 git 管理和 review 的纯文本。
//

import Combine
import Foundation

@MainActor
final class WikiStore: ObservableObject {

    @Published private(set) var entries: [WikiEntry] = []
    @Published private(set) var graph: WikiGraph = .empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoaded = false
    /// 结构层：域划分与域间依赖。独立于条目，不会因为条目增删而失效。
    @Published private(set) var architecture = WikiArchitecture.empty

    let root: URL

    /// 标题（归一化）→ 条目 id
    private var titleIndex: [String: String] = [:]
    /// 目标 id → 引用它的条目 id
    private var backlinkIndex: [String: Set<String>] = [:]
    /// 条目 id → 条目。列表每行、详情栏、批量操作都要按 id 取，
    /// 用 `entries.first { $0.id == id }` 会退化成 O(n²)。
    private var entriesByID: [String: WikiEntry] = [:]
    /// 检索用的预小写副本：标题、标签、正文各一份。
    private struct SearchRow {
        let id: String
        let title: String
        let tags: [String]
        let body: String
    }
    private var searchRows: [SearchRow] = []
    /// 布局代数号：后台算完的旧结果不能覆盖新数据。
    private var layoutGeneration: Int = 0

    init(root: URL) {
        self.root = root
    }

    var directory: URL {
        root.appending(path: ".qiyide/wiki", directoryHint: .isDirectory)
    }

    // MARK: 加载

    func reload() {
        let fileManager = FileManager.default
        errorMessage = nil

        guard fileManager.fileExists(atPath: directory.path) else {
            entries = []
            graph = .empty
            titleIndex = [:]
            backlinkIndex = [:]
            entriesByID = [:]
            searchRows = []
            isLoaded = true
            return
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            errorMessage = "读取知识库失败：\(error.localizedDescription)"
            return
        }

        var parsed: [WikiEntry] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            parsed.append(WikiEntry.parse(text: text, fileURL: url))
        }

        entries = parsed.sorted { $0.updatedAt > $1.updatedAt }
        rebuildIndexes()
        rebuildGraph()
        architecture = WikiArchitecture.load(root: root)
        isLoaded = true
    }

    private func rebuildIndexes() {
        titleIndex = [:]
        entriesByID = [:]
        entriesByID.reserveCapacity(entries.count)
        searchRows = []
        searchRows.reserveCapacity(entries.count)
        for entry in entries {
            titleIndex[entry.normalizedTitle] = entry.id
            entriesByID[entry.id] = entry
            searchRows.append(SearchRow(
                id: entry.id,
                title: entry.title.lowercased(),
                tags: entry.tags.map { $0.lowercased() },
                body: entry.body.lowercased()
            ))
        }
        backlinkIndex = [:]
        for entry in entries {
            for target in outgoingLinks(of: entry) {
                guard let targetID = titleIndex[WikiEntry.normalize(target)] else { continue }
                backlinkIndex[targetID, default: []].insert(entry.id)
            }
        }
    }

    /// 正文里的 `[[链接]]`，按出现顺序去重。
    private func bodyLinks(of entry: WikiEntry) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let pattern = "\\[\\[([^\\[\\]]+)\\]\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(entry.body.startIndex..<entry.body.endIndex, in: entry.body)
        regex.enumerateMatches(in: entry.body, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let targetRange = Range(match.range(at: 1), in: entry.body) else { return }
            let target = String(entry.body[targetRange]).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, seen.insert(target).inserted else { return }
            result.append(target)
        }
        return result
    }

    /// 显式关系在前，正文提及在后。
    private func outgoingLinks(of entry: WikiEntry) -> [String] {
        entry.relations.map(\.target) + bodyLinks(of: entry)
    }

    private func rebuildGraph() {
        var nodes: [WikiNode] = entries.map { entry in
            WikiNode(
                id: entry.id,
                title: entry.title,
                label: entry.displayTitle,
                type: entry.type,
                degree: 0,
                position: .zero,
                isDraft: entry.isDraft
            )
        }

        var edges: [WikiEdge] = []
        var seenPairs: Set<String> = []

        // 1) 前置声明的关系（强边）
        for entry in entries {
            for relation in entry.relations {
                guard let targetID = titleIndex[WikiEntry.normalize(relation.target)],
                      targetID != entry.id else { continue }
                let pairKey = "\(entry.id)->\(targetID)"
                guard seenPairs.insert(pairKey).inserted else { continue }
                edges.append(WikiEdge(
                    id: "e-\(edges.count)",
                    from: entry.id,
                    to: targetID,
                    kind: relation.kind,
                    isExplicit: true
                ))
            }
        }

        // 2) 正文提及（弱边，已被强边覆盖的跳过）
        var explicitDirected: Set<String> = []
        for edge in edges {
            explicitDirected.insert("\(edge.from)->\(edge.to)")
            explicitDirected.insert("\(edge.to)->\(edge.from)")
        }
        for entry in entries {
            for target in bodyLinks(of: entry) {
                guard let targetID = titleIndex[WikiEntry.normalize(target)],
                      targetID != entry.id else { continue }
                let key = "\(entry.id)->\(targetID)"
                guard !explicitDirected.contains(key) else { continue }
                guard seenPairs.insert(key).inserted else { continue }
                edges.append(WikiEdge(
                    id: "e-\(edges.count)",
                    from: entry.id,
                    to: targetID,
                    kind: "提及",
                    isExplicit: false
                ))
            }
        }

        // 3) 布局
        //
        // 力导向是 O(n²·iterations)：232 个节点在 Debug 构建里要一百多毫秒，
        // 而 reload 会在每次确认/丢弃/删除后触发，同步算就是「点一下卡一下」。
        //
        // 现在先用力导向的螺旋初值上屏（同一套公式，视觉上仍然是确定的），
        // 再把收敛计算挪到后台线程，算完替换坐标。过期结果用代数号丢弃。
        var degree: [String: Int] = [:]
        for edge in edges {
            degree[edge.from, default: 0] += 1
            degree[edge.to, default: 0] += 1
        }
        for index in nodes.indices {
            nodes[index].degree = degree[nodes[index].id] ?? 0
            nodes[index].position = WikiLayout.initialPosition(
                index: index,
                count: nodes.count,
                id: nodes[index].id
            )
        }

        graph = WikiGraph(nodes: nodes, edges: edges)

        layoutGeneration &+= 1
        let generation = layoutGeneration
        let ids = nodes.map(\.id)
        let pairs = edges.map { ($0.from, $0.to) }
        Task { [weak self] in
            let positions = await Task.detached(priority: .userInitiated) {
                WikiLayout.compute(nodes: ids, edges: pairs)
            }.value
            guard let self, self.layoutGeneration == generation else { return }
            self.applyPositions(positions)
        }
    }

    /// 后台算完的坐标回填。只有位置变了才重组图，避免白触发一次重绘。
    private func applyPositions(_ positions: [String: CGPoint]) {
        var nodes = graph.nodes
        var changed = false
        for index in nodes.indices {
            guard let position = positions[nodes[index].id],
                  nodes[index].position != position else { continue }
            nodes[index].position = position
            changed = true
        }
        guard changed else { return }
        graph = WikiGraph(nodes: nodes, edges: graph.edges)
    }

    // MARK: 查询

    func entry(id: String) -> WikiEntry? {
        entriesByID[id]
    }

    func entry(titled title: String) -> WikiEntry? {
        guard let id = titleIndex[WikiEntry.normalize(title)] else { return nil }
        return entry(id: id)
    }

    func backlinks(of id: String) -> [WikiEntry] {
        (backlinkIndex[id] ?? []).compactMap { entry(id: $0) }
    }

    /// 简单打分检索：标题命中权重最高，其次标签，最后正文。
    ///
    /// 小写副本在重建索引时算好一次。搜索框是「每敲一个字搜一次」，
    /// 旧实现每次都对全库正文调 `lowercased()`，输入时会明显掉字。
    func search(_ query: String) -> [WikiEntry] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return entries }

        var scored: [(entry: WikiEntry, score: Int)] = []
        scored.reserveCapacity(16)
        for row in searchRows {
            var score = 0
            if row.title.contains(keyword) { score += 6 }
            if row.tags.contains(where: { $0.contains(keyword) }) { score += 3 }
            if row.body.contains(keyword) { score += 1 }
            guard score > 0, let entry = entriesByID[row.id] else { continue }
            scored.append((entry, score))
        }
        return scored.sorted { $0.score > $1.score }.map(\.entry)
    }

    /// 与一组改动文件相关的条目：用于审查窗口的「相关知识」。
    func entries(matchingPaths paths: [String]) -> [WikiEntry] {
        guard !paths.isEmpty else { return [] }
        return entries.filter { entry in
            entry.sources.contains { source in
                paths.contains { path in
                    path == source || path.hasSuffix(source) || source.hasSuffix(path)
                }
            }
        }
    }

    // MARK: 写入

    @discardableResult
    func create(type: WikiEntryType, title: String = "新条目") throws -> WikiEntry {
        try ensureDirectory()
        let id = uniqueID(basedOn: title)
        let url = directory.appending(path: "\(id).md")
        var entry = WikiEntry(
            id: id,
            title: title,
            type: type,
            tags: [],
            sources: [],
            relations: [],
            body: "",
            updatedAt: Date(),
            fileURL: url
        )
        entry.updatedAt = Date()
        try write(entry)
        reload()
        return self.entry(id: id) ?? entry
    }

    func save(_ entry: WikiEntry) throws {
        try ensureDirectory()
        var updated = entry
        updated.updatedAt = Date()
        try write(updated)
        reload()
    }

    /// 把 AI 生成的草稿落盘。永远是 draft，必须由人确认后才成为可信知识。
    /// 落盘一份草稿。
    ///
    /// `refresh` 为 false 时只写文件、不重建内存与图谱。
    /// 建档一轮会连续写十几条，每条都重算一次力导向布局会直接把主线程锁死
    /// （实测 159 节点一次布局一秒多，20 条就是二十多秒无响应）。
    @discardableResult
    func applyDraft(
        _ draft: WikiDraft,
        generatedBy: String,
        sources: [String],
        refresh: Bool = true
    ) throws -> WikiEntry {
        if draft.action == .update, let target = entry(titled: draft.target) {
            var updated = target
            switch draft.mergeMode {
            case .append:
                // 一次改动带来的增量：追加，保留原文便于人对照。
                let stamp = Date().formatted(date: .numeric, time: .shortened)
                updated.body += "\n\n**补充（\(stamp)）**：\(draft.body)"
            case .replace:
                // 重复建档：整块替换 AI 生成的结构，只保留人写过的「补充」段落。
                // 否则同一模块跑 N 轮就会累积 N 段互相矛盾的结论。
                let preserved = Self.preservedNotes(in: target.body)
                updated.body = preserved.isEmpty
                    ? draft.body
                    : draft.body + "\n\n" + preserved
                if !draft.relations.isEmpty {
                    updated.relations = draft.relations
                }
                if !sources.isEmpty {
                    updated.sources = sources
                }
            }
            updated.status = .draft
            updated.generatedBy = generatedBy
            if updated.sources.isEmpty { updated.sources = sources }
            if refresh {
                try save(updated)
                return entry(id: target.id) ?? updated
            }
            updated.updatedAt = Date()
            try write(updated)
            return updated
        }

        try ensureDirectory()
        let id = uniqueID(basedOn: draft.title)
        let url = directory.appending(path: "\(id).md")
        let entry = WikiEntry(
            id: id,
            title: draft.title,
            type: draft.type,
            tags: draft.tags,
            sources: sources,
            relations: draft.relations,
            body: draft.body,
            updatedAt: Date(),
            fileURL: url,
            status: .draft,
            generatedBy: generatedBy
        )
        try write(entry)
        if refresh {
            reload()
            return self.entry(id: id) ?? entry
        }
        return entry
    }

    // MARK: 批量

    /// 批量保存：逐个写文件，最后只 reload 一次。
    ///
    /// 收尾补边时会对上百个条目改关系，逐条 `save` 等于上百次全量重扫 + 布局。
    func save(_ entries: [WikiEntry]) throws {
        guard !entries.isEmpty else { return }
        try ensureDirectory()
        for entry in entries {
            var updated = entry
            updated.updatedAt = Date()
            try write(updated)
        }
        reload()
    }

    /// 批量确认。
    ///
    /// 逐个写文件、最后只 reload 一次：单条 `save` 每次都做全量扫描，
    /// 一百条草稿就是一百次解析，界面会明显卡住。
    @discardableResult
    func confirm(ids: [String]) -> Int {
        var changed = 0
        for id in ids {
            guard let entry = entry(id: id), entry.isDraft else { continue }
            var updated = entry
            updated.status = .confirmed
            updated.updatedAt = Date()
            if (try? write(updated)) != nil { changed += 1 }
        }
        if changed > 0 { reload() }
        return changed
    }

    /// 批量丢弃草稿：走废纸篓，可恢复。已确认的条目不动。
    @discardableResult
    func discardDrafts(ids: [String]) -> Int {
        var changed = 0
        for id in ids {
            guard let entry = entry(id: id), entry.isDraft else { continue }
            if (try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)) != nil {
                changed += 1
            }
        }
        if changed > 0 { reload() }
        return changed
    }

    /// 批量删除：不限草稿，全部走废纸篓。
    @discardableResult
    func delete(ids: [String]) -> Int {
        var changed = 0
        for id in ids {
            guard let entry = entry(id: id) else { continue }
            if (try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)) != nil {
                changed += 1
            }
        }
        if changed > 0 { reload() }
        return changed
    }

    /// 人确认草稿：转入 confirmed，此后才会被当作可信知识。
    func confirm(_ entry: WikiEntry) throws {
        var updated = entry
        updated.status = .confirmed
        try save(updated)
    }

    /// 丢弃草稿：移入废纸篓，不直接删除。
    func discardDraft(_ entry: WikiEntry) throws {
        guard entry.isDraft else { return }
        try delete(entry)
    }

    var drafts: [WikiEntry] {
        entries.filter(\.isDraft)
    }

    func delete(_ entry: WikiEntry) throws {
        guard FileManager.default.fileExists(atPath: entry.fileURL.path) else { return }
        // 走废纸篓，知识不该因为一次误点就永久消失。
        try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
        reload()
    }

    /// 人写过的「补充」段落：重复建档替换正文时必须保留。
    private static func preservedNotes(in body: String) -> String {
        let blocks = body.components(separatedBy: "\n\n**补充（")
        guard blocks.count > 1 else { return "" }
        return blocks.dropFirst().map { "**补充（" + $0 }.joined(separator: "\n\n")
    }

    // MARK: 内部

    private func write(_ entry: WikiEntry) throws {
        try entry.markdown().write(to: entry.fileURL, atomically: true, encoding: .utf8)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func uniqueID(basedOn base: String) -> String {
        let sanitized = base.replacingOccurrences(of: "/", with: "-")
        var candidate = sanitized
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appending(path: "\(candidate).md").path) {
            candidate = "\(sanitized)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
