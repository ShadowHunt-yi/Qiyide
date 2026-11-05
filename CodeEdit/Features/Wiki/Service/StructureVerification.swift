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
            failures += checkModelAgreement(index: index, graph: store.graph)
            printTable(index)

            await renderLevels(index: index, store: store, root: root, output: output)

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
    private static func checkModelAgreement(index: StructureIndex, graph: MindGraph) -> Int {
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
        return graph.baseCommit.isEmpty ? 0 : mismatches.count
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

    // MARK: 渲染

    /// 把三级各渲染一张。宽度取 620：三栏窗口里中间栏的常见宽度，在这个宽度下不挤才算过。
    @MainActor
    private static func renderLevels(
        index: StructureIndex,
        store: DomainModelStore,
        root: URL,
        output: URL
    ) async {
        log("—— 截图 ——")
        var cases: [(name: String, path: [String])] = [("1-overview", [])]
        if let largest = index.modeledDomains.first {
            cases.append(("2-domain", [largest.id]))
            // 选一个带子包的模块，再往下走一层：子包方块和文件清单都要看得到。
            let module = largest.modules.first { !index.contents(of: $0, at: []).packages.isEmpty }
                ?? largest.modules.first
            if let module {
                cases.append(("3-module", [largest.id, module.id]))
                if let package = index.contents(of: module, at: []).packages.first {
                    cases.append(("4-package", [largest.id, module.id] + package.subpath))
                }
            }
        }
        for item in cases {
            let view = StructureMapView(
                store: store,
                root: root,
                selectedDomain: .constant(nil),
                onOpenFile: { _ in },
                preloaded: index,
                initialPath: item.path
            )
            .background(Color(nsColor: .textBackgroundColor))
            await snapshot(view, size: NSSize(width: 620, height: 720), to: output.appending(path: "\(item.name).png"))
        }

        // 整窗：检查「结构」页签放进三栏之后的比例。
        let window = WikiWindowView(
            root: root,
            workspace: nil,
            autoLoad: true,
            initiallySelectedDomain: nil,
            initialCenterMode: .structure
        )
        await snapshot(window, size: NSSize(width: 1280, height: 760), to: output.appending(path: "5-window.png"))
    }

    /// 挂到屏幕外的真实窗口上再截图。
    ///
    /// 不用 `ImageRenderer`：它画不了 `Button`、`Picker` 这类原生控件，会整块替换成占位符。
    @MainActor
    static func snapshot<Content: View>(_ view: Content, size: NSSize, to url: URL) async {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -8000, y: -8000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI 首次布局与异步加载都要等几轮 runloop，太快截图会得到空白。
        try? await Task.sleep(nanoseconds: 1_200_000_000)

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
#endif
