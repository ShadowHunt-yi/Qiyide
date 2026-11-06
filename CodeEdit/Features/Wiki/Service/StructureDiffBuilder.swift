//
//  StructureDiffBuilder.swift
//  CodeEdit
//
//  算出分支的结构增量。
//
//  口径和 PR 一致：基准是当前分支与目标分支的分叉点（merge-base），
//  不是目标分支的最新提交——否则别人后来合进主干的改动会被算成「我删的」。
//  头部默认是工作区：AI 写代码时最需要看的，往往是还没提交的那部分。
//
//  成本只和改动量有关：
//  头部的依赖事实要全仓扫一遍（只读每个文件的 import 段，几千个文件百毫秒级）；
//  基准一侧不切分支、不检出，只把「改过的文件」从 git 对象库里读出来重算，
//  没改过的文件两侧必然相同，直接复用。
//

import Foundation

enum StructureDiffBuilder {

    struct Options: Sendable {
        /// 目标分支。nil 时取远端默认分支。
        var target: String?
        var includeWorkingTree = true
        /// 事先声明的改动范围（域标识）。空集合表示没有声明，不做越界检查。
        var scope: Set<String> = []
    }

    enum Failure: Error, Sendable {
        case notRepository(String)
        case noTarget
        case noCommonAncestor(String)

        var message: String {
            switch self {
            case .notRepository(let reason): return reason
            case .noTarget: return "找不到可以对比的目标分支（试过 origin/main、origin/master、main、master）"
            case .noCommonAncestor(let target): return "当前分支和 \(target) 没有共同的祖先提交"
            }
        }
    }

    /// 一个文件在地图上的位置。
    struct Location: Hashable, Sendable {
        var domainID: String
        var moduleID: String
        var moduleTitle: String
        var moduleKey: String
        var subpath: [String]

        var path: [String] { [domainID, moduleID] + subpath }
    }

    /// 计算过程中共享的上下文。各步骤只读它，避免一长串参数来回传。
    struct Context {
        let root: URL
        let index: StructureIndex
        let options: Options
        let base: String
        var headFacts = StructureFacts.empty
        /// 基准版本里「改过的文件」的引用（已按基准一侧的文件清单解析）。
        var baseReferences: [StructureReference] = []
        var baseTexts: [String: String] = [:]
        /// 头部一侧改过的文件。它们在头部事实里的引用不能算进基准。
        var changedHeadPaths = Set<String>()
        private var locations: [String: Location?] = [:]

        init(root: URL, index: StructureIndex, options: Options, base: String) {
            self.root = root
            self.index = index
            self.options = options
            self.base = base
        }

        /// 路径 → 位置。按目录缓存：同一个目录下的文件位置相同，不必每个文件都走一遍规则。
        mutating func location(of path: String) -> Location? {
            guard path.hasSuffix(".java") else { return nil }
            let directory = (path as NSString).deletingLastPathComponent
            if let cached = locations[directory] { return cached }
            var result: Location?
            if let parts = index.assigner.parts(forFile: path) {
                let assignment = index.assigner.assign(parts: parts)
                let depth = assignment.moduleKey.split(separator: "/").count
                result = Location(
                    domainID: assignment.domainID,
                    moduleID: assignment.moduleID,
                    moduleTitle: assignment.moduleTitle,
                    moduleKey: assignment.moduleKey,
                    subpath: Array(parts.dropFirst(depth))
                )
            }
            locations[directory] = result
            return result
        }

        func domainTitle(_ id: String) -> String {
            index.domain(id)?.title ?? id
        }
    }

    // MARK: 入口

