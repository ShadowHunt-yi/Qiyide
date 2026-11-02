//
//  WikiCoherence.swift
//  CodeEdit
//
//  一致性体检：把「模型 / 知识 / 代码」三者对不上的地方一次列出来。
//
//  为什么这件事必须做在合并之后：
//  以前领域模型、知识条目、架构视图各存一份、没有共同键，
//  「这个域被改名了，那几条挂在上面的知识怎么办」这种问题根本无从检查——
//  连「挂在上面的知识」是什么都不知道。有了 DomainID 才问得出这个问题。
//
//  只报「确定错了」的事，不做模糊推断：
//  宁可少报一条，也不要让人在几十条误报里失去信任。
//

import Foundation

// MARK: - 报告

struct CoherenceReport: Sendable {

    enum Kind: String, Sendable, CaseIterable {
        /// 条目挂在一个已经不存在的域上（域被合并/改名/删除）。
        case dangling
        /// 域存在，但一条知识都没有。
        case gap
        /// 条目没有归属。
        case unassigned
        /// 条目关联的代码文件已经不在了。
        case staleSource
        /// 领域模型基于的提交落后于当前 HEAD。
        case baseDrift

        var title: String {
            switch self {
            case .dangling: return "悬空归属"
            case .gap: return "空缺域"
            case .unassigned: return "未归类"
            case .staleSource: return "过期关联"
            case .baseDrift: return "基线落后"
            }
        }

        /// 能不能在体检面板里直接处理。
        var isFixable: Bool {
            self == .dangling
        }
    }

    struct Issue: Sendable, Identifiable {
        var kind: Kind
        /// 一行主文案，如「AI画像」。
        var headline: String
        /// 次要说明，如「domain:service/portrait 已不存在」。
        var detail: String
        var entryID: String?
        var domainID: String?

        var id: String {
            "\(kind.rawValue)|\(entryID ?? "")|\(domainID ?? "")|\(headline)"
        }
    }

    var issues: [Issue] = []
    var checkedAt: Date = .distantPast

    func count(_ kind: Kind) -> Int {
        issues.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    var total: Int { issues.count }
    var isEmpty: Bool { issues.isEmpty }

    /// 按严重程度排序后的分组，供面板直接渲染。
    var groups: [(kind: Kind, issues: [Issue])] {
        Kind.allCases.compactMap { kind in
            let items = issues.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind, items)
        }
    }
}

// MARK: - 检查

enum WikiCoherence {

    /// 单条「过期关联」最多报多少条。文件批量改名时可能几千条，全列没有意义。
    private static let staleLimit = 40

    /// 检查所需的输入快照。
    ///
    /// 为什么要有这一层：体检里有两类开销，一类是遍历条目（主线程，微秒级），
    /// 一类是 `git rev-parse` 加几千次 `fileExists`（几十毫秒，纯 I/O）。
    /// 前者必须在主线程取，后者不该占着主线程——分开之后，后者才能挪到后台。
    struct Snapshot: Sendable {

        struct Entry: Sendable {
            let id: String
            let displayTitle: String
            let domains: [String]
            let sources: [String]
        }

        struct Domain: Sendable {
            let id: String
            let displayTitle: String
            let classCount: Int
            let entryCount: Int
        }

        var entries: [Entry] = []
        var domains: [Domain] = []
        /// 「未归类」摘要只需要前几条标题，不必把整串搬过来。
        var unassignedTitles: [String] = []
        var unassignedCount: Int = 0
        var hasDomainTags: Bool = false
    }

