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
import Foundation

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

            log("—— 知识条目预览（不写盘）——")
            for domain in result.graph.domains.prefix(2) {
                let body = WikiDomainSeeding.body(for: domain, in: result.graph)
                log("《\(domain.displayTitle)》正文前 16 行：")
                for line in body.split(separator: "\n", omittingEmptySubsequences: false).prefix(16) {
                    log("  | \(line)")
                }
            }

            log("验证结束")
            exit(0)
        }
    }

    private static func log(_ text: String) {
        print("[verify][domain] \(text)")
        fflush(stdout)
    }
}
#endif
