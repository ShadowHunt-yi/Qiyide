//
//  StructureDiffBuilder+Asks.swift
//  CodeEdit
//
//  把结构变化变成「待确认」：每条是一道判断题，带着能点开核对的证据。
//
//  生成规则偏保守。一条假的「新增跨域依赖」比漏报更伤——人被骗过一次，
//  之后整张清单都不会再认真看。所以每条待确认都必须指得出具体的文件和行；
//  拿不出证据的变化（比如只改了方法体）一律不生成。
//
//  标识是稳定的：同一件事在两次计算里标识相同，人做过的决定才对得上。
//

import Foundation

extension StructureDiffBuilder {

    static func makeAsks(
        changes: inout [StructureFileChange],
        diff: StructureDiff,
        context: inout Context
    ) -> [StructureAsk] {
        // 文件路径 → 它卷入了哪几类待确认。最后一次性写回改动列表。
        var tagged: [String: Set<StructureAsk.Kind>] = [:]

        var asks = newModuleAsks(diff: diff, context: &context, tagged: &tagged)
        // 等着归属的新包，它自己带来的依赖不再单独问：
        // 「它引用了谁」本来就是「它该归谁」这道题的一部分，拆成两条只会让人答两遍。
        let pending = Set(asks.flatMap { $0.anchors.compactMap { $0.count > 1 ? $0[1] : nil } })
        asks += moveAsks(changes: changes, context: &context, tagged: &tagged)
        asks += dependencyAsks(diff: diff, excluding: pending, context: &context, tagged: &tagged)
        asks += interfaceAsks(changes: changes, context: &context, tagged: &tagged)
        asks += scopeAsks(changes: changes, context: context, tagged: &tagged)

        for offset in changes.indices {
            changes[offset].tags = tagged[changes[offset].path] ?? []
        }
        return asks
    }