    static func load(root: URL, index: StructureIndex, options: Options) async -> Result<StructureDiff, Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: build(root: root, index: index, options: options))
            }
        }
    }

    static func build(root: URL, index: StructureIndex, options: Options) -> Result<StructureDiff, Failure> {
        if let reason = WikiChangeSource.unavailableReason(root: root) {
            return .failure(.notRepository(reason))
        }
        guard let target = options.target ?? StructureGit.defaultTarget(root: root),
              StructureGit.exists(target, root: root) else {
            return .failure(.noTarget)
        }
        guard let base = StructureGit.mergeBase(target: target, root: root) else {
            return .failure(.noCommonAncestor(target))
        }

        var context = Context(root: root, index: index, options: options, base: base)
        var diff = StructureDiff()
        var clock = Date()
        func lap(_ stage: String) {
            diff.timings.append(StructureTiming(stage: stage, milliseconds: Date().timeIntervalSince(clock) * 1000))
            clock = Date()
        }
        diff.headName = StructureGit.headName(root: root)
        diff.targetName = target
        diff.baseCommit = String(base.prefix(8))
        diff.commitCount = StructureGit.commitCount(since: base, root: root)
        diff.includesWorkingTree = options.includeWorkingTree
        diff.scope = options.scope

        let raw = StructureGit.changes(base: base, includeWorkingTree: options.includeWorkingTree, root: root)
        var changes = classify(raw, into: &diff, context: &context)
        lap("改动文件")

        // 基准一侧有哪些模块：头部有、基准没有的就是新模块；反过来就是被删光的模块。
        let baseFiles = StructureGit.files(at: base, root: root).filter { context.location(of: $0) != nil }
        let baseModules = Set(baseFiles.compactMap { context.location(of: $0)?.moduleID })
        let headModules = Set(index.domains.flatMap { $0.modules.map(\.id) })
        diff.newModules = headModules.subtracting(baseModules)
        var removed: [String: StructureRemovedModule] = [:]
        for path in baseFiles {
            guard let location = context.location(of: path), !headModules.contains(location.moduleID) else { continue }
            removed[location.moduleID] = StructureRemovedModule(
                id: location.moduleID,
                title: location.moduleTitle,
                key: location.moduleKey,
                domainID: location.domainID
            )
        }

        lap("基准模块")
        collectFacts(changes: changes, baseFiles: baseFiles, into: &context)
        diff.scannedFiles = context.headFacts.scannedFiles
        diff.unresolvedImports = context.headFacts.dangling.count
        lap("依赖事实")
        diff.edges = edgeChanges(context: &context)
        lap("依赖变化")
        diff.asks = makeAsks(changes: &changes, diff: diff, context: &context)
        diff.setChanges(changes, removedModules: Array(removed.values))
        lap("待确认")
        return .success(diff)
    }

    // MARK: 改动落位

    /// 把 git 的原始改动变成「落在某个模块上的文件改动」；不属于源码的只计数。
    private static func classify(
        _ raw: [StructureGit.RawChange],
        into diff: inout StructureDiff,
        context: inout Context
    ) -> [StructureFileChange] {
        let uncommitted = context.options.includeWorkingTree
            ? StructureGit.uncommittedPaths(root: context.root)
            : []
        var result: [StructureFileChange] = []

        func make(_ path: String, _ kind: StructureFileChange.Kind, _ location: Location, other: String? = nil) {
            result.append(StructureFileChange(
                path: path,
                kind: kind,
                counterpart: other,
                isUncommitted: uncommitted.contains(path),
                domainID: location.domainID,
                moduleID: location.moduleID,
                subpath: location.subpath
            ))
        }

        for change in raw {
            let here = context.location(of: change.path)
            let before = change.oldPath.flatMap { context.location(of: $0) }
            switch change.status {
            case .added:
                if let here { make(change.path, .added, here) } else { countAuxiliary(change.path, into: &diff) }
            case .modified:
                if let here { make(change.path, .modified, here) } else { countAuxiliary(change.path, into: &diff) }
            case .deleted:
                if let here { make(change.path, .deleted, here) } else { countAuxiliary(change.path, into: &diff) }
            case .renamed:
                guard let oldPath = change.oldPath else { continue }
                switch (before, here) {
                case let (before?, here?) where before.moduleID == here.moduleID:
                    // 模块内改名或挪子包：对结构来说就是一次变更，不是「删一个加一个」。
                    make(change.path, .modified, here, other: oldPath)
                case let (before?, here?):
                    make(oldPath, .deleted, before, other: change.path)
                    make(change.path, .added, here, other: oldPath)
                case let (before?, nil):
                    make(oldPath, .deleted, before)
                case let (nil, here?):
                    make(change.path, .added, here)
                case (nil, nil):
                    countAuxiliary(change.path, into: &diff)
                }
            }
        }
        pairUndetectedMoves(&result)
        return result
    }

    /// git 没认出来的移动：同名文件一处删、一处加，且各只有一个，按移动处理。
    ///
    /// git 按内容相似度判断改名，文件很小或挪动时顺手改了不少内容就认不出来，
    /// 结果是「删了一个类、加了一个类」——归属变了这件事反而看不到了。
    private static func pairUndetectedMoves(_ changes: inout [StructureFileChange]) {
        var deleted: [String: [Int]] = [:]
        var added: [String: [Int]] = [:]
        for (offset, change) in changes.enumerated() where change.counterpart == nil {
            switch change.kind {
            case .deleted: deleted[change.fileName, default: []].append(offset)
            case .added: added[change.fileName, default: []].append(offset)
            case .modified: break
            }
        }
        for (name, sources) in deleted {
            guard sources.count == 1, let targets = added[name], targets.count == 1 else { continue }
            changes[sources[0]].counterpart = changes[targets[0]].path
            changes[targets[0]].counterpart = changes[sources[0]].path
        }
    }

    /// 测试、文档和其他文件只计数，不参与结构判断。
    private static func countAuxiliary(_ path: String, into diff: inout StructureDiff) {
        let lower = path.lowercased()
        if lower.contains("/src/test/") || lower.contains("/test/") || lower.hasSuffix("test.java")
            || lower.hasSuffix("tests.java") {
            diff.testFiles += 1
        } else if lower.hasSuffix(".md") || lower.hasSuffix(".txt") || lower.hasPrefix("docs/")
            || lower.contains("/docs/") {
            diff.documentFiles += 1
        } else {
            diff.otherFiles += 1
        }
    }

    // MARK: 依赖事实

    /// 头部全量扫一遍；基准一侧只重算改过的文件。
    private static func collectFacts(
        changes: [StructureFileChange],
        baseFiles: [String],
        into context: inout Context
    ) {
        let headPaths = context.index.domains.flatMap { $0.modules.flatMap { $0.files.map(\.path) } }
        context.headFacts = StructureFacts.scan(root: context.root, paths: headPaths)

        // 头部一侧：新增、变更的文件；基准一侧：变更（含改名前的路径）、删除的文件。
        var basePaths = Set<String>()
        for change in changes {
            switch change.kind {
            case .added:
                context.changedHeadPaths.insert(change.path)
            case .modified:
                context.changedHeadPaths.insert(change.path)
                basePaths.insert(change.counterpart ?? change.path)
            case .deleted:
                basePaths.insert(change.path)
            }
        }

        let ordered = basePaths.sorted()
        context.baseTexts = StructureGit.contents(of: ordered, at: context.base, root: context.root)
        let resolver = JavaTypeResolver(paths: baseFiles)
        for path in ordered {
            guard let text = context.baseTexts[path] else { continue }
            context.baseReferences += StructureFacts.references(in: text, from: path, resolver: resolver).resolved
        }
    }

    // MARK: 依赖变化

    private struct Pair: Hashable {
        var from: String
        var to: String
    }

    /// 比较两侧「模块 → 模块」的引用集合，找出新增和消失的。
    private static func edgeChanges(context: inout Context) -> [StructureEdgeChange] {
        var head: [Pair: [StructureReference]] = [:]
        var base: [Pair: [StructureReference]] = [:]
        var domainOf: [String: String] = [:]

        func record(_ reference: StructureReference, into table: inout [Pair: [StructureReference]]) {
            guard let from = context.location(of: reference.from),
                  let to = context.location(of: reference.to),
                  from.moduleID != to.moduleID else { return }
            // 指向「未划分」「共享基建」的引用是所有人都会有的基础依赖，不算结构变化。
            let targetKind = context.index.domain(to.domainID)?.kind
            if targetKind == .unassigned || targetKind == .shared { return }
            domainOf[from.moduleID] = from.domainID
            domainOf[to.moduleID] = to.domainID
            table[Pair(from: from.moduleID, to: to.moduleID), default: []].append(reference)
        }

        for reference in context.headFacts.references {
            record(reference, into: &head)
            // 没改过的文件，两侧的引用必然一样。
            if !context.changedHeadPaths.contains(reference.from) {
                record(reference, into: &base)
            }
        }
        for reference in context.baseReferences {
            record(reference, into: &base)
        }

        func domainPairs(_ table: [Pair: [StructureReference]]) -> Set<Pair> {
            Set(table.keys.compactMap { pair in
                guard let from = domainOf[pair.from], let to = domainOf[pair.to], from != to else { return nil }
                return Pair(from: from, to: to)
            })
        }
        let headDomains = domainPairs(head)
        let baseDomains = domainPairs(base)

        var result: [StructureEdgeChange] = []
        for (pair, references) in head where base[pair] == nil {
            guard let from = domainOf[pair.from], let to = domainOf[pair.to] else { continue }
            result.append(StructureEdgeChange(
                kind: .added,
                fromDomain: from,
                toDomain: to,
                fromModule: pair.from,
                toModule: pair.to,
                references: references,
                changesDomainPair: from != to && !baseDomains.contains(Pair(from: from, to: to))
            ))
        }
        for (pair, references) in base where head[pair] == nil {
            guard let from = domainOf[pair.from], let to = domainOf[pair.to] else { continue }
            result.append(StructureEdgeChange(
                kind: .removed,
                fromDomain: from,
                toDomain: to,
                fromModule: pair.from,
                toModule: pair.to,
                references: references,
                changesDomainPair: from != to && !headDomains.contains(Pair(from: from, to: to))
            ))
        }
        return result.sorted { $0.id < $1.id }
    }
}
