//
//  WikiStore.swift
//  CodeEdit
//
//  知识库的数据层：扫描 `.qiyide/wiki/*.md`，维护标题索引、反向链接与图谱。
//
//  索引全部在内存里重建（百级条目量级，一次扫描是毫秒级），
//  不引入数据库——知识条目本来就该是能用 git 管理和 review 的纯文本。
//
//  两条写入路径，不要混用：
//  - `reload()`：重扫磁盘。只在「首次载入」和「外部改动了文件」时用，异步。
//  - `applyChanges(updated:removed:)`：内存增量。写入方手里已经有最新内容，
//    没必要再从磁盘读回来。
//

import Combine
import Foundation

@MainActor
final class WikiStore: ObservableObject {

    @Published private(set) var entries: [WikiEntry] = []
    @Published private(set) var graph: WikiGraph = .empty
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoaded = false
    /// 正在后台重扫。按钮用它显示进度，也用来挡掉重复点击。
    @Published private(set) var isReloading = false
    /// 结构层：域划分与域间依赖。独立于条目，不会因为条目增删而失效。
    @Published private(set) var architecture = WikiArchitecture.empty

    /// 内容版本号：任何一次写入都递增。
    ///
    /// 视图用它判断「派生数据要不要重算」。原来盯着 `entries.count` 是不准的：
    /// 改一条条目的正文、状态、归属都不会改变数量，但体检结果已经过期了。
    @Published private(set) var contentRevision: Int = 0

    let root: URL

    /// 标题（归一化）→ 条目 id
    private var titleIndex: [String: String] = [:]
    /// 目标 id → 引用它的条目 id
    private var backlinkIndex: [String: Set<String>] = [:]
    /// 条目 id → 条目。列表每行、详情栏、批量操作都要按 id 取，
    /// 用 `entries.first { $0.id == id }` 会退化成 O(n²)。
    private var entriesByID: [String: WikiEntry] = [:]
    /// 域 id → 条目 id。
    ///
    /// 左栏按域分组、详情页列「这个域有哪些知识」都走这张表；
    /// 没有它就只能每次全库扫一遍 `entry.domains`，域一多就是 O(域×条目)。
    private var entriesByDomain: [String: [String]] = [:]
    /// 检索用的预小写副本：标题、标签、正文各一份。按 id 存，
    /// 这样改一条条目只需要重算它自己那一行。
    private struct SearchRow {
        let id: String
        let title: String
        let tags: [String]
        let body: String
    }
    private var searchRows: [String: SearchRow] = [:]
    /// 条目 id → 正文里的 `[[链接]]`。
    ///
    /// 正则扫全文是「重建索引」和「重建图谱」共同的大头：两步都要遍历每条正文，
    /// 而单条保存时真正变的只有一条。记忆化之后，改一条条目从「重扫 240 篇正文 × 2 遍」
    /// 降到「扫 1 篇」。条目被改动或删除时对应项在 `applyChanges` 里失效。
    private var bodyLinkCache: [String: [String]] = [:]

    /// 参与建图的字段。只有这些变了，节点与边才需要重算。
    ///
    /// `domains` / `sources` / `status` 都不在其中：改域归属、确认草稿
    /// 不会让任何一条边出现或消失，也没必要重建四个邻接索引。
    private struct GraphInput: Equatable {
        var title: String
        var relations: [WikiRelation]
        var links: [String]
    }
    private var graphInputs: [String: GraphInput] = [:]
    /// 布局代数号：后台算完的旧结果不能覆盖新数据。
    private var layoutGeneration: Int = 0
    /// 扫描代数号：两次重扫并发时，先发后到的那次结果必须丢掉。
    private var reloadGeneration: Int = 0

    init(root: URL) {
        self.root = root
    }

    var directory: URL {
        root.appending(path: ".qiyide/wiki", directoryHint: .isDirectory)
    }

    // MARK: 加载