    private static func className(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: 地图：新包

    /// 落进兜底域或「未划分」的新包要人确认归属。
    ///
    /// 普通业务域下面新加的子包不问：它的归属由路径决定，没有歧义。
    /// 兜底域不一样——它本来就是「还没想清楚归谁」的那部分，新东西掉进去不该悄悄算数。
    private static func newModuleAsks(
        diff: StructureDiff,
        context: inout Context,
        tagged: inout [String: Set<StructureAsk.Kind>]
    ) -> [StructureAsk] {
        var asks: [StructureAsk] = []
        for moduleID in diff.newModules.sorted() {
            guard let module = context.index.module(moduleID),
                  let domain = context.index.domain(ofModule: moduleID),
                  domain.kind == .catchAll || domain.kind == .unassigned else { continue }

            // 它和哪个域往来最多：这是「该归谁」最直接的线索。
            var outgoing: [String: [StructureReference]] = [:]
            var incoming: [String: Int] = [:]
            for file in module.files {
                tagged[file.path, default: []].insert(.map)
                for reference in context.headFacts.outgoing(from: file.path) {
                    guard let other = context.location(of: reference.to)?.domainID, other != domain.id else { continue }
                    outgoing[other, default: []].append(reference)
                }
                for reference in context.headFacts.incoming(to: file.path) {
                    guard let other = context.location(of: reference.from)?.domainID, other != domain.id else {
                        continue
                    }
                    incoming[other, default: 0] += 1
                }
            }
            let partners = Set(outgoing.keys).union(incoming.keys).filter {
                let kind = context.index.domain($0)?.kind
                return kind == .domain || kind == .catchAll
            }
            let closest = partners.max {
                let lhs = (outgoing[$0]?.count ?? 0) + (incoming[$0] ?? 0)
                let rhs = (outgoing[$1]?.count ?? 0) + (incoming[$1] ?? 0)
                return lhs != rhs ? lhs < rhs : $0 > $1
            }

            let place = domain.kind == .catchAll ? "兜底域「\(domain.title)」" : "「未划分」"
            var detail = "\(module.classCount) 个新类落在\(place)。"
            var evidence: [StructureEvidence] = []
            if let closest {
                let title = context.domainTitle(closest)
                detail += "它和「\(title)」往来最多：引用对方 \(outgoing[closest]?.count ?? 0) 处，"
                    + "被对方引用 \(incoming[closest] ?? 0) 处。"
                evidence = (outgoing[closest] ?? []).prefix(3).map {
                    StructureEvidence(file: $0.from, line: $0.line, sign: "+", text: $0.text)
                }
            } else {
                detail += "它和其他域没有往来。"
            }
            var ask = StructureAsk(
                id: "map:new:" + moduleID,
                kind: .map,
                title: "新包 \(module.key) 待归属",
                detail: detail,
                anchors: [[domain.id, moduleID]],
                evidence: evidence
            )
            if let closest {
                ask.adoption = StructureAsk.Adoption(
                    moduleKey: module.key,
                    moduleTitle: module.title,
                    domainID: closest,
                    domainTitle: context.domainTitle(closest)
                )
            }
            asks.append(ask)
        }
        return asks
    }

    // MARK: 地图：跨域移动

    private static func moveAsks(
        changes: [StructureFileChange],
        context: inout Context,
        tagged: inout [String: Set<StructureAsk.Kind>]
    ) -> [StructureAsk] {
        struct Move {
            var from: Location
            var to: Location
            var files: [(old: String, new: String)] = []
        }
        var moves: [String: Move] = [:]
        for change in changes where change.kind == .added {
            guard let oldPath = change.counterpart,
                  let from = context.location(of: oldPath),
                  let to = context.location(of: change.path),
                  from.domainID != to.domainID else { continue }
            let key = from.moduleID + "->" + to.moduleID
            var move = moves[key] ?? Move(from: from, to: to)
            move.files.append((oldPath, change.path))
            moves[key] = move
            tagged[oldPath, default: []].insert(.map)
            tagged[change.path, default: []].insert(.map)
        }

        return moves.keys.sorted().compactMap { key in
            guard let move = moves[key], let first = move.files.first else { return nil }
            let source = "\(context.domainTitle(move.from.domainID)) › \(move.from.moduleTitle)"
            let target = "\(context.domainTitle(move.to.domainID)) › \(move.to.moduleTitle)"
            let names = move.files.count == 1
                ? className(first.new)
                : "\(className(first.new)) 等 \(move.files.count) 个文件"
            var evidence: [StructureEvidence] = []
            for file in move.files.prefix(3) {
                evidence.append(StructureEvidence(file: file.old, line: 0, sign: "-", text: file.old))
                evidence.append(StructureEvidence(file: file.new, line: 0, sign: "+", text: file.new))
            }
            return StructureAsk(
                id: "map:move:" + key,
                kind: .map,
                title: "\(move.files.count) 个文件跨域移动 \(source) → \(target)",
                detail: "\(names) 从「\(source)」移到了「\(target)」。归属变了。",
                anchors: [
                    [move.from.domainID, move.from.moduleID],
                    [move.to.domainID, move.to.moduleID]
                ],
                evidence: evidence,
                remedy: "把 \(names) 移回「\(source)」。本次改动不应改变它们的归属。"
            )
        }
    }

    // MARK: 依赖

    /// 跨域的依赖变化按「域 → 域」合并成一条：同一对域之间多出三个模块的引用，是一个决定，不是三个。
    private static func dependencyAsks(
        diff: StructureDiff,
        excluding pending: Set<String>,
        context: inout Context,
        tagged: inout [String: Set<StructureAsk.Kind>]
    ) -> [StructureAsk] {
        var groups: [String: [StructureEdgeChange]] = [:]
        for edge in diff.edges where edge.crossesDomains && !pending.contains(edge.fromModule) {
            let prefix = edge.kind == .added ? "dep:add:" : "dep:del:"
            groups[prefix + edge.fromDomain + "->" + edge.toDomain, default: []].append(edge)
        }

        var asks: [StructureAsk] = []
        for key in groups.keys.sorted() {
            guard let edges = groups[key], let first = edges.first else { continue }
            let references = edges.flatMap(\.references)
            let source = context.domainTitle(first.fromDomain)
            let target = context.domainTitle(first.toDomain)
            func moduleTitle(_ id: String, fallback: String) -> String {
                context.index.module(id)?.title ?? context.location(of: fallback)?.moduleTitle ?? id
            }
            let targetModules = Array(Set(edges.map {
                moduleTitle($0.toModule, fallback: $0.references.first?.to ?? "")
            })).sorted()

            var anchors: [[String]] = []
            for reference in references {
                tagged[reference.from, default: []].insert(.dependency)
                if let location = context.location(of: reference.from), !anchors.contains(location.path) {
                    anchors.append(location.path)
                }
            }
            for edge in edges where !anchors.contains([edge.toDomain, edge.toModule]) {
                anchors.append([edge.toDomain, edge.toModule])
            }

            let label: String
            if edges.count == 1 {
                let sourceModule = moduleTitle(first.fromModule, fallback: first.references.first?.from ?? "")
                label = "\(source) › \(sourceModule) → \(target) › \(targetModules.joined(separator: "、"))"
            } else {
                label = "\(source) → \(target)"
            }
            let files = Array(Set(references.map { className($0.from) })).sorted()
            let who = files.count == 1 ? files[0] : "\(files[0]) 等 \(files.count) 个文件"
            let sign = first.kind == .added ? "+" : "-"
            let evidence = references.prefix(6).map {
                StructureEvidence(file: $0.from, line: $0.line, sign: sign, text: $0.text)
            }
            let changesPair = edges.contains(where: \.changesDomainPair)

            if first.kind == .added {
                let history = changesPair
                    ? "这两个域之前没有直接依赖。"
                    : "「\(source)」之前已经依赖「\(target)」的其他模块。"
                asks.append(StructureAsk(
                    id: key,
                    kind: .dependency,
                    title: "新增依赖 \(label)",
                    detail: "\(who) 开始引用「\(target)」的 \(targetModules.joined(separator: "、"))，"
                        + "共 \(references.count) 处。\(history)",
                    anchors: anchors,
                    evidence: evidence,
                    remedy: "「\(source)」不应直接依赖「\(target)」的 \(targetModules.joined(separator: "、"))："
                        + "移除 \(files.joined(separator: "、")) 里的这 \(references.count) 处引用，"
                        + "改为经由对方的对外接口，或由调用方把需要的数据传进来。"
                ))
            } else {
                let after = changesPair ? "两个域之间不再有直接依赖。" : ""
                asks.append(StructureAsk(
                    id: key,
                    kind: .dependency,
                    title: "依赖消失 \(label)",
                    detail: "原有的 \(references.count) 处引用全部移除了。\(after)请确认这是有意解耦，而不是功能被删掉。",
                    anchors: anchors,
                    evidence: evidence,
                    remedy: "恢复「\(source)」对「\(target)」的 \(targetModules.joined(separator: "、")) 的引用，"
                        + "或说明替代的数据来源。"
                ))
            }
        }
        return asks
    }

    // MARK: 接口

    /// 被别的域引用的类，公开签名变了；或者文件删了但还有人在引用。
    private static func interfaceAsks(
        changes: [StructureFileChange],
        context: inout Context,
        tagged: inout [String: Set<StructureAsk.Kind>]
    ) -> [StructureAsk] {
        var asks: [StructureAsk] = []
        for change in changes {
            guard let here = context.location(of: change.path) else { continue }

            if change.kind == .deleted {
                guard let name = JavaTypeResolver.typeName(forPath: change.path) else { continue }
                let dangling = context.headFacts.dangling.filter { $0.name == name || $0.name.hasPrefix(name + ".") }
                guard !dangling.isEmpty else { continue }
                var anchors = [here.path]
                for item in dangling {
                    if let location = context.location(of: item.from), !anchors.contains(location.path) {
                        anchors.append(location.path)
                    }
                }
                tagged[change.path, default: []].insert(.interface)
                asks.append(StructureAsk(
                    id: "api:gone:" + change.path,
                    kind: .interface,
                    title: "已删除但仍被引用 \(className(change.path))",
                    detail: "还有 \(dangling.count) 处 import 指向它，这些文件会编译失败。",
                    anchors: anchors,
                    evidence: dangling.prefix(5).map {
                        StructureEvidence(file: $0.from, line: $0.line, sign: " ", text: "import \($0.name);")
                    },
                    remedy: "恢复 \(className(change.path))，或同步修改仍在引用它的 \(dangling.count) 处。"
                ))
                continue
            }

            // 只看「原地改」的文件。改名的类，引用方必须跟着改 import，那会体现在依赖变化里。
            guard change.kind == .modified, change.counterpart == nil else { continue }
            let importers = context.headFacts.incoming(to: change.path).filter {
                guard let other = context.location(of: $0.from) else { return false }
                return other.domainID != here.domainID
            }
            guard !importers.isEmpty else { continue }

            let lines = StructureGit.changedLines(
                of: change.path,
                base: context.base,
                includeWorkingTree: context.options.includeWorkingTree,
                root: context.root
            )
            let isInterface = JavaSignature.isInterface(context.baseTexts[change.path] ?? "")
            var evidence = JavaSignature.changes(in: lines, inInterface: isInterface)
            guard !evidence.isEmpty else { continue }
            for offset in evidence.indices { evidence[offset].file = change.path }

            var anchors = [here.path]
            var domains: [String: Int] = [:]
            for reference in importers {
                guard let location = context.location(of: reference.from) else { continue }
                domains[location.domainID, default: 0] += 1
                let anchor = [location.domainID, location.moduleID]
                if !anchors.contains(anchor) { anchors.append(anchor) }
            }
            let titles = domains.keys
                .sorted { (domains[$0] ?? 0) != (domains[$1] ?? 0) ? (domains[$0] ?? 0) > (domains[$1] ?? 0) : $0 < $1 }
                .map { "「\(context.domainTitle($0))」" }
                .joined()
            let synced = importers.filter { context.changedHeadPaths.contains($0.from) }.count
            let status: String
            if synced == 0 {
                status = "本分支都没有同步修改"
            } else if synced == importers.count {
                status = "本分支都已同步修改"
            } else {
                status = "其中 \(synced) 个已同步修改"
            }

            tagged[change.path, default: []].insert(.interface)
            asks.append(StructureAsk(
                id: "api:" + change.path,
                kind: .interface,
                title: "对外接口变化 \(className(change.path))",
                detail: "\(titles)共有 \(importers.count) 个文件引用它，\(status)。",
                anchors: anchors,
                evidence: Array(evidence.prefix(8)),
                remedy: "\(className(change.path)) 的公开签名需要保持向后兼容：保留原有签名，新的行为用新增方法承接。"
            ))
        }
        return asks
    }

    // MARK: 范围

    /// 事先声明了「只动哪几个域」时，范围外的改动合成一条待确认。
    private static func scopeAsks(
        changes: [StructureFileChange],
        context: Context,
        tagged: inout [String: Set<StructureAsk.Kind>]
    ) -> [StructureAsk] {
        let scope = context.options.scope
        guard !scope.isEmpty else { return [] }
        let outside = changes.filter { !scope.contains($0.domainID) }
        guard !outside.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        var anchors: [[String]] = []
        for change in outside {
            counts[change.domainID, default: 0] += 1
            tagged[change.path, default: []].insert(.scope)
            let anchor = [change.domainID, change.moduleID]
            if !anchors.contains(anchor) { anchors.append(anchor) }
        }
        let ordered = counts.keys.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            return left != right ? left > right : lhs < rhs
        }
        let names = ordered.map { context.domainTitle($0) }
        let declared = scope.map { context.domainTitle($0) }.sorted().joined(separator: "、")
        let breakdown = ordered.map { "\(context.domainTitle($0)) \(counts[$0] ?? 0) 个文件" }.joined(separator: "、")

        return [StructureAsk(
            id: "scope",
            kind: .scope,
            title: "越出声明范围：\(names.joined(separator: "、"))",
            detail: "本次声明只动「\(declared)」，范围外还改了 \(breakdown)。",
            anchors: anchors,
            evidence: outside.prefix(5).map {
                StructureEvidence(file: $0.path, line: 0, sign: $0.kind == .deleted ? "-" : "+", text: $0.path)
            },
            remedy: "撤回对\(names.joined(separator: "、"))的改动。本次范围仅限\(declared)。"
        )]
    }
}
