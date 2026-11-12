#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// 校验报告只读核对与隔离预览；不生成用户仓库建议、不确认用户知识、不调用模型。
enum WikiSourceCheckVerification {
    nonisolated static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["QIYIDE_VERIFY_SOURCE_CHECK_ROOT"] {
            Task { @MainActor in
                do { try await audit(root: URL(fileURLWithPath: path), output: env["QIYIDE_VERIFY_SOURCE_CHECK_JSON"]); NSApp.terminate(nil) }
                catch { fputs("[source-check-audit] ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        } else if let destination = env["QIYIDE_VERIFY_SOURCE_CHECK_PREVIEW"] {
            Task { @MainActor in
                do { try await preview(output: URL(fileURLWithPath: destination)); NSApp.terminate(nil) }
                catch { fputs("[source-check-preview] ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
            }
        }
    }

    @MainActor
    private static func audit(root: URL, output: String?) async throws {
        let directory = root.appending(path: ".qiyide/wiki")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let before = try files.map { try Data(contentsOf: $0) }
        let store = WikiStore(root: root); store.reloadNow()
        try await finish(store)
        guard store.knowledgeCheck.status == .completed else { throw WikiGenerationError.invalidOutput(store.knowledgeCheck.message) }
        let snapshot = store.entries
        let mappings = try await WikiBackgroundWork.run {
            let resolver = WikiSourceScopeResolver(root: root)
            return try snapshot.map { entry -> [String: String] in
                let resolved = try resolver.resolve(entry.scopePaths)
                return ["id": entry.id, "resolvedScopes": String(resolved.scopes.count), "candidateSources": String(resolved.sources.count),
                        "unresolvedScopes": String(resolved.issues.count), "suggestionOnly": "true"]
            }
        }
        let counts = WikiKnowledgeCheckCounts.count(entries: store.entries, report: store.knowledgeReport)
        let details = store.entries.map { entry -> [String: Any] in
            let assessment = store.assessment(for: entry)
            return ["id": entry.id, "state": assessment.state.rawValue, "sourceCount": entry.sources.count,
                    "scopeCount": entry.scopePaths.count, "issueCount": assessment.issues.count,
                    "reason": assessment.issues.first?.kind.rawValue ?? "none",
                    "unboundScopes": assessment.issues.filter { $0.kind == .scopeUnbound && $0.path != nil }.count,
                    "nextStep": assessment.nextStep]
        }
        let after = try files.map { try Data(contentsOf: $0) }
        guard before == after else { throw WikiGenerationError.invalidOutput("只读校验改变了原有文件") }
        let info: [String: Any] = ["entries": store.entries.count, "ready": counts.ready, "review": counts.review,
            "status": store.knowledgeCheck.status.rawValue, "message": store.knowledgeCheck.message,
            "checkedSources": store.knowledgeReport.sourcesChecked, "results": details, "mappingCandidates": mappings,
            "originalFilesUnchanged": true, "modelRequests": 0, "knowledgeConfirmedOrRewritten": false]
        let data = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: URL(fileURLWithPath: output)) }
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private static func preview(output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appending(path: "qiyide-source-check-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["app/src/main/java/com/example/platform/agent/orders/Order.java", "app/src/main/java/com/example/platform/service/users/User.java"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "class LocalPreview {}".write(to: url, atomically: true, encoding: .utf8)
        }
        let store = WikiStore(root: root, knowledgeChecker: { entries, root, progress in
            for index in 0..<entries.count {
                try Task.checkCancellation()
                progress(.init(checkedEntries: index, totalEntries: entries.count, currentEntry: entries[index].title, currentPath: entries[index].scopePaths.first ?? ""))
                try await Task.sleep(nanoseconds: 160_000_000)
            }
            return try await WikiBackgroundWork.run {
                try WikiKnowledgeReview.evaluateChecked(entries: entries, root: root, onProgress: progress)
            }
        })
        var target: WikiEntry?
        for index in 0..<9 {
            var entry = try store.create(type: .module, title: index == 0 ? "订单领域 · 未绑定来源" : "领域模板 \(index) · 未绑定来源")
            entry.body = "领域范围与设计含义仍需人工对照；这是本地组件样例。"
            entry.scopePaths = [index == 0 ? "agent/orders" : "agent/missing-\(index)"]
            entry.status = .confirmed
            entry.protectsHumanContent = true
            entry.confirmation = WikiKnowledgeReview.confirmation(for: entry, root: root)
            try store.save(entry)
            if index == 0 { target = entry }
        }
        store.refreshKnowledge(contentChanged: true)
        try await render(WikiKnowledgeOverview(store: store, entries: store.entries, onSelect: { _ in }, onCreateRule: {}, onShowContext: {}),
                         size: .init(width: 660, height: 820), to: output.appending(path: "checking-progress.png"), wait: 350_000_000)
        try await finish(store)
        guard WikiKnowledgeCheckCounts.count(entries: store.entries, report: store.knowledgeReport).review == 9 else {
            throw WikiGenerationError.invalidOutput("未绑定来源的 9 条样例不能变绿")
        }
        try await render(WikiKnowledgeOverview(store: store, entries: store.entries, onSelect: { _ in }, onCreateRule: {}, onShowContext: {}),
                         size: .init(width: 660, height: 820), to: output.appending(path: "completed-with-blockers.png"))
        try await render(WikiSourceCheckReportSheet(store: store, entries: store.entries, onSelect: { _ in }),
                         size: .init(width: 640, height: 660), to: output.appending(path: "report-exact-paths.png"))
        guard let original = target else { throw WikiKnowledgeError.emptyContent }
        let originalBytes = try Data(contentsOf: original.fileURL)
        let proposal = try await store.proposeSourceBinding(for: original)
        guard proposal.proposalFor == original.id, proposal.sources.count == 1,
              try Data(contentsOf: original.fileURL) == originalBytes else { throw WikiGenerationError.invalidOutput("来源更新必须保留原文") }
        _ = try store.acceptProposal(proposal)
        try await finish(store)
        guard WikiKnowledgeCheckCounts.count(entries: store.entries, report: store.knowledgeReport).ready == 1 else {
            throw WikiGenerationError.invalidOutput("人工接受来源绑定后的样例应可核验")
        }
        try await render(WikiKnowledgeOverview(store: store, entries: store.entries, onSelect: { _ in }, onCreateRule: {}, onShowContext: {}),
                         size: .init(width: 660, height: 820), to: output.appending(path: "human-accepted-binding.png"))
        print("[source-check-preview] PASS: visible progress, persistent 9-entry blocker report, exact paths, preserved original, explicit human source binding; 0 model calls")
    }

    @MainActor
    private static func finish(_ store: WikiStore) async throws {
        for _ in 0..<500 {
            if !store.isCheckingKnowledge { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        store.cancelKnowledgeCheck()
        throw WikiGenerationError.invalidOutput("来源校验未结束")
    }

    @MainActor
    private static func render<Content: View>(_ view: Content, size: NSSize, to url: URL, wait: UInt64 = 300_000_000) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: .init(origin: .init(x: -6000, y: -6000), size: size),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = hosting
        window.orderFrontRegardless(); hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: wait)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw WikiGenerationError.invalidOutput("组件截图不可用") }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WikiGenerationError.invalidOutput("组件截图编码失败") }
        try data.write(to: url); window.orderOut(nil)
        print("[source-check-preview] \(url.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
    }
}
#endif
