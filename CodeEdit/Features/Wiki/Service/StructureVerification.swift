//
//  StructureVerification.swift
//  CodeEdit
//
//  无界面验证结构地图：模块算得准不准、每一级画出来能不能看。
//
//  两类检查分开做，因为它们失败的方式不同：
//  - 「准不准」是数：每个文件恰好属于一个模块、模块之和等于域、两次扫描结果一致。
//    这些写成断言，任何一条不过就以非零退出，脚本和 CI 都能直接用。
//  - 「能不能看」是图：卡片挤不挤、长包名截断得对不对、三栏里放不放得下。
//    读代码看不出来，只能渲染出来用眼睛判断。
//
//  用法：
//    QIYIDE_VERIFY_STRUCTURE=/path/to/repo \
//    QIYIDE_VERIFY_STRUCTURE_OUT=/tmp/structure \
//    build/QiyideDev.app/Contents/MacOS/QiyideDev
//
//  只读：不写被测仓库。有锁定模型就用锁定的，没有就现场识别一次（结果只留在内存里）。
//  例外：设置 QIYIDE_VERIFY_STRUCTURE_LOCK=1 会把识别结果锁定落盘，用于整窗截图，只应指向仓库副本。
//

#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum StructureVerification {

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["QIYIDE_VERIFY_STRUCTURE"] else { return }
        let root = URL(fileURLWithPath: rootPath)
        let output = URL(fileURLWithPath: environment["QIYIDE_VERIFY_STRUCTURE_OUT"] ?? "/tmp/qiyide-structure")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        log("开始验证 \(rootPath)")
        Task { @MainActor in
            let store = DomainModelStore(root: root)
            if store.graph.isEmpty {
                log("没有锁定模型，现场识别一次")
                await store.analyze()
                // 整窗截图要读磁盘上的锁定模型。只在显式要求时写，并且应当指向仓库的副本。
                if environment["QIYIDE_VERIFY_STRUCTURE_LOCK"] == "1" {
                    store.lock()
                    log("已按要求锁定模型（写入 .qiyide/wiki/domains.locked.json）")
                }
            } else {
                log("使用锁定模型")
            }
            guard !store.graph.isEmpty else {
                log("失败：没有识别出领域模型（\(store.errorMessage ?? "未知原因")）")
                exit(1)
            }

            let started = Date()
            let packages = DomainAnalyzer.scanPackages(root: root)
            let index = StructureIndex.build(packages: packages, graph: store.graph)
            log(String(
                format: "索引：%d 个域 / %d 个模块 / %d 个类，扫描加构建 %.0fms",
                index.modeledDomains.count,
                index.moduleCount,
                index.classCount,
                Date().timeIntervalSince(started) * 1000
            ))

            var failures = checkInvariants(index: index, packages: packages, root: root, graph: store.graph)
            failures += checkModelAgreement(index: index, graph: store.graph, isLocked: store.isLocked)
            printTable(index)
            printFacts(index: index, root: root)

            let options = StructureDiffBuilder.Options(
                target: environment["QIYIDE_VERIFY_STRUCTURE_TARGET"],
                includeWorkingTree: environment["QIYIDE_VERIFY_STRUCTURE_COMMITTED_ONLY"] != "1",
                scope: Set((environment["QIYIDE_VERIFY_STRUCTURE_SCOPE"] ?? "")
                    .split(separator: ",").map(String.init))
            )
            let diff = printDiff(index: index, root: root, options: options)

            await renderLevels(index: index, diff: diff, store: store, root: root, output: output)

            if failures == 0 {
                log("验证结束：全部通过")
                exit(0)
            }
            log("验证结束：\(failures) 项未通过")
            exit(1)
        }
    }

    // MARK: 断言

    /// 全覆盖、守恒、唯一，外加「同一份代码扫两次结果相同」。
    private static func checkInvariants(
        index: StructureIndex,
        packages: [ScannedPackage],
        root: URL,
        graph: MindGraph
    ) -> Int {
        log("—— 不变量 ——")
        var failures = 0

        let problems = index.violations(packages: packages)
        if problems.isEmpty {
            log("全覆盖 / 守恒 / 唯一：通过（\(packages.flatMap(\.files).count) 个文件）")
        } else {
            failures += problems.count
            for problem in problems { log("失败 \(problem)") }
        }

        // 稳定：目录遍历顺序、字典迭代顺序都不保证稳定，结果却必须稳定。
        let again = StructureIndex.build(packages: DomainAnalyzer.scanPackages(root: root), graph: graph)
        if signature(index) == signature(again) {
            log("稳定：通过（两次扫描的域、模块、文件逐项相同）")
        } else {
            failures += 1
            log("失败 稳定：两次扫描结果不同")
        }
        return failures
    }

    /// 领域模型自己记的模块，和按当下文件算出来的模块，应当对得上。
    ///
    /// 对不上有两种情况：模型是旧的（代码之后变了），或者识别本身算错了。
    /// 现场识别时必须完全一致；用锁定模型时只提示，不算失败。
    private static func checkModelAgreement(index: StructureIndex, graph: MindGraph, isLocked: Bool) -> Int {
        log("—— 模型与扫描对账 ——")
        var mismatches: [String] = []
        for domain in graph.domains {
            let modeled = graph.children(of: domain.id).filter { $0.kind == .module }
            let modeledSum = modeled.reduce(0) { $0 + $1.classCount }
            if modeledSum != domain.classCount {
                mismatches.append("\(domain.displayTitle)：域 \(domain.classCount) 类，模块之和 \(modeledSum)")
            }
            for node in modeled {
                let scanned = index.module(node.id)?.classCount ?? 0
                if scanned != node.classCount {
                    let name = "\(domain.displayTitle) › \(node.displayTitle)"
                    mismatches.append("\(name)：模型 \(node.classCount)，扫描 \(scanned)")
                }
            }
        }
        let outside = index.domains.flatMap(\.modules).filter { !$0.isModeled && !$0.isRoot }
        let unassigned = index.domain(StructureAssigner.unassignedDomainID)?.modules.count ?? 0
        if outside.count > unassigned {
            mismatches.append("有 \(outside.count - unassigned) 个模块不在模型里（识别之后新加的包）")
        }

        guard !mismatches.isEmpty else {
            log("模型里每个域的类数都等于模块之和，且与扫描一致：通过")
            return 0
        }
        for line in mismatches.prefix(12) { log("不一致 \(line)") }
        if mismatches.count > 12 { log("……共 \(mismatches.count) 处") }
        // 锁定模型是过去某一刻的快照，代码之后变了是正常的：只提示。
        return isLocked ? 0 : mismatches.count
    }

    private static func signature(_ index: StructureIndex) -> [String] {
        index.domains.flatMap { domain in
            domain.modules.map { module in
                "\(domain.id)|\(module.id)|\(module.files.map(\.path).joined(separator: ","))"
            }
        }
    }

    private static func printTable(_ index: StructureIndex) {
        log("—— 域与模块 ——")
        for domain in index.domains {
            let tag = domain.kind.tag.map { "（\($0)）" } ?? ""
            log("[\(domain.title)]\(tag) \(domain.modules.count) 个模块 / \(domain.classCount) 类")
            let line = domain.modules
                .map { "\($0.title) \($0.classCount)" }
                .joined(separator: "，")
            log("   \(line)")
        }
    }

    // MARK: 依赖事实

    /// 依赖图的精度：有多少 import 指向仓库自己的包却对不到文件。
    ///
    /// 这个比例是「依赖变化」能不能信的前提。它高了，后面报出来的新增依赖就可能是假的。
    private static func printFacts(index: StructureIndex, root: URL) {
        log("—— 依赖事实 ——")
        let started = Date()
        let paths = index.domains.flatMap { $0.modules.flatMap { $0.files.map(\.path) } }
        let facts = StructureFacts.scan(root: root, paths: paths)
        let total = facts.references.count + facts.dangling.count
        log(String(
            format: "扫描 %d 个文件 %.0fms：仓库内引用 %d 条，未解析 %d 条（%.1f%%）",
            facts.scannedFiles,
            Date().timeIntervalSince(started) * 1000,
            facts.references.count,
            facts.dangling.count,
            total == 0 ? 0 : Double(facts.dangling.count) * 100 / Double(total)
        ))
        for item in facts.dangling.prefix(5) {
            log("   未解析 \(item.name)  ← \((item.from as NSString).lastPathComponent):\(item.line)")
        }

        // 域到域的引用数：全仓那一级画的就是它。
        var pairs: [String: Int] = [:]
        for reference in facts.references {
            guard let from = index.moduleID(forFile: reference.from).flatMap({ index.domain(ofModule: $0) }),
                  let to = index.moduleID(forFile: reference.to).flatMap({ index.domain(ofModule: $0) }),
                  from.id != to.id else { continue }
            pairs["\(from.title) → \(to.title)", default: 0] += 1
        }
        for (pair, count) in pairs.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            log("   \(pair)  \(count)")
        }
    }

    // MARK: 分支 diff

    @discardableResult
    private static func printDiff(
        index: StructureIndex,
        root: URL,
        options: StructureDiffBuilder.Options
    ) -> StructureDiff? {
        log("—— 分支 diff ——")
        let started = Date()
        switch StructureDiffBuilder.build(root: root, index: index, options: options) {
        case .failure(let failure):
            log("跳过：\(failure.message)")
            return nil
        case .success(let diff):
            log(String(
                format: "%@ → %@（分叉点 %@，%d 个提交%@），计算 %.0fms",
                diff.headName,
                diff.targetName,
                diff.baseCommit,
                diff.commitCount,
                diff.includesWorkingTree ? "，含未提交" : "",
                Date().timeIntervalSince(started) * 1000
            ))
            log("   耗时：" + diff.timings
                .map { String(format: "%@ %.0fms", $0.stage, $0.milliseconds) }
                .joined(separator: " · "))
            log("文件 \(diff.fileCount) 个：源码 \(diff.changes.count)，测试 \(diff.testFiles)，"
                + "文档 \(diff.documentFiles)，其他 \(diff.otherFiles)；模块内实现 \(diff.innerChanges.count)")
            for domain in index.domains where !diff.marks(domain: domain.id).isEmpty {
                let marks = diff.marks(domain: domain.id)
                let modules = domain.modules
                    .filter { !diff.marks(module: $0.id).isEmpty }
                    .map { module -> String in
                        let mark = diff.marks(module: module.id)
                        let fresh = diff.newModules.contains(module.id) ? "（新）" : ""
                        return "\(module.title)\(fresh) +\(mark.added) ~\(mark.modified) −\(mark.deleted)"
                    }
                let gone = diff.removedModules(domain: domain.id).map { "\($0.title)（已删光）" }
                log("   [\(domain.title)] +\(marks.added) ~\(marks.modified) −\(marks.deleted)："
                    + (modules + gone).joined(separator: "，"))
            }
            for edge in diff.edges {
                let sign = edge.kind == .added ? "+" : "−"
                let cross = edge.crossesDomains ? (edge.changesDomainPair ? "跨域·新的域对" : "跨域") : "域内"
                log("   依赖 \(sign) \(edge.fromModule) → \(edge.toModule)（\(cross)，\(edge.references.count) 处）")
            }
            log("待确认 \(diff.asks.count) 条")
            for ask in diff.asks {
                log("   [\(ask.kind.title)] \(ask.title)")
                log("       \(ask.detail)")
                for line in ask.evidence.prefix(4) {
                    let place = line.line > 0 ? "\((line.file as NSString).lastPathComponent):\(line.line)" : ""
                    log("       \(line.sign) \(line.text)  \(place)")
                }
            }
            return diff
        }
    }

    // MARK: 渲染

    /// 每一级各渲染一张；有分支增量时，再把叠加后的几种状态各渲染一张。
    ///
    /// 宽度取 620：三栏窗口里中间栏的常见宽度，在这个宽度下不挤才算过。
    @MainActor
    private static func renderLevels(
        index: StructureIndex,
        diff: StructureDiff?,
        store: DomainModelStore,
        root: URL,
        output: URL
    ) async {
        log("—— 截图 ——")
        struct Shot {
            var name: String
            var path: [String]
            var diff: StructureDiff?
            var decisions: [String: StructureDecision] = [:]
            var height: CGFloat = 720
        }
        var shots = [Shot(name: "1-overview", path: [])]
        if let largest = index.modeledDomains.first {
            shots.append(Shot(name: "2-domain", path: [largest.id]))
            // 选一个带子包的模块，再往下走一层：子包方块和文件清单都要看得到。
            let module = largest.modules.first { !index.contents(of: $0, at: []).packages.isEmpty }
                ?? largest.modules.first
            if let module {
                shots.append(Shot(name: "3-module", path: [largest.id, module.id]))
                if let package = index.contents(of: module, at: []).packages.first {
                    shots.append(Shot(name: "4-package", path: [largest.id, module.id] + package.subpath))
                }
            }
        }

        if let diff, !diff.changes.isEmpty {
            shots.append(Shot(name: "6-diff-overview", path: [], diff: diff, height: 1500))
            // 待确认最多的域，以及它里面改动最多的模块：标记、徽标、文件标签都集中在这两张上。
            let busiest = index.domains.max {
                diff.asks(inside: [$0.id]).count < diff.asks(inside: [$1.id]).count
            }
            if let busiest {
                shots.append(Shot(name: "7-diff-domain", path: [busiest.id], diff: diff, height: 1300))
                let module = busiest.modules.max {
                    diff.marks(module: $0.id).total < diff.marks(module: $1.id).total
                }
                if let module {
                    let contents = index.contents(of: module, at: [])
                    let deeper = contents.packages.first {
                        !diff.marks(module: module.id, under: $0.subpath).isEmpty
                    }
                    shots.append(Shot(
                        name: "8-diff-module",
                        path: [busiest.id, module.id] + (contents.files.isEmpty ? deeper?.subpath ?? [] : []),
                        diff: diff,
                        height: 1100
                    ))
                }
            }
            // 做过几个决定之后的样子：已决定的收成一行，违规的生成修改要求。
            var decisions: [String: StructureDecision] = [:]
            for (offset, ask) in diff.asks.enumerated() where ask.adoption == nil {
                if offset % 2 == 0 { decisions[ask.id] = .accepted } else { decisions[ask.id] = .violation }
            }
            shots.append(Shot(name: "9-diff-decided", path: [], diff: diff, decisions: decisions, height: 1300))
        }

        for shot in shots {
            let view = StructureMapView(
                store: store,
                root: root,
                selectedDomain: .constant(nil),
                onOpenFile: { _ in },
                preloaded: index,
                preloadedDiff: shot.diff,
                preloadedDecisions: shot.decisions,
                initialPath: shot.path
            )
            .background(Color(nsColor: .textBackgroundColor))
            await snapshot(
                view,
                size: NSSize(width: 620, height: shot.height),
                to: output.appending(path: "\(shot.name).png")
            )
        }

        // 整窗：检查「结构」页签放进三栏之后的比例。它自己加载数据，所以多等一会儿。
        let window = WikiWindowView(
            root: root,
            workspace: nil,
            autoLoad: true,
            initiallySelectedDomain: nil,
            initialCenterMode: .structure
        )
        await snapshot(
            window,
            size: NSSize(width: 1280, height: 820),
            to: output.appending(path: "5-window.png"),
            settle: 4_000_000_000
        )
    }

    /// 挂到屏幕外的真实窗口上再截图。
    ///
    /// 不用 `ImageRenderer`：它画不了 `Button`、`Picker` 这类原生控件，会整块替换成占位符。
    @MainActor
    static func snapshot<Content: View>(
        _ view: Content,
        size: NSSize,
        to url: URL,
        settle: UInt64 = 1_200_000_000
    ) async {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = OffscreenWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI 首次布局与异步加载都要等几轮 runloop，太快截图会得到空白。
        try? await Task.sleep(nanoseconds: settle)

        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            log("无法创建位图：\(url.lastPathComponent)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            log("PNG 编码失败：\(url.lastPathComponent)")
            return
        }
        do {
            try png.write(to: url)
            log("已渲染：\(url.path)")
        } catch {
            log("写盘失败：\(error.localizedDescription)")
        }
    }

    private static func log(_ text: String) {
        print("[verify][structure] \(text)")
        fflush(stdout)
    }
}

/// 只用来截图的窗口：不当键盘焦点窗口。
///
/// 普通窗口即使放在屏幕外，也可能成为应用的 key window。那样人这时候敲的键
/// 会落到它上面——实测截图里的页签被方向键切走过，人那边的输入也丢了。
private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
#endif
