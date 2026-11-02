//
//  WikiDomainBackfill.swift
//  CodeEdit
//
//  给历史知识条目补「所属域」。
//
//  为什么先出报告、不直接改文件：
//  归属只能靠「条目的 sources 路径里是否含某个域的包路径」推断，
//  包被改名、条目横跨两个域时必然有歧义。直接批量改 md 会产生一堆
//  难以 review 的 diff，错了还得一条条回滚。
//  所以这里只算「建议」，由人看过再一次性写入。
//
//  为什么不能自动归属多义项：
//  一个条目同时命中两个域，说明它写的是「两边共同遵守的约定」。
//  随便挑一个塞进去，比留在「未归类」更糟——以后没人会再去检查它。
//

import Foundation

/// 一次回填分析的结果。只描述建议，不碰文件。
struct DomainBackfillReport: Sendable {

    /// 一条建议：某条目应该归到某个域，以及判断所依据的代码路径。
    struct Suggestion: Sendable, Identifiable {
        var entryID: String
        var entryTitle: String
        var domainID: String
        var domainTitle: String
        /// 命中的那条 source，用于人工核对。
        var via: String

        var id: String { entryID + "→" + domainID }
    }

    /// 完全匹配不到任何域的条目。
    struct Orphan: Sendable, Identifiable {
        var entryID: String
        var entryTitle: String
        var sourceCount: Int

        var id: String { entryID }
    }

    /// 一条知识都没有的域。
    struct Gap: Sendable, Identifiable {
        var domainID: String
        var domainTitle: String
        var classCount: Int

        var id: String { domainID }
    }

    /// 已经有域标记、无需处理的条目数。
    var alreadyTagged: Int = 0
    /// 能唯一确定归属的条目。
    var suggestions: [Suggestion] = []
    /// 命中多个域，需要人判断。
    var ambiguous: [Suggestion] = []
    /// 匹配不到任何域。
    var orphans: [Orphan] = []
    /// 没有对应知识的域。
    var gaps: [Gap] = []

    var isEmpty: Bool {
        suggestions.isEmpty && ambiguous.isEmpty && orphans.isEmpty && gaps.isEmpty
    }

    var summary: String {
        "已标 \(alreadyTagged) · 可归属 \(suggestions.count) · 多义 \(ambiguous.count)"
            + " · 无归属 \(orphans.count) · 空缺域 \(gaps.count)"
    }
}

// MARK: - 分析

enum WikiDomainBackfill {

    /// 一个域在路径匹配时用的键集合。
    private struct DomainProfile {
        var id: String
        var title: String
        var classCount: Int
        /// 按长度降序，长的先匹配（`agent/suggest` 优先于 `agent`）。
        var keys: [String]
    }

    /// 只算不写。
    @MainActor
    static func report(graph: MindGraph, store: WikiStore) -> DomainBackfillReport {
        var report = DomainBackfillReport()
        let profiles = profiles(in: graph)
        guard !profiles.isEmpty else { return report }

        for entry in store.entries {
            guard entry.domains.isEmpty else {
                report.alreadyTagged += 1
                continue
            }

            switch resolve(entry: entry, profiles: profiles) {
            case .none:
                report.orphans.append(DomainBackfillReport.Orphan(
                    entryID: entry.id,
                    entryTitle: entry.displayTitle,
                    sourceCount: entry.sources.count
                ))
            case .one(let hit):
                report.suggestions.append(suggestion(entry: entry, hit: hit))
            case .several(let hit):
                report.ambiguous.append(suggestion(entry: entry, hit: hit))
            }
        }

        // 空缺域：一个条目都没挂上的域。建议归属里的也算「将要有」。
        var covered = store.taggedDomainIDs
        covered.formUnion(report.suggestions.map(\.domainID))
        for profile in profiles where !covered.contains(profile.id) {
            report.gaps.append(DomainBackfillReport.Gap(
                domainID: profile.id,
                domainTitle: profile.title,
                classCount: profile.classCount
            ))
        }

        return report
    }

    /// 一个条目最终归到哪个域。
    enum Resolution {
        case none
        case one(Hit)
        /// 跨源命中多个域：条目写的是「共同约定」，不自动归属。
        case several(Hit)
    }

    struct Hit {
        var domainID: String
        var domainTitle: String
        /// 命中的域键（业务包路径）。
        var key: String
        /// 命中的那条 source，用于人工核对。
        var source: String
    }

    /// 归属判定。
    ///
    /// 规则优先级（每条都由真实仓库的误判逼出来的）：
    /// 1. **同一路径上，靠前的业务段优先**。`agent/service/X.java` 同时含 `agent` 和
    ///    `service` 两段，但它属于 `agent` 那个产品线——`service` 只是子目录名。
    /// 2. **同一起点则更长的键优先**。`service/portrait` 比 `service` 具体，
    ///    兜底域（按一级包聚合出来的）永远不该抢走具体域已经认领的路径。
    /// 3. **不同 source 命中不同域 → 多义**。这才是真正的跨域条目。
    private static func resolve(entry: WikiEntry, profiles: [DomainProfile]) -> Resolution {
        resolve(sources: entry.sources, profiles: profiles)
    }

