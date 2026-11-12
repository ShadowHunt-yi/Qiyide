//
//  WikiWindowVerification.swift
//  CodeEdit
//
//  把整个知识库窗口离屏渲染成 PNG。
//
//  为什么需要：合并之后「一个页面里放三个模块」是否真的好用，只能看图判断——
//  左栏域列表会不会太长、导图在 600pt 宽里还看不看得清、右栏空态是不是占了太多地方。
//  这些都是排版问题，读代码看不出来。
//
//  用法：
//    QIYIDE_VERIFY_WIKI=/path/to/repo build/QiyideDev.app/Contents/MacOS/QiyideDev
//  产物：/tmp/wiki-window.png
//

#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum WikiWindowVerification {

    static func runIfRequested() {
        guard let rootPath = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_WIKI"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath)
        let output = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_WIKI_OUT"]
            ?? "/tmp/wiki-window.png"

        print("[verify][wiki] 开始渲染 \(rootPath)")
        Task { @MainActor in
            render(root: root, to: output)
        }
    }

    /// 用真实的 `NSHostingView` 渲染，而不是 `ImageRenderer`。
    ///
    /// `ImageRenderer` 画不了带原生控件的界面：`Button`、`Picker`、`HSplitView`
    /// 会被整块替换成「禁止」占位符（实测整窗变成一个巨大的红色斜杠）。
    /// 挂到真实窗口上再 `cacheDisplay` 走的是 AppKit 的绘制路径，控件正常。
    ///
    /// 窗口放在屏幕外，避免验证时在用户眼前闪一下。
    @MainActor
    private static func render(root: URL, to path: String) {
        let size = NSSize(width: 1280, height: 760)
        // 先建一个 store 只为取「第一个域」：渲染时默认选中它，
        // 这样截出来的是「域详情」而不是空态——合并后最主要的新模块就是它。
        let model = DomainModelStore(root: root)
        let firstDomain = model.graph.domains.first?.id

        // 顺手打一份体检结果 + 关键路径耗时：
        // 渲染出来是给人看排版的，数字给的是「逻辑对不对、快不快」。
        var clock = Date()
        let store = WikiStore(root: root)
        store.reloadNow()
        let reloadMS = Date().timeIntervalSince(clock) * 1000

        clock = Date()
        let report = WikiCoherence.check(root: root, graph: model.graph, store: store)
        let coherenceMS = Date().timeIntervalSince(clock) * 1000

        clock = Date()
        for spec in ViewSpec.presets {
            _ = ViewProjector.project(model.graph, spec: spec)
        }
        let projectionMS = Date().timeIntervalSince(clock) * 1000 / Double(ViewSpec.presets.count)

        clock = Date()
        let expanded = Set(model.graph.domains.map(\.id))
        let layout = MindMapLayout.compute(
            graph: model.graph,
            size: CGSize(width: 520, height: 640),
            expanded: expanded
        )
        let layoutMS = Date().timeIntervalSince(clock) * 1000

        clock = Date()
        let backfill = WikiDomainBackfill.report(graph: model.graph, store: store)
        let backfillMS = Date().timeIntervalSince(clock) * 1000

        print(String(
            format: "[verify][wiki] 性能：reload %.1fms · 体检 %.1fms · 投影 %.2fms/视角 · 布局 %.1fms(%d 卡片) · 归属 %.1fms",
            reloadMS, coherenceMS, projectionMS, layoutMS, layout.placements.count, backfillMS
        ))
        print("[verify][wiki] 规模：\(store.entries.count) 条知识 / \(model.graph.domains.count) 个域 / "
              + "归属建议 \(backfill.suggestions.count)")

        // 单条保存走的是增量路径。要测它就得写文件，所以只在显式要求时跑，
        // 并且应当指向一个副本目录，别指向真实仓库。
        if ProcessInfo.processInfo.environment["QIYIDE_VERIFY_WIKI_WRITE"] == "1",
           let sample = store.entries.first {
            let start = Date()
            try? store.save(sample)
            print(String(
                format: "[verify][wiki] 单条保存 %.1fms（增量，不重读磁盘）",
                Date().timeIntervalSince(start) * 1000
            ))
            // 增量更新的正确性判据：写完之后，内存里的状态必须和「重扫磁盘」完全一致。
            // 旧实现每次保存都 reload，天然一致；改成增量之后这条不变量要显式守住。
            checkConsistency(store, label: "保存")

            // 确认草稿走的是「结构没变」的那条路：只翻节点标记，不重建邻接表。
            // 这是新增的分支，必须单独验一次。
            if let draft = store.drafts.first {
                let confirmed = store.confirm(ids: [draft.id])
                print("[verify][wiki] 批量确认：\(confirmed) 条")
                checkConsistency(store, label: "确认草稿")
            }

            // 改类型同样走「结构没变」的分支，但图上节点的颜色取决于 type，
            // 刷新时漏掉它就会「类型改了、图还是旧色」。
            if var entry = store.entries.first {
                let original = entry.type
                entry.type = original == .decision ? .topic : .decision
                try? store.save(entry)
                let synced = store.graph.node(entry.id)?.type == entry.type
                print("[verify][wiki] 类型同步：\(synced ? "通过" : "失败（图上仍是 \(String(describing: store.graph.node(entry.id)?.type))）")")
                entry.type = original
                try? store.save(entry)
            }

            // 检索索引按 id 增量维护，最容易出的错是「漏了某条」——
            // 拿每条自己的标题去搜，必须能搜回自己。
            let missing = store.entries.filter { entry in
                let probe = String(entry.title.prefix(8))
                return !store.search(probe).contains { $0.id == entry.id }
            }
            print("[verify][wiki] 检索自检：\(missing.isEmpty ? "通过（\(store.entries.count) 条）" : "失败 \(missing.count) 条")")
            for entry in missing.prefix(3) {
                print("[verify][wiki]   搜不到：\(entry.title.prefix(40))")
            }

            // 建档带域：applyDraft 收到 domainID 时必须写进 frontmatter，
            // 否则「条目一落盘就挂在域上」只是一句注释。走一遍真实落盘再读回来。
            let probeDraft = WikiDraft(
                action: .create,
                target: "",
                title: "归属自检临时条目",
                type: .module,
                tags: ["自检"],
                relations: [],
                body: "验证 applyDraft 的 domainID 真的落盘。",
                reason: "",
                sources: ["自检/不存在的路径.java"]
            )
            let probeDomain = "domain:leftover:agent"
            if let created = try? store.applyDraft(
                probeDraft,
                generatedBy: "verify",
                sources: ["自检/不存在的路径.java"],
                domainID: probeDomain,
                refresh: false
            ) {
                let onDisk = try? String(contentsOf: created.fileURL, encoding: .utf8)
                let wrote = onDisk?.contains("domains: \(probeDomain)") == true
                let inMemory = created.domains == [probeDomain]
                print("[verify][wiki] 建档带域：\(wrote && inMemory ? "通过" : "失败（磁盘 \(wrote) 内存 \(inMemory)）")")
                try? FileManager.default.removeItem(at: created.fileURL)
                store.reloadNow()
            }

            // 震荡自检：同一模块分两轮写，sources 必须累加。
            //
            // 建档按轮处理，第二轮只带「本轮待处理的文件」。如果这里用覆盖，
            // 第一轮的文件会从条目里被摘掉 → 下一轮又变回待处理 → 无限重写。
            var round1 = WikiDraft(
                action: .create,
                target: "",
                title: "震荡自检临时条目",
                type: .module,
                tags: ["自检"],
                relations: [],
                body: "第一轮：A + B",
                reason: "",
                sources: [],
                mergeMode: .replace
            )
            _ = try? store.applyDraft(
                round1, generatedBy: "verify", sources: ["A.java", "B.java"], refresh: false
            )
            store.reloadNow()
            round1.action = .update
            round1.target = "震荡自检临时条目"
            round1.body = "第二轮：只有 B 待处理"
            let merged = try? store.applyDraft(
                round1, generatedBy: "verify", sources: ["B.java", "C.java"], refresh: false
            )
            let expected = ["A.java", "B.java", "C.java"]
            print("[verify][wiki] 增量合并：\(merged?.sources == expected ? "通过（A+B+C）" : "失败（\(merged?.sources ?? [])）")")
            if let merged {
                try? FileManager.default.removeItem(at: merged.fileURL)
                store.reloadNow()
            }
        }

        // 建档归属自检：如果现在跑一次「整个仓库建档」，每个模块能不能拿到域？
        // 拿真实代码文件跑一遍路径判定，看覆盖率与落到哪些域——
        // 规则错了这里会立刻显形（比如 suggest 的文件全落到 AI搭子）。
        if !model.graph.domains.isEmpty {
            var counts: [String: Int] = [:]
            var unmatched = 0
            var scanned = 0
            if let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    guard scanned < 5000 else { break }
                    guard url.pathExtension == "java" else { continue }
                    guard !url.path.contains("/target/"), !url.path.contains("/test/") else { continue }
                    scanned += 1
                    let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    if let hit = WikiDomainBackfill.domain(forSources: [relative], graph: model.graph) {
                        counts[hit.domainTitle, default: 0] += 1
                    } else {
                        unmatched += 1
                    }
                }
            }
            print("[verify][wiki] 建档归属自检：扫 \(scanned) 个 java，匹配 \(scanned - unmatched)，未匹配 \(unmatched)")
            for (title, count) in counts.sorted(by: { $0.value > $1.value }) {
                print("[verify][wiki]   \(title)：\(count)")
            }
        }

        // 建档面板的统计口径：缓存 + 条目双条件。
        // 只看缓存时，条目被删/归档后这些文件仍算「已建档」，面板会显示
        // 「已建档 N、待处理 M」而库里一条对应条目都没有。
        do {
            let inventory = WikiRepoIngest.inventory(
                root: root, insights: WikiInsightStore.load(root: root),
                model: AINarrativeStore.shared.providerLabel,
                curatedPaths: Set(store.entries.flatMap(\.sources))
            )
            let total = inventory.total
            let fresh = inventory.fresh
            print("[verify][wiki] 建档面板：全仓 \(total) · 已建档 \(fresh) · 待处理 \(max(total - fresh, 0))")
            print("[verify][wiki]   缓存口径（旧）：\(WikiRepoIngest.inventory(root: root, insights: WikiInsightStore.load(root: root), model: AINarrativeStore.shared.providerLabel).fresh) 个会被误判为已建档")
        }

        let summary = report.groups.map { "\($0.kind.title) \($0.issues.count)" }
            .joined(separator: " · ")
        print("[verify][wiki] 体检：\(report.isEmpty ? "无问题" : summary)")
        for group in report.groups {
            for issue in group.issues.prefix(3) {
                print("[verify][wiki]   \(group.kind.title)：\(issue.headline) — \(issue.detail)")
            }
        }

        let hosting = NSHostingView(rootView: WikiWindowView(
            root: root,
            workspace: nil,
            autoLoad: true,
            initiallySelectedDomain: firstDomain
        ))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI 首次布局要等一轮 runloop，太快截图会得到空白。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("[verify][wiki] 无法创建位图")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("[verify][wiki] PNG 编码失败")
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("[verify][wiki] 已渲染：\(path)")
            } catch {
                print("[verify][wiki] 写盘失败：\(error.localizedDescription)")
            }
            window.orderOut(nil)
            exit(0)
        }
    }

    /// 对照检查：增量更新后的内存状态 vs 重扫磁盘后的状态。
    ///
    /// 不一致就说明「内存里有一份磁盘上没有的东西」——这类漂移在增量路径里
    /// 不会自己暴露，只会在某次重启后表现为「我明明改过」。
    @MainActor
    private static func checkConsistency(_ store: WikiStore, label: String) {
        let incremental = snapshot(store)
        let incrementalEdges = store.graph.edges.count
        store.reloadNow()
        let reloaded = snapshot(store)
        let reloadedEdges = store.graph.edges.count
        guard incremental != reloaded || incrementalEdges != reloadedEdges else {
            print("[verify][wiki] \(label) 增量/全量一致性：通过（\(reloaded.count) 条 · \(reloadedEdges) 边）")
            return
        }
        print("[verify][wiki] \(label) 增量/全量一致性：失败（边 \(incrementalEdges) vs \(reloadedEdges)）")
        for item in Set(incremental).subtracting(reloaded).prefix(5) {
            print("[verify][wiki]   仅增量：\(item)")
        }
        for item in Set(reloaded).subtracting(incremental).prefix(5) {
            print("[verify][wiki]   仅全量：\(item)")
        }
    }

    /// 「增量 vs 全量」对照用的规范化快照。
    ///
    /// 刻意不含 `updatedAt`：ISO8601 序列化只到秒，内存里是完整精度，
    /// 拿时间戳比对必然不等，会淹没真正的问题。
    @MainActor
    private static func snapshot(_ store: WikiStore) -> [String] {
        store.entries.map { entry in
            [
                entry.id,
                entry.title,
                entry.type.rawValue,
                entry.status.rawValue,
                entry.domains.joined(separator: ","),
                entry.tags.joined(separator: ","),
                entry.sources.joined(separator: ","),
                entry.relations.map { "\($0.kind):\($0.target)" }.joined(separator: ";"),
                String(entry.body.count)
            ].joined(separator: "|")
        }
    }
}
#endif