    /// 从内存取数。必须是主线程——它读的是 store 的索引。
    @MainActor
    static func snapshot(graph: MindGraph, store: WikiStore) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.entries = store.entries.map { entry in
            Snapshot.Entry(
                id: entry.id,
                displayTitle: entry.displayTitle,
                domains: entry.domains,
                sources: entry.sources
            )
        }
        snapshot.domains = graph.domains.map { domain in
            Snapshot.Domain(
                id: domain.id,
                displayTitle: domain.displayTitle,
                classCount: domain.classCount,
                entryCount: store.entries(inDomain: domain.id).count
            )
        }
        let orphans = store.unassignedEntries
        snapshot.unassignedTitles = Array(orphans.prefix(3).map(\.displayTitle))
        snapshot.unassignedCount = orphans.count
        snapshot.hasDomainTags = store.hasDomainTags
        return snapshot
    }

    /// 体检本体：只看快照和磁盘，不碰 store，因此可以放后台。
    static func evaluate(_ snapshot: Snapshot, root: URL, baseCommit: String) -> CoherenceReport {
        var report = CoherenceReport()
        report.checkedAt = Date()

        let domainIDs = Set(snapshot.domains.map(\.id))

        // 1) 悬空：条目指向的域已经不存在。
        for entry in snapshot.entries {
            for domainID in entry.domains where !domainIDs.contains(domainID) {
                report.issues.append(CoherenceReport.Issue(
                    kind: .dangling,
                    headline: entry.displayTitle,
                    detail: "\(domainID) 已不存在（域被改名或合并？）",
                    entryID: entry.id,
                    domainID: domainID
                ))
            }
        }

        // 2) 空缺 / 未归类。
        // 一条都没打标时，不该报「8 个域全都空缺」——那只是没建立归属，
        // 一条「未归类」就说明了全部问题。
        if !snapshot.hasDomainTags {
            if !snapshot.entries.isEmpty {
                report.issues.append(CoherenceReport.Issue(
                    kind: .unassigned,
                    headline: "\(snapshot.entries.count) 条知识未标归属",
                    detail: "用「域归属」按代码路径批量补写",
                    entryID: nil,
                    domainID: nil
                ))
            }
        } else {
            for domain in snapshot.domains where domain.entryCount == 0 {
                report.issues.append(CoherenceReport.Issue(
                    kind: .gap,
                    headline: domain.displayTitle,
                    detail: "\(domain.classCount) 类，没有对应知识",
                    entryID: nil,
                    domainID: domain.id
                ))
            }
            if snapshot.unassignedCount > 0 {
                let sample = snapshot.unassignedTitles.joined(separator: "、")
                report.issues.append(CoherenceReport.Issue(
                    kind: .unassigned,
                    headline: "\(snapshot.unassignedCount) 条知识未归类",
                    detail: snapshot.unassignedCount > 3 ? "\(sample) 等" : sample,
                    entryID: nil,
                    domainID: nil
                ))
            }
        }

        // 3) 过期关联：只查「看起来是文件」的 source。
        //
        // 领域生成的条目里 source 是业务包路径（`agent/suggest`），不是仓库相对文件，
        // 拿去判存在必然误报。这里只检查带扩展名的路径——宁可漏报目录类 source。
        let manager = FileManager.default
        var stale = 0
        outer: for entry in snapshot.entries {
            for source in entry.sources {
                guard (source as NSString).pathExtension.isEmpty == false else { continue }
                guard !manager.fileExists(atPath: root.appending(path: source).path) else { continue }
                stale += 1
                if stale <= staleLimit {
                    report.issues.append(CoherenceReport.Issue(
                        kind: .staleSource,
                        headline: entry.displayTitle,
                        detail: source,
                        entryID: entry.id,
                        domainID: nil
                    ))
                }
                if stale > staleLimit { break outer }
            }
        }

        // 4) 基线落后：模型基于旧提交。git 只在真要判的时候跑一次。
        if !baseCommit.isEmpty {
            let head = baseCommitAtHEAD(root: root)
            if !head.isEmpty, baseCommit != head {
                report.issues.append(CoherenceReport.Issue(
                    kind: .baseDrift,
                    headline: "模型基于 \(String(baseCommit.prefix(7)))",
                    detail: "当前 HEAD \(String(head.prefix(7)))",
                    entryID: nil,
                    domainID: nil
                ))
            }
        }

        return report
    }

    /// 当前 HEAD。不是 git 仓库时返回空串。
    private static func baseCommitAtHEAD(root: URL) -> String {
        WikiChangeSource.run(["rev-parse", "HEAD"], at: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 同步体检。命令行走私、验收脚本用；界面走 `checkAsync`。
    @MainActor
    static func check(root: URL, graph: MindGraph, store: WikiStore) -> CoherenceReport {
        evaluate(snapshot(graph: graph, store: store), root: root, baseCommit: graph.baseCommit)
    }

    /// 异步体检：取数在主线程（O(条目数)），git 与文件存在性检查在后台。
    @MainActor
    static func checkAsync(root: URL, graph: MindGraph, store: WikiStore) async -> CoherenceReport {
        let snapshot = snapshot(graph: graph, store: store)
        let baseCommit = graph.baseCommit
        return await Task.detached(priority: .utility) {
            evaluate(snapshot, root: root, baseCommit: baseCommit)
        }.value
    }

    /// 清掉所有悬空归属。只改 `domains` 字段，正文与其他元数据不动。
    @MainActor
    @discardableResult
    static func clearDangling(_ report: CoherenceReport, store: WikiStore) throws -> Int {
        let targets = report.issues.filter { $0.kind == .dangling }
        guard !targets.isEmpty else { return 0 }

        let deadDomains = Set(targets.compactMap(\.domainID))
        var updated: [WikiEntry] = []
        for entry in store.entries {
            let kept = entry.domains.filter { !deadDomains.contains($0) }
            guard kept.count != entry.domains.count else { continue }
            var copy = entry
            copy.domains = kept
            updated.append(copy)
        }
        guard !updated.isEmpty else { return 0 }
        try store.save(updated)
        return updated.count
    }
}
