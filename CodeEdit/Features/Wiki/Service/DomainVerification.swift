//
//  DomainVerification.swift
//  CodeEdit
//
//  无界面验证领域建模链路。
//
//  为什么要单独做一个入口：
//  这条链路依赖 `NSHostingView` 的视图生命周期来触发，而无头启动（命令行传仓库路径）
//  时 SwiftUI 的 `onAppear` / `task` 都不执行，导致「点按钮 → 出结果」这条路
//  没法自动验证。这个入口绕开界面，直接调分析器 / 投影器 / 模板，
//  跑的是同一套业务代码，能验证到 99% 的逻辑。
//
//  用法：
//    QIYIDE_VERIFY_DOMAIN=/path/to/repo build/QiyideDev.app/Contents/MacOS/QiyideDev
//
//  只读：不写 .qiyide/wiki，不修改被测仓库。
//

#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum DomainVerification {

    static func runIfRequested() {
        guard let rootPath = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_DOMAIN"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath)
        log("开始验证 \(rootPath)")

        Task {
            let started = Date()
            let result = await DomainAnalyzer.analyze(root: root) { _ in }
            log(String(
                format: "识别完成：%d 个候选包 / %d 个类 / 耗时 %.1fs",
                result.packageCount,
                result.classCount,
                Date().timeIntervalSince(started)
            ))

            for warning in result.warnings {
                log("警告：\(warning)")
            }

            log("—— 领域列表（\(result.graph.domains.count) 个）——")
            for domain in result.graph.domains {
                log("[\(domain.displayTitle)] \(domain.classCount) 类，包 \(domain.packages.joined(separator: ","))")
                log("   负责人：\(domain.owner.primary.isEmpty ? "（无）" : domain.owner.primary)")
                for item in domain.evidence.prefix(5) {
                    log("   依据·\(item.kind.title)：\(item.detail)")
                }
                let children = result.graph.children(of: domain.id)
                if !children.isEmpty {
                    let sample = children.prefix(6)
                        .map { "\($0.displayTitle)(\($0.classCount))" }
                        .joined(separator: ", ")
                    log("   模块：\(sample)")
                }
            }

            log("—— 视角投影 ——")
            for spec in ViewSpec.presets {
                let projected = ViewProjector.project(result.graph, spec: spec)
                let top = projected.children(of: projected.rootID).map(\.displayTitle)
                log("\(spec.name)：\(projected.nodes.count) 节点，顶层 [\(top.joined(separator: ", "))]")
            }

            // 布局自检：卡片重叠是「看不清」的直接来源，必须为 0。
            log("—— 布局自检（画布 980×680，全部展开）——")
            var cases: [(String, MindGraph)] = [("建模视图", result.graph)]
            cases += ViewSpec.presets.map { ($0.name, ViewProjector.project(result.graph, spec: $0)) }
            for (name, graph) in cases {
                let expanded = Set(graph.nodes.filter { $0.kind == .domain }.map(\.id))
                let layout = MindMapLayout.compute(
                    graph: graph,
                    size: CGSize(width: 980, height: 680),
                    expanded: expanded
                )
                var overlaps = 0
                let rects = layout.placements.map(\.rect)
                for i in rects.indices {
                    for j in rects.indices where j > i {
                        if rects[i].intersects(rects[j]) { overlaps += 1 }
                    }
                }
                let summaries = layout.placements.filter(\.isSummary)
                let summaryText = summaries.isEmpty
                    ? "无"
                    : summaries.map { "\($0.node.parentID ?? "?")+\($0.hiddenCount)" }.joined(separator: ", ")
                log(String(
                    format: "%@：%d 卡片，重叠 %d 对，内容 %.0f×%.0f，汇总卡[%@]",
                    name,
                    layout.placements.count,
                    overlaps,
                    layout.contentBounds.width,
                    layout.contentBounds.height,
                    summaryText
                ))
            }

            log("—— 知识条目预览（不写盘）——")
            for domain in result.graph.domains.prefix(2) {
                let body = WikiDomainSeeding.body(for: domain, in: result.graph)
                log("《\(domain.displayTitle)》正文前 16 行：")
                for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(16) {
                    log("  | \(line)")
                }
            }

            await MainActor.run {
                checkDomainTagging(root: root, graph: result.graph)
            }

            // 离屏渲染导图，用于人工检查排版（字体、留白、连线、图例）。
            if let path = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_SNAPSHOT"] {
                await MainActor.run {
                    snapshot(graph: result.graph, root: root, to: path, expanded: false,
                             size: CGSize(width: 980, height: 680))
                    // 再来一张全展开的：模块卡片、汇总卡、放大后的字号都在这一张上看。
                    snapshot(graph: result.graph, root: root,
                             to: path.replacingOccurrences(of: ".png", with: "-expanded.png"),
                             expanded: true, size: CGSize(width: 1100, height: 1500))
                }
            }

            log("验证结束")
            exit(0)
        }
    }

    /// 打标自检：frontmatter 往返 + 真实仓库上的回填分布。
    ///
    /// 只读：报告算出来只打印，不写盘。
    @MainActor
    private static func checkDomainTagging(root: URL, graph: MindGraph) {
        log("—— 打标自检 ——")

        // 1) 写进去的域必须能原样读回来。
        let entry = WikiEntry(
            id: "selfcheck",
            title: "自检条目",
            type: .module,
            tags: [],
            sources: ["a/b/c.java"],
            domains: ["domain:a/b", "domain:c"],
            relations: [],
            body: "正文",
            updatedAt: Date(),
            fileURL: URL(fileURLWithPath: "/tmp/selfcheck.md")
        )
        let round = WikiEntry.parse(text: entry.markdown(), fileURL: entry.fileURL)
        if round.domains == entry.domains {
            log("打标往返：通过（\(round.domains.joined(separator: ", "))）")
        } else {
            log("打标往返：失败 期望 \(entry.domains) 实际 \(round.domains)")
        }

        // 2) 真实知识库上的归属分布。
        let store = WikiStore(root: root)
        store.reload()
        guard !store.entries.isEmpty else {
            log("回填报告：知识库为空（\(root.appending(path: ".qiyide/wiki").path)）")
            return
        }
        let report = WikiDomainBackfill.report(graph: graph, store: store)
        log("回填报告：\(report.summary)")
        for item in report.gaps.prefix(8) {
            log("  空缺域 \(item.domainTitle)（\(item.classCount) 类）")
        }
        for item in report.suggestions.prefix(8) {
            log("  建议 \(item.entryTitle) → \(item.domainTitle)  依据 \(item.via)")
        }
        for item in report.ambiguous.prefix(5) {
            log("  多义 \(item.entryTitle) ~ \(item.domainTitle)  依据 \(item.via)")
        }
        for item in report.orphans.prefix(5) {
            log("  无归属 \(item.entryTitle)（\(item.sourceCount) 条关联代码）")
        }

        // 3) 写入路径自检：只在显式要求时跑，因为它会改文件。
        guard ProcessInfo.processInfo.environment["QIYIDE_VERIFY_BACKFILL_APPLY"] == "1" else {
            return
        }
        do {
            let count = try WikiDomainBackfill.apply(report, store: store)
            log("补写完成：\(count) 条")
            let after = WikiDomainBackfill.report(graph: graph, store: store)
            log("补写后：\(after.summary)")
            for entry in store.entries where !entry.domains.isEmpty {
                log("  已标 \(entry.displayTitle) → \(entry.domains.joined(separator: ", "))")
            }
            for domain in graph.domains {
                let tagged = store.entries(inDomain: domain.id).count
                log("  域索引 \(domain.displayTitle)：\(tagged) 条")
            }
        } catch {
            log("补写失败：\(error.localizedDescription)")
        }
    }

    /// 把导图渲染成 PNG。
    ///
    /// 界面链路在无头启动下没法自动点，但「画出来长什么样」可以直接渲染验证：
    /// 排版问题（字太小、卡片挤、连线穿卡片）看图一眼就知道，比读代码可靠。
    @MainActor
    private static func snapshot(graph: MindGraph, root: URL, to path: String, expanded: Bool, size: CGSize) {
        let store = DomainModelStore(root: root)
        let openIDs: Set<String> = expanded
            ? Set(graph.nodes.filter { $0.kind == .domain }.map(\.id))
            : []
        let content = MindMapView(
            store: store,
            selection: .constant(nil),
            displayGraph: graph,
            isReadOnly: true,
            graphToken: "verify-\(expanded)",
            initiallyExpanded: openIDs
        )
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .textBackgroundColor))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            log("渲染失败：\(path)")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("导图已渲染：\(path)")
        } catch {
            log("渲染写盘失败：\(error.localizedDescription)")
        }
    }

    private static func log(_ text: String) {
        print("[verify][domain] \(text)")
        fflush(stdout)
    }
}
#endif
