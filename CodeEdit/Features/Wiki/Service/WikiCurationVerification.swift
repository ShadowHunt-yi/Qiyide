//
//  WikiCurationVerification.swift
//  CodeEdit
//
//  端到端验证「整仓建档跑得动」：用小预算连跑几轮，检查两件事——
//  1. 进度单调上升（已建档文件数不能倒退、轮次必须推进）；
//  2. 条目的 sources 不被缩减（这是震荡的直接判据）。
//
//  为什么必须真跑：震荡只在「轮与轮之间交接状态」时暴露。
//  单测能证明 applyDraft 的并集逻辑对，但证明不了下一轮调度会不会把
//  刚建好的文件又重新当成待处理。这一层只有跑两轮才看得见。
//
//  用法：
//    QIYIDE_VERIFY_CURATE=/path/to/repo build/QiyideDev.app/Contents/MacOS/QiyideDev
//  可选：
//    QIYIDE_VERIFY_CURATE_ROUNDS=2    跑几轮（默认 2）
//    QIYIDE_VERIFY_CURATE_FILES=4     每轮预算文件数（默认 4，小预算省调用）
//

#if DEBUG
import Foundation

enum WikiCurationVerification {

    /// 直接写 stderr：`print` 在重定向到文件时是块缓冲，
    /// 一旦卡住，日志全留在缓冲区里，等于没有。
    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func runIfRequested() {
        guard let rootPath = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_CURATE"] else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let rounds = Int(environment["QIYIDE_VERIFY_CURATE_ROUNDS"] ?? "2") ?? 2
        let filesPerRound = Int(environment["QIYIDE_VERIFY_CURATE_FILES"] ?? "4") ?? 4

        Task { @MainActor in
            let root = URL(fileURLWithPath: rootPath)
            let store = WikiStore(root: root)
            store.reloadNow()
            let runner = WikiCurationRunner.shared
            let start = metrics(store: store, root: root)
            log("[verify][curate] 起始：\(start.entries) 条 · job 第 \(start.round) 轮 · 已建档 \(start.done)")

            // 诊断：把「扫描 → 已建档/待处理」这条链摊开。
            // 面板说「全部已覆盖」而文件数只有一半时，必须能看到是哪一步归零的。
            do {
                let model = AINarrativeStore.shared.providerLabel
                let insights = WikiInsightStore.load(root: root)
                let curated = Set(store.entries.flatMap(\.sources))
                let (modules, considered) = WikiRepoIngest.scan(
                    root: root, maxFiles: 100_000, maxModules: Int.max
                )
                var fresh = 0
                var pendingFiles = 0
                var pendingModules = 0
                for module in modules {
                    var count = 0
                    for file in module.files {
                        let url = root.appending(path: file.path)
                        if insights.insight(for: file.path, url: url, model: model) != nil,
                           curated.contains(file.path) {
                            fresh += 1
                        } else {
                            count += 1
                        }
                    }
                    if count > 0 {
                        pendingModules += 1
                        pendingFiles += count
                    }
                }
                log("[verify][curate] 诊断：模块 \(modules.count) · 全仓 \(considered) · 已建档 \(fresh) · "
                    + "待处理 \(pendingFiles)（\(pendingModules) 个模块）· 模型「\(model)」")
            }

            // 连通性探测：区分「代码卡死」和「模型不响应」。
            // 建档每一轮都靠模型，如果这一项就慢，后面的超时都是它的后果。
            let probeStart = Date()
            do {
                if let request = AINarrativeStore.shared.makeRequest(system: "只回复一个词", user: "ping"),
                   let provider = AINarrativeStore.shared.makeProvider() {
                    let text = try await withProbeTimeout(seconds: 30) {
                        try await provider.complete(request.withMaxTokens(128))
                    }
                    let ms = Int(Date().timeIntervalSince(probeStart) * 1000)
                    log("[verify][curate] 模型连通：\(ms)ms · 返回「\(text.prefix(24))」")
                } else {
                    log("[verify][curate] 模型连通：未配置（\(AINarrativeStore.shared.blockedReason ?? "未知")）")
                }
            } catch {
                let ms = Int(Date().timeIntervalSince(probeStart) * 1000)
                log("[verify][curate] 模型连通：失败（\(ms)ms）· \(error)")
            }

            var previousSources: [String: Int] = [:]
            for index in 1...rounds {
                var options = WikiCurationRunner.Options.standard
                // 必须走整仓模式：`wholeRepo = false` 是「单轮」场景，
                // 只取前 defaultMaxModules(=8) 个模块，而那 8 个早已建档，
                // 于是会立刻报「全部已覆盖」——验的不是生产路径。
                options.wholeRepo = true
                options.filesPerRound = filesPerRound
                options.concurrency = 2
                // 用累计调用数卡预算：每轮 4 个文件约 2 次调用，跑完一轮就停。
                options.maxCallsPerRun = 3
                options.maxMinutes = 10

                let before = metrics(store: store, root: root)
                runner.start(root: root, store: store, options: options)
                guard runner.isRunning else {
                    log("[verify][curate] 第 \(index) 轮启动失败：\(runner.errorMessage ?? "未知原因")")
                    exit(1)
                }
                // 等这一轮跑完。建档在后台 Task 里，isRunning 在 finish() 时才翻回 false。
                // 带超时：跑不完也要能拿到现场，而不是无限等一个不会结束的任务。
                let deadline = Date().addingTimeInterval(600)
                while runner.isRunning, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if runner.isRunning {
                    log("[verify][curate] 第 \(index) 轮超时 600s：阶段 \(runner.stage.title) · "
                        + "detail「\(runner.detail)」· 错误 \(runner.errorMessage ?? "无")")
                    exit(1)
                }
                store.reloadNow()
                let after = metrics(store: store, root: root)

                log(
                    "[verify][curate] 第 \(index) 轮：条目 \(before.entries)→\(after.entries) · "
                        + "已建档 \(before.done)→\(after.done) · round \(before.round)→\(after.round)"
                )
                if let summary = runner.finishedSummary {
                    log("[verify][curate]   \(summary)")
                }

                // 震荡判据：上一轮已经建档的条目，sources 不能变少。
                // 变少说明新一轮把它引用的文件「摘掉」了，那些文件随即会变回待处理。
                let sources = sourceCounts(store)
                if !previousSources.isEmpty {
                    let regressed = previousSources.compactMap { id, count -> String? in
                        guard let now = sources[id], now < count else { return nil }
                        return "\(id)(\(count)→\(now))"
                    }
                    let verdict = regressed.isEmpty
                        ? "无（通过）"
                        : "\(regressed.count) 条，例如 \(regressed.prefix(3).joined(separator: "、"))"
                    log("[verify][curate]   sources 缩减：\(verdict)")
                }
                previousSources = sources
            }

            log("[verify][curate] 完成")
            exit(0)
        }
    }

    private struct Metrics {
        var entries: Int
        var round: Int
        var done: Int
    }

    @MainActor
    private static func metrics(store: WikiStore, root: URL) -> Metrics {
        let job = WikiCurationJob.load(root: root)
        return Metrics(entries: store.entries.count, round: job.round, done: job.filesDone)
    }

    /// 条目 id → sources 数量。只看数量就够：变少就是被摘掉了。
    @MainActor
    private static func sourceCounts(_ store: WikiStore) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(store.entries.count)
        for entry in store.entries {
            result[entry.id] = entry.sources.count
        }
        return result
    }

    /// 探测用的短超时。模型挂住时不能让验证脚本自己也挂住。
    private static func withProbeTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                group.cancelAll()
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }
}
#endif
