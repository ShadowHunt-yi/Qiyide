//
//  StructureVerdict.swift
//  CodeEdit
//
//  顶部的那一句结论。
//
//  结构地图先给结论、再给图：多数 AI 写出来的分支只改了模块内部，
//  这时一句「没有改变结构」就够了，图都不用看。只有结论说「有 N 处等你确认」时，
//  人才需要往下看——而且往下看的就是那 N 条，不是全部改动。
//
//  这里是纯函数：同样的 diff、同样的位置、同样的已决定集合，得到同样的话。
//

import Foundation

struct StructureVerdict: Hashable, Sendable {
    /// 一句话结论。
    var headline: String
    /// 补充的几个数，用间隔号连起来显示。
    var facts: [String] = []
    /// 这个范围内还没决定的待确认数。
    var openCount = 0

    /// - Parameters:
    ///   - path: 当前位置 `[域, 模块, 子包…]`，空数组是全仓。
    ///   - decided: 已经做过决定的待确认标识。
    static func make(
        diff: StructureDiff,
        index: StructureIndex,
        path: [String],
        decided: Set<String> = []
    ) -> StructureVerdict {
        let asks = diff.asks(inside: path)
        let open = asks.filter { !decided.contains($0.id) }.count
        let tail = asks.isEmpty ? "没有需要你确认的" : open == 0 ? "\(asks.count) 处都已确认" : "\(open) 处等你确认"

        guard let domainID = path.first else {
            return overall(diff: diff, index: index, asks: asks, open: open)
        }
        guard path.count > 1 else {
            let title = index.domain(domainID)?.title ?? domainID
            let touched = diff.touchedModules.filter { index.domain(ofModule: $0)?.id == domainID }.count
                + diff.removedModules(domain: domainID).count
            let what = touched == 0 ? "本分支没有改动" : "改动 \(touched) 个模块"
            return StructureVerdict(headline: "\(title)：\(what)，\(tail)。", openCount: open)
        }
        let subpath = Array(path.dropFirst(2))
        let title = subpath.last ?? index.module(path[1])?.title ?? path[1]
        let count = diff.marks(module: path[1], under: subpath).total
        let what = count == 0 ? "本分支没有改动" : "改动 \(count) 个文件"
        return StructureVerdict(headline: "\(title)：\(what)，\(tail)。", openCount: open)
    }

    private static func overall(
        diff: StructureDiff,
        index: StructureIndex,
        asks: [StructureAsk],
        open: Int
    ) -> StructureVerdict {
        var extras: [String] = []
        if diff.testFiles > 0 { extras.append("测试 \(diff.testFiles) 个") }
        if diff.documentFiles > 0 { extras.append("文档 \(diff.documentFiles) 个") }
        if diff.otherFiles > 0 { extras.append("其他文件 \(diff.otherFiles) 个") }
        let counted = extras.isEmpty ? nil : "另有\(extras.joined(separator: "、"))只计数"
        let declared = diff.scope.isEmpty ? nil : "声明范围：" + diff.scope
            .map { index.domain($0)?.title ?? $0 }.sorted().joined(separator: "、")

        guard !asks.isEmpty else {
            if diff.changes.isEmpty {
                let headline = diff.fileCount == 0
                    ? "相对 \(diff.targetName) 没有改动。"
                    : "这个分支没有改动源码结构。"
                return StructureVerdict(headline: headline, facts: [counted, declared].compactMap { $0 })
            }
            return StructureVerdict(
                headline: "这个分支没有改变结构。",
                facts: ["\(diff.changes.count) 个源码文件都是模块内实现", counted, declared].compactMap { $0 }
            )
        }

        let domains = index.domains.count
        var facts = ["动了 \(diff.touchedDomains.count)/\(domains) 个域、\(diff.touchedModules.count) 个模块"]
        let crossing = diff.edges.filter(\.crossesDomains)
        let added = crossing.filter { $0.kind == .added }.count
        let removed = crossing.count - added
        if added > 0 { facts.append("新增 \(added) 条跨域依赖") }
        if removed > 0 { facts.append("消失 \(removed) 条跨域依赖") }
        let interfaces = asks.filter { $0.kind == .interface }.count
        if interfaces > 0 { facts.append("\(interfaces) 处接口变化") }
        let fresh = asks.filter { $0.id.hasPrefix("map:new:") }.count
        if fresh > 0 { facts.append("\(fresh) 个新包待归属") }
        let moves = asks.filter { $0.id.hasPrefix("map:move:") }.count
        if moves > 0 { facts.append("\(moves) 处跨域移动") }
        if asks.contains(where: { $0.kind == .scope }) { facts.append("有改动越出声明范围") }
        if let counted { facts.append(counted) }
        if let declared { facts.append(declared) }

        let headline: String
        if open == 0 {
            headline = "\(asks.count) 处已全部确认，这个分支审完了。"
        } else if open == asks.count {
            headline = "这个分支改了结构，\(open) 处等你确认。"
        } else {
            headline = "还剩 \(open) 处等你确认。"
        }
        return StructureVerdict(headline: headline, facts: facts, openCount: open)
    }
}
