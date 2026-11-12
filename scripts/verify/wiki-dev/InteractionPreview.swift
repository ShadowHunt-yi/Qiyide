//  隔离项目 + 真 SwiftUI 组件；任务等待/失败使用可控替身，不发送模型请求。
import AppKit
import SwiftUI

@MainActor
enum InteractionPreview {
    nonisolated static func runIfRequested() {
        guard let destination = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_INTERACTION_OUT"] else { return }
        Task { @MainActor in
            let base = FileManager.default.temporaryDirectory.appending(path: "qiyide-ux-preview-\(UUID().uuidString)")
            do {
                defer { try? FileManager.default.removeItem(at: base) }
                let output = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let root = base.appending(path: "架构交互验证")
                try FileManager.default.createDirectory(at: root.appending(path: "Sources/API"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: root.appending(path: "Sources/Domain"), withIntermediateDirectories: true)
                try "struct APIEntry { let rule = BusinessRule() }".write(to: root.appending(path: "Sources/API/Entry.swift"), atomically: true, encoding: .utf8)
                try "struct BusinessRule { let amount = 1 }".write(to: root.appending(path: "Sources/Domain/Rule.swift"), atomically: true, encoding: .utf8)
                let workspace = WorkspaceDocument(fileURL: root)
                let waiting = WikiArchitectureRunner(root: root, reportsActivity: false, prepare: { _, _, progress in
                    progress(.init(.scan, "隔离样例：已发现 2 个源文件", completed: 2))
                    progress(.init(.dependencies, "隔离样例：已解析 4/4 份文件证据", completed: 4, total: 4))
                    progress(.init(.plan, "隔离样例：等待模型返回结构化结果", attempt: 1, attempts: 2))
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw CocoaError(.userCancelled)
                }, commit: { _, _, _ in })
                @MainActor func view(_ mode: WikiWindowView.CenterMode, _ runner: WikiArchitectureRunner) -> WikiWindowView {
                    WikiWindowView(root: root, workspace: workspace, autoLoad: true,
                                   initialCenterMode: mode, architectureRunner: runner)
                }
                try await render(view(.architecture, waiting), size: .init(width: 900, height: 620), to: output.appending(path: "architecture-empty-900.png"))
                waiting.start(mode: .staticOnly)
                try await Task.sleep(nanoseconds: 20_000_000)
                try await render(view(.architecture, waiting), size: .init(width: 1280, height: 760), to: output.appending(path: "architecture-running.png"))
                try await render(view(.knowledge, waiting), size: .init(width: 1280, height: 760), to: output.appending(path: "knowledge-running-dark.png"), appearance: .darkAqua)
                guard waiting.snapshot.isActive else { throw PreviewError.expectation("切换视角丢失任务") }
                waiting.cancel()
                for _ in 0..<100 where waiting.snapshot.status != .cancelled { try await Task.sleep(nanoseconds: 10_000_000) }
                guard waiting.snapshot.status == .cancelled else { throw PreviewError.expectation("取消没有结束") }
                try await render(view(.architecture, waiting), size: .init(width: 1280, height: 760), to: output.appending(path: "architecture-cancelled.png"))

                let live = WikiArchitectureRunner(root: root, reportsActivity: false)
                live.start(mode: .staticOnly)
                for _ in 0..<500 where live.snapshot.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
                guard live.snapshot.status == .completed, let result = live.result else { throw PreviewError.expectation("静态生成未完成") }
                let store = WikiStore(root: root)
                store.reloadNow()
                guard store.entries.isEmpty, !store.architecture.isEmpty else { throw PreviewError.expectation("空知识库无法查看独立架构") }
                try await render(view(.architecture, live), size: .init(width: 1280, height: 760), to: output.appending(path: "architecture-completed.png"))
                // 有架构但没有领域模型时，也必须允许停留在领域模型视角。
                try await render(view(.mindmap, live), size: .init(width: 1280, height: 760), to: output.appending(path: "domain-model-independent.png"))
                let detailView = WikiWindowView(
                    root: root, workspace: workspace, autoLoad: true, initialCenterMode: .architecture,
                    initiallySelectedArchitectureDomain: result.architecture.domains.first?.name,
                    architectureRunner: live
                )
                try await render(detailView, size: .init(width: 1280, height: 760), to: output.appending(path: "architecture-selected-domain.png"))
                let ingest = WikiIngestSheet(runner: WikiCurationRunner(), store: store, onClose: {})
                try await render(ingest, size: .init(width: 560, height: 660), to: output.appending(path: "ingest-preview.png"))
                let oldBytes = try Data(contentsOf: WikiArchitecture.url(root: root))
                let failing = WikiArchitectureRunner(root: root, reportsActivity: false,
                    prepare: { _, _, progress in progress(.init(.plan, "隔离样例：候选生成完成")); return result },
                    commit: { _, _, progress in progress(.init(.save, "隔离样例：保存失败")); throw CocoaError(.fileWriteNoPermission) })
                failing.start(mode: .staticOnly)
                for _ in 0..<100 where failing.snapshot.isActive { try await Task.sleep(nanoseconds: 10_000_000) }
                guard failing.snapshot.status == .failed, failing.canRetrySave,
                      try Data(contentsOf: WikiArchitecture.url(root: root)) == oldBytes else { throw PreviewError.expectation("失败破坏旧图") }
                try await render(view(.architecture, failing), size: .init(width: 1280, height: 760), to: output.appending(path: "architecture-save-failed.png"))
                let blocked = WikiArchitectureRunner(root: root, reportsActivity: false, aiReady: { false }, blockedReason: { "隔离样例：AI 未配置" })
                blocked.start()
                try await render(view(.architecture, blocked), size: .init(width: 900, height: 620), to: output.appending(path: "architecture-blocked-900.png"))
                try FileManager.default.removeItem(at: base)
                print("[interaction-preview] PASS: empty wiki, shared task, cross-view progress, cancellation, static generation, old-result protection")
                print("[interaction-preview] \(output.path)")
                exit(0)
            } catch {
                print("[interaction-preview] FAILED: \(error)")
                exit(1)
            }
        }
    }

    private enum PreviewError: Error { case expectation(String), bitmap }

    private static func render<Content: View>(
        _ view: Content, size: NSSize, to url: URL, appearance: NSAppearance.Name = .aqua
    ) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: .init(origin: .init(x: -6000, y: -6000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw PreviewError.bitmap }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.bitmap }
        try data.write(to: url)
        window.orderOut(nil)
        print("[interaction-preview] \(url.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
