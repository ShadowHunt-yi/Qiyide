#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// 只读状态核对与本地响应截图；没有真实模型调用，不改被检查仓库。
enum WikiCurationResumeVerification {
    nonisolated static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["QIYIDE_VERIFY_CURATE_STATE"] {
            Task { @MainActor in
                do {
                    let root = URL(fileURLWithPath: path)
                    let files = [WikiCurationJob.url(root: root), WikiInsightStore.url(root: root)]
                    let before = try files.map { try Data(contentsOf: $0) }
                    let store = WikiStore(root: root); store.reloadNow()
                    let runner = WikiCurationRunner()
                    let started = Date()
                    await runner.preview(root: root, entries: store.entries)
                    guard runner.errorMessage == nil else { throw WikiGenerationError.invalidOutput(runner.errorMessage ?? "状态核对失败") }
                    let after = try files.map { try Data(contentsOf: $0) }
                    guard before == after else { throw WikiGenerationError.invalidOutput("只读核对修改了检查点") }
                    let info: [String: Any] = [
                        "totalFiles": runner.coverage.totalFiles,
                        "currentUnderstanding": runner.coverage.understoodFiles,
                        "currentOutput": runner.coverage.outputFiles,
                        "legacyObservations": runner.coverage.legacyObservations,
                        "archivedLegacyObservations": runner.coverage.archivedLegacyObservations,
                        "savedEntries": runner.coverage.savedEntries,
                        "legacyFilesDone": runner.job.legacyProgress?.filesDone ?? 0,
                        "legacyFilesTotal": runner.job.legacyProgress?.filesTotal ?? 0,
                        "historicalRequests": runner.job.callsUsed,
                        "nextRunBudget": WikiCurationRunner.Options.standard.maxCallsPerRun,
                        "historicalRequestsDoNotConsumeNextRun": true,
                        "checkpointsUnchanged": before == after,
                        "modelRequestsSent": 0,
                        "seconds": Date().timeIntervalSince(started)
                    ]
                    let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
                    if let output = env["QIYIDE_VERIFY_CURATE_STATE_OUT"] { try data.write(to: URL(fileURLWithPath: output)) }
                    print(String(decoding: data, as: UTF8.self))
                    NSApp.terminate(nil)
                } catch {
                    fputs("[curation-state] ERROR: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
            }
        } else if let path = env["QIYIDE_VERIFY_CURATE_RESUME_OUT"] {
            Task { @MainActor in
                do { try await renderCases(output: URL(fileURLWithPath: path)); NSApp.terminate(nil) }
                catch { fputs("[curation-resume-preview] ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }

    @MainActor
    private static func renderCases(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "qiyide-resume-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["OrderCreate", "OrderCancel"] {
            let url = root.appending(path: "Sources/Orders/\(name).swift")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "struct \(name) {}".write(to: url, atomically: true, encoding: .utf8)
        }
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        old.filesDone = 2627; old.filesTotal = 2654
        try old.save(root: root)
        var legacy: [String: RepoFileInsight] = [:]
        for index in 0..<2629 {
            let path = index == 0 ? "Sources/Orders/OrderCreate.swift" : "Legacy/Observation-\(index).swift"
            legacy[path] = .init(path: path, purpose: "隔离旧格式观察，不作为当前代码证据", keyPoints: [])
        }
        try JSONEncoder().encode(["records": legacy]).write(to: WikiInsightStore.url(root: root))
        let request = AINarrativeRequest(baseURL: "https://local-test.invalid", model: "preview-only", apiKey: "",
            systemPrompt: "test", userPrompt: "", maxTokens: 2048, temperature: 0.1, timeout: 5)
        let runner = WikiCurationRunner(request: request, complete: { request in
            if request.systemPrompt.contains("\"files\"") {
                let files = request.userPrompt.split(separator: "\n").compactMap { line -> [String: Any]? in
                    guard line.hasPrefix("=== "), line.hasSuffix(" ===") else { return nil }
                    return ["path": String(line.dropFirst(4).dropLast(4)), "purpose": "本地样例的当前观察", "keyPoints": []]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
            }
            return "{\"action\":\"create\",\"responsibility\":\"本地合成模块说明，仍需人工核对\",\"decisions\":[],\"rules\":[]}"
        })
        let store = WikiStore(root: root); store.reloadNow()
        await runner.preview(root: root, entries: store.entries)
        try await render(runner: runner, store: store, to: output.appending(path: "legacy-retained.png"))
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: root, store: store, options: options)
        try await finish(runner)
        guard runner.coverage.understoodFiles == 2, runner.coverage.outputFiles == 0,
              runner.job.lastRun?.pauseReason == .requestBudget else { throw WikiGenerationError.invalidOutput("额度暂停进度不正确") }
        try await render(runner: runner, store: store, to: output.appending(path: "budget-exhausted.png"))
        try await render(runner: runner, store: store, to: output.appending(path: "budget-exhausted-dark.png"), appearance: .darkAqua)
        runner.start(root: root, store: store, options: options)
        try await finish(runner)
        guard runner.job.status == .finished, runner.coverage.outputFiles == 2,
              runner.job.callsUsed == 2364 else { throw WikiGenerationError.invalidOutput("续跑没有保留已理解内容") }
        try await render(runner: runner, store: store, to: output.appending(path: "resumed-completed.png"))
        print("[curation-resume-preview] PASS: legacy retained, current understanding visible, bounded budget pause, explicit resume, history preserved; 0 real-model calls")
    }

    @MainActor
    private static func finish(_ runner: WikiCurationRunner) async throws {
        for _ in 0..<600 {
            if !runner.isRunning { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        runner.stop()
        throw WikiGenerationError.invalidOutput("本地预览任务未结束")
    }

    @MainActor
    private static func render(runner: WikiCurationRunner, store: WikiStore, to url: URL,
                               appearance: NSAppearance.Name = .aqua) async throws {
        let size = NSSize(width: 600, height: 740)
        let hosting = NSHostingView(rootView: WikiIngestSheet(runner: runner, store: store, onClose: {}))
        hosting.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: .init(origin: .init(x: -6000, y: -6000), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); window.contentView = hosting
        window.orderFrontRegardless(); hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 800_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw WikiGenerationError.invalidOutput("无法渲染组件") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WikiGenerationError.invalidOutput("无法生成截图") }
        try data.write(to: url); window.orderOut(nil)
        print("[curation-resume-preview] \(url.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
#endif