    /// 一组代码路径归到哪个域。建档与回填共用同一套规则，避免两处判定不一致。
    private static func resolve(sources: [String], profiles: [DomainProfile]) -> Resolution {
        // 先按 source 分组：一条 source 最多投出一个域。
        var winnerBySource: [String: Hit] = [:]

        for source in sources {
            var best: (hit: Hit, index: Int)?
            for profile in profiles {
                for key in profile.keys {
                    guard let index = matchIndex(source: source, key: key) else { continue }
                    // 位置更靠前优先；同位置时更长的 key 优先。
                    if let current = best {
                        if index > current.index { continue }
                        if index == current.index, key.count <= current.hit.key.count { continue }
                    }
                    best = (
                        Hit(
                            domainID: profile.id,
                            domainTitle: profile.title,
                            key: key,
                            source: source
                        ),
                        index
                    )
                }
            }
            if let best, winnerBySource[source] == nil {
                winnerBySource[source] = best.hit
            }
        }

        guard !winnerBySource.isEmpty else { return .none }

        // 再按域去重：多条 source 指向同一个域，仍然算唯一。
        var unique: [String: Hit] = [:]
        for hit in winnerBySource.values where unique[hit.domainID] == nil {
            unique[hit.domainID] = hit
        }

        if unique.count == 1, let hit = unique.values.first {
            return .one(hit)
        }

        // 多个域都成立：取最靠前的那条做展示建议，但标记为需人工确认。
        guard let first = unique.values.min(by: { lhs, rhs in
            let left = matchIndex(source: lhs.source, key: lhs.key) ?? Int.max
            let right = matchIndex(source: rhs.source, key: rhs.key) ?? Int.max
            if left != right { return left < right }
            return lhs.key.count > rhs.key.count
        }) else { return .none }
        return .several(first)
    }

    /// 给一组代码路径找域。**建档时用**：条目落盘就带归属，不必事后回填。
    ///
    /// 与回填完全同一套规则：只有「唯一确定」才返回，多义和无归属都返回 nil。
    /// 多义不猜是有意的——一条写在两个域共同边界上的知识，塞进任一边都比留在
    /// 「未归类」更糟，因为以后不会再有人回头看它。
    ///
    /// - Parameters:
    ///   - sources: 仓库相对路径（可以是文件，也可以是包路径）。
    ///   - graph: 已锁定的领域模型。
    /// - Returns: 命中信息；域模型为空时返回 nil。
    static func domain(forSources sources: [String], graph: MindGraph) -> Hit? {
        let profiles = profiles(in: graph)
        guard !profiles.isEmpty, !sources.isEmpty else { return nil }
        guard case .one(let hit) = resolve(sources: sources, profiles: profiles) else { return nil }
        return hit
    }

    /// 按报告写入。只补「唯一确定」的条目；多义与无归属一律不动。
    @MainActor
    @discardableResult
    static func apply(_ report: DomainBackfillReport, store: WikiStore) throws -> Int {
        var updated: [WikiEntry] = []
        for suggestion in report.suggestions {
            guard var entry = store.entry(id: suggestion.entryID),
                  entry.domains.isEmpty else { continue }
            entry.domains = [suggestion.domainID]
            updated.append(entry)
        }
        guard !updated.isEmpty else { return 0 }
        // 批量保存：只 reload 一次。逐条 save 会触发 N 次全库重扫 + 图谱重排。
        try store.save(updated)
        return updated.count
    }

    // MARK: 匹配

    private static func profiles(in graph: MindGraph) -> [DomainProfile] {
        graph.domains.map { domain in
            var keys = domain.packages
            for child in graph.children(of: domain.id) {
                keys.append(contentsOf: child.packages)
            }
            var seen = Set<String>()
            let unique = keys
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .sorted { $0.count > $1.count }
            return DomainProfile(
                id: domain.id,
                title: domain.displayTitle,
                classCount: domain.classCount,
                keys: unique
            )
        }
    }

    /// `key` 作为完整路径段出现在 `source` 里的位置；不出现返回 nil。
    ///
    /// 必须按「段」匹配：`agent/suggest` 不能命中 `agent/suggestion`。
    /// 返回值同时用于排序——越靠前的段越接近业务顶层（`agent` 比 `service` 更靠上）。
    private static func matchIndex(source: String, key: String) -> Int? {
        guard !key.isEmpty else { return nil }
        if source == key { return 0 }

        var start = source.startIndex
        while let range = source.range(of: key, range: start..<source.endIndex) {
            let beforeOK = range.lowerBound == source.startIndex
                || source[source.index(before: range.lowerBound)] == "/"
            let afterOK = range.upperBound == source.endIndex
                || source[range.upperBound] == "/"
            if beforeOK && afterOK {
                return source.distance(from: source.startIndex, to: range.lowerBound)
            }
            start = source.index(after: range.lowerBound)
        }
        return nil
    }

    private static func suggestion(entry: WikiEntry, hit: Hit) -> DomainBackfillReport.Suggestion {
        DomainBackfillReport.Suggestion(
            entryID: entry.id,
            entryTitle: entry.displayTitle,
            domainID: hit.domainID,
            domainTitle: hit.domainTitle,
            via: hit.source
        )
    }
}
