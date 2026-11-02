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