    /// 扫描结果。为的是把「磁盘上发生了什么」和「内存怎么更新」分开：
    /// 前者可以在后台线程做，后者必须在主线程做。
    private enum ScanOutcome: Sendable {
        case missingDirectory
        case failed(String)
        case success([WikiEntry])
    }

    /// 后台扫描：列目录 → 读文件 → 解析 → 按更新时间排序。
    ///
    /// 全是纯 I/O 与纯函数，不碰任何实例状态，所以能安全地放在 detached task 里。
    /// 240 条约 245ms，留在主线程上就是开窗时的一次可见卡顿。
    nonisolated private static func scan(directory: URL) -> ScanOutcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else {
            return .missingDirectory
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .failed("读取知识库失败：\(error.localizedDescription)")
        }

        var parsed: [WikiEntry] = []
        parsed.reserveCapacity(urls.count)
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            parsed.append(WikiEntry.parse(text: text, fileURL: url))
        }
        return .success(parsed.sorted { $0.updatedAt > $1.updatedAt })
    }

    /// 重新扫描磁盘上的知识库。
    ///
    /// 只在两种情况下需要：首次载入，以及「文件被本次写入之外的东西改了」
    /// （外部编辑器、git 切分支、架构构建器）。自己写完就知道内容是什么，
    /// 走 `applyChanges` 即可——那里不读磁盘。
    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isReloading = true

        let directory = self.directory
        let outcome = await Task.detached(priority: .userInitiated) {
            // 显式写类型名：`Self.` 在 detached 闭包里会被当成捕获实例。
            WikiStore.scan(directory: directory)
        }.value

        // 期间又发起了一次扫描：这次结果已过期，直接丢弃。
        // 不判这个，先发后到的旧快照会盖掉新数据。
        guard generation == reloadGeneration else { return }
        isReloading = false
        apply(outcome)
    }

    /// 同步重扫。**只给没有视图生命周期的调用方**：离屏渲染、验收脚本、
    /// 以及 `init(autoLoad:)`。界面路径一律用 `await reload()`。
    func reloadNow() {
        reloadGeneration &+= 1
        apply(Self.scan(directory: directory))
    }

    /// 把扫描结果装进内存。必须在主线程。
    private func apply(_ outcome: ScanOutcome) {
        switch outcome {
        case .missingDirectory:
            errorMessage = nil
            entries = []
            graph = .empty
            titleIndex = [:]
            backlinkIndex = [:]
            entriesByID = [:]
            entriesByDomain = [:]
            searchRows = [:]
            bodyLinkCache = [:]
            architecture = .empty
            isLoaded = true

        case .failed(let message):
            // 目录读不出来时保留旧数据：临时 I/O 错误不该让整个知识库变空。
            errorMessage = message

        case .success(let scanned):
            errorMessage = nil
            entries = scanned
            // 全量重扫：正文可能被外部改过，所有派生缓存作废。
            searchRows = [:]
            bodyLinkCache = [:]
            graphInputs = [:]
            rebuildIndexes()
            rebuildGraph()
            architecture = WikiArchitecture.load(root: root)
            contentRevision &+= 1
            isLoaded = true
        }
    }

    /// 重建派生索引。
    ///
    /// `refreshing` 为 nil 表示全量（重扫磁盘后）；否则只重算这些条目的
    /// 检索行与正文链接——改一条条目时，其余 239 篇正文不可能变。
    private func rebuildIndexes(refreshing ids: Set<String>? = nil) {
        titleIndex = [:]
        entriesByID = [:]
        entriesByDomain = [:]
        entriesByID.reserveCapacity(entries.count)
        for entry in entries {
            titleIndex[entry.normalizedTitle] = entry.id
            entriesByID[entry.id] = entry
            for domain in entry.domains {
                entriesByDomain[domain, default: []].append(entry.id)
            }
            // 标题/标签/正文的小写副本是这个方法最贵的一步（要复制全部正文），
            // 没变的条目不能重算。
            guard ids == nil || ids?.contains(entry.id) == true else { continue }
            searchRows[entry.id] = SearchRow(
                id: entry.id,
                title: entry.title.lowercased(),
                tags: entry.tags.map { $0.lowercased() },
                body: entry.body.lowercased()
            )
        }
        if searchRows.count != entriesByID.count {
            searchRows = searchRows.filter { entriesByID[$0.key] != nil }
        }
        backlinkIndex = [:]
        for entry in entries {
            for target in outgoingLinks(of: entry) {
                guard let targetID = titleIndex[WikiEntry.normalize(target)] else { continue }
                backlinkIndex[targetID, default: []].insert(entry.id)
            }
        }
    }

    /// 正文 `[[链接]]` 的正则。编译一次复用。
    ///
    /// 原来每个条目都 `try? NSRegularExpression(...)` 新建一次：240 条就是 240 次编译，
    /// 是 `reload` 的主要开销之一（正则编译在 Debug 下尤其贵）。
    private static let bodyLinkRegex = try? NSRegularExpression(
        pattern: "\\[\\[([^\\[\\]]+)\\]\\]"
    )

    /// 正文里的 `[[链接]]`，按出现顺序去重。
    private func bodyLinks(of entry: WikiEntry) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        guard let regex = Self.bodyLinkRegex else { return [] }
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
        entry.relations.map(\.target) + cachedBodyLinks(of: entry)
    }

    /// 带记忆化的 `bodyLinks`。
    private func cachedBodyLinks(of entry: WikiEntry) -> [String] {
        if let cached = bodyLinkCache[entry.id] { return cached }
        let links = bodyLinks(of: entry)
        bodyLinkCache[entry.id] = links
        return links
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
            for target in cachedBodyLinks(of: entry) {
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

        // 记下这次建图用的输入，下次保存时据此判断「结构到底变没变」。
        var inputs: [String: GraphInput] = [:]
        inputs.reserveCapacity(entries.count)
        for entry in entries {
            inputs[entry.id] = GraphInput(
                title: entry.title,
                relations: entry.relations,
                links: cachedBodyLinks(of: entry)
            )
        }
        graphInputs = inputs

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

    /// 某个域下的条目，顺序与列表一致（按更新时间降序）。
    func entries(inDomain domainID: String) -> [WikiEntry] {
        (entriesByDomain[domainID] ?? []).compactMap { entry(id: $0) }
    }

    /// 不属于任何域的条目。
    ///
    /// 合并后左栏必须单独给它们一段：否则 AI 随手记的、以及历史遗留的条目
    /// 会既不在任何域下、又不会出现在任何分组里，等于凭空消失。
    var unassignedEntries: [WikiEntry] {
        entries.filter { $0.domains.isEmpty }
    }

    /// 条目里出现过的域 id。
    var taggedDomainIDs: Set<String> {
        Set(entriesByDomain.keys)
    }

    /// 是否有任何条目带域标记。
    ///
    /// 界面上到处要判「打标了没有」，每次都 `!taggedDomainIDs.isEmpty` 会现造一个 Set；
    /// 这里直接看索引空不空，O(1)。
    var hasDomainTags: Bool {
        !entriesByDomain.isEmpty
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
        // 按 `entries` 的顺序遍历（更新时间降序），同分时顺序才是稳定的——
        // 直接遍历字典每次结果顺序都不一样。
        for entry in entries {
            guard let row = searchRows[entry.id] else { continue }
            var score = 0
            if row.title.contains(keyword) { score += 6 }
            if row.tags.contains(where: { $0.contains(keyword) }) { score += 3 }
            if row.body.contains(keyword) { score += 1 }
            guard score > 0 else { continue }
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
        // 刚写进去的内容就在手上，不必再扫一遍磁盘（旧实现是 create → reload）。
        applyChanges(updated: [entry], removed: [])
        return self.entry(id: id) ?? entry
    }

    func save(_ entry: WikiEntry) throws {
        try ensureDirectory()
        var updated = entry
        updated.updatedAt = Date()
        try write(updated)
        // 增量更新，不重读磁盘。
        //
        // `reload()` 要把条目全部重读重解析（240 条实测 245ms），而 save 的入参
        // 本来就是最新内容——再从磁盘读回来是纯浪费。
        applyChanges(updated: [updated], removed: [])
    }

    /// 把一批改动并入内存索引并重建派生数据（不读文件）。
    ///
    /// 这是所有写入的唯一收口：单条保存、批量保存、批量确认、批量删除都走它。
    /// 索引与图谱只重建一次，条目再多也只有一轮。
    private func applyChanges(updated: [WikiEntry], removed: Set<String>) {
        guard !updated.isEmpty || !removed.isEmpty else { return }

        if !removed.isEmpty {
            entries.removeAll { removed.contains($0.id) }
            for id in removed {
                bodyLinkCache[id] = nil
                searchRows[id] = nil
            }
        }

        var touched: Set<String> = []
        touched.reserveCapacity(updated.count)
        if !updated.isEmpty {
            var positions: [String: Int] = [:]
            positions.reserveCapacity(entries.count)
            for (index, entry) in entries.enumerated() { positions[entry.id] = index }
            for entry in updated {
                if let index = positions[entry.id] {
                    entries[index] = entry
                } else {
                    positions[entry.id] = entries.count
                    entries.append(entry)
                }
                // 正文可能变了，缓存的链接与检索行都要作废。
                bodyLinkCache[entry.id] = nil
                touched.insert(entry.id)
            }
            entries.sort { $0.updatedAt > $1.updatedAt }
        }

        // 先判结构变没变，再决定重建到哪一层。
        // 「确认草稿」「改域归属」这类保存不动任何一条边，重建图谱纯属白烧 CPU。
        let structural = isStructuralChange(updated: updated, removed: removed)
        rebuildIndexes(refreshing: touched)
        if structural {
            rebuildGraph()
        } else {
            refreshGraphNodes(updated)
        }
        contentRevision &+= 1
    }

    /// 这批改动会不会改变图的结构（节点集合、边集合）。
    ///
    /// 判据是「建图输入的指纹」：标题（决定能否被 `[[链接]]` 指到）、
    /// 显式关系、正文链接。三者都没变，图就是同一张图。
    private func isStructuralChange(updated: [WikiEntry], removed: Set<String>) -> Bool {
        guard removed.isEmpty else { return true }
        guard !updated.isEmpty else { return false }
        for entry in updated {
            guard let previous = graphInputs[entry.id] else { return true }
            let current = GraphInput(
                title: entry.title,
                relations: entry.relations,
                links: cachedBodyLinks(of: entry)
            )
            guard current == previous else { return true }
        }
        return false
    }

    /// 结构没变时，只把节点自身的展示字段刷新一遍（草稿标记、类型）。
    ///
    /// 比起重建整张图，这里只改 `nodes[i]` 与索引字典里的一项，不碰邻接表。
    /// `type` 必须一起刷：它决定图上节点的颜色，改类型不该画成旧颜色。
    private func refreshGraphNodes(_ updated: [WikiEntry]) {
        var changed: [WikiNode] = []
        for entry in updated {
            guard var node = graph.node(entry.id) else { continue }
            guard node.isDraft != entry.isDraft || node.type != entry.type else { continue }
            node.isDraft = entry.isDraft
            node.type = entry.type
            changed.append(node)
        }
        graph.updateNodes(changed)
    }

    /// 只准备条目对象（分配 id 与文件路径），**不写盘也不重扫**。
    ///
    /// 批量生成时用。领域生成一次要写 8 条，若逐条 `create`，
    /// 每条都会触发一次全库重扫（重解析 240 个 md + 重建索引 + 重排图谱），
    /// 8 条就是 8 次——这部分开销比生成本身大得多。
    func prepareEntry(type: WikiEntryType, title: String) throws -> WikiEntry {
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
        return entry
    }

    /// 把 AI 生成的草稿落盘。永远是 draft，必须由人确认后才成为可信知识。
    ///
    /// `domainID` 是建档时按代码路径匹配出的归属（见 `WikiDomainBackfill.domain(forSources:graph:)`）：
    /// 有它，条目一落盘就挂在域上，域详情页当场有内容，不必再跑一遍「域归属」回填。
    ///
    /// `refresh` 为 false 时只写文件、不重建内存与图谱。
    /// 建档一轮会连续写十几条，每条都重算一次力导向布局会直接把主线程锁死
    /// （实测 159 节点一次布局一秒多，20 条就是二十多秒无响应）。
    @discardableResult
    func applyDraft(
        _ draft: WikiDraft,
        generatedBy: String,
        sources: [String],
        domainID: String? = nil,
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
            // 只在「还没有归属」时补。人工改过的域不能被每次建档冲掉。
            if updated.domains.isEmpty, let domainID {
                updated.domains = [domainID]
            }
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
            domains: domainID.map { [$0] } ?? [],
            relations: draft.relations,
            body: draft.body,
            updatedAt: Date(),
            fileURL: url,
            status: .draft,
            generatedBy: generatedBy
        )
        try write(entry)
        if refresh {
            applyChanges(updated: [entry], removed: [])
        }
        return entry
    }

    // MARK: 批量

    /// 批量保存：逐个写文件，最后并进内存一次。
    ///
    /// 收尾补边时会对上百个条目改关系。旧实现是「写完后 reload 一次」——
    /// 一次全量重扫看似省事，但要把刚写完的内容再从磁盘读回来；
    /// 这里直接把入参并进索引，索引与图谱也只重建一次。
    func save(_ entries: [WikiEntry]) throws {
        guard !entries.isEmpty else { return }
        try ensureDirectory()
        var written: [WikiEntry] = []
        written.reserveCapacity(entries.count)
        for entry in entries {
            var updated = entry
            updated.updatedAt = Date()
            try write(updated)
            written.append(updated)
        }
        applyChanges(updated: written, removed: [])
    }

    /// 批量确认。
    ///
    /// 逐个写文件、最后只更新一次内存：旧实现最后 reload，一百条草稿要重读重解析一百次。
    @discardableResult
    func confirm(ids: [String]) -> Int {
        var updated: [WikiEntry] = []
        for id in ids {
            guard let entry = entry(id: id), entry.isDraft else { continue }
            var copy = entry
            copy.status = .confirmed
            copy.updatedAt = Date()
            if (try? write(copy)) != nil { updated.append(copy) }
        }
        applyChanges(updated: updated, removed: [])
        return updated.count
    }

    /// 批量丢弃草稿：走废纸篓，可恢复。已确认的条目不动。
    @discardableResult
    func discardDrafts(ids: [String]) -> Int {
        var removed: Set<String> = []
        for id in ids {
            guard let entry = entry(id: id), entry.isDraft else { continue }
            if (try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)) != nil {
                removed.insert(id)
            }
        }
        applyChanges(updated: [], removed: removed)
        return removed.count
    }

    /// 批量删除：不限草稿，全部走废纸篓。
    @discardableResult
    func delete(ids: [String]) -> Int {
        var removed: Set<String> = []
        for id in ids {
            guard let entry = entry(id: id) else { continue }
            if (try? FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)) != nil {
                removed.insert(id)
            }
        }
        applyChanges(updated: [], removed: removed)
        return removed.count
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
        guard FileManager.default.fileExists(atPath: entry.fileURL.path) else {
            // 文件已经不在了（被外部删了）：内存里也不该留着它。
            applyChanges(updated: [], removed: [entry.id])
            return
        }
        // 走废纸篓，知识不该因为一次误点就永久消失。
        try FileManager.default.trashItem(at: entry.fileURL, resultingItemURL: nil)
        applyChanges(updated: [], removed: [entry.id])
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
