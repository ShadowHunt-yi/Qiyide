//  用隔离样例离屏渲染真实 SwiftUI 组件，不读取或修改用户的业务仓库。
import AppKit
import SwiftUI

@MainActor
enum KnowledgePreview {
    nonisolated static func runIfRequested() {
        guard let destination = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_KNOWLEDGE_OUT"] else { return }
        Task { @MainActor in
            var previewRoot: URL?
            do {
                let output = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let root = FileManager.default.temporaryDirectory.appending(path: "qiyide-knowledge-preview-\(UUID().uuidString)")
                previewRoot = root
                let store = WikiStore(root: root)
                let source = root.appending(path: "src/Workbench.swift")
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "func suggestions() { returnBasicSuggestions() }".write(to: source, atomically: true, encoding: .utf8)

                let rule = try add(store, title: "建议卡片保持一致的数据含义", type: .rule,
                                   body: "工作台与 AI 搭子使用相同的建议文本和状态定义。不得因为复用数据对象而扩大用户可见范围。", confirm: true)
                _ = try add(store, title: "画像缺失时仍返回基础建议", type: .module,
                            body: "画像仅补充建议内容；画像缺失时返回基础建议，不阻断工作台主流程。",
                            sources: ["src/Workbench.swift"], confirm: true)
                _ = try add(store, title: "跨业务数据契约的边界", type: .decision,
                            body: "复用对外的数据契约，不直接依赖另一个业务的内部状态。若字段语义不同，应明确转换。", confirm: true)
                _ = try add(store, title: "入口职责与校验顺序", type: .module,
                            body: "入口先完成用户范围和参数校验，再进入工作台编排。该说明仍需人工结合实际代码核对。")
                var legacy = try store.create(type: .rule, title: "历史知识：数据可见范围")
                legacy.body = "历史记录需要补充确认依据，不能因为文件仍存在就当作当前事实。"
                legacy.status = .confirmed
                try store.save(legacy)
                try "func suggestions() { throw MissingPortrait() }".write(to: source, atomically: true, encoding: .utf8)
                let draft = WikiDraft(action: .update, target: rule.title, title: rule.title, type: .rule,
                                      tags: [], relations: [], body: "新增组织范围可见性，但必须保留原有的用户范围校验。是否允许这项业务变化，需要人决定。",
                                      reason: "需要明确新的数据范围", sources: [], mergeMode: .replace)
                let proposal = try store.applyDraft(draft, generatedBy: "隔离测试样例（未调用模型）", sources: [])
                await store.reload()
                store.knowledgeReport = WikiKnowledgeReview.evaluate(entries: store.entries, root: root)
                store.isCheckingKnowledge = false

                try await render(WikiWindowView(root: root, workspace: nil, autoLoad: true),
                                 size: .init(width: 1280, height: 800), to: output.appending(path: "overview-wide.png"))
                try await render(WikiWindowView(root: root, workspace: nil, autoLoad: true),
                                 size: .init(width: 980, height: 780), to: output.appending(path: "overview-compact.png"))
                try await render(WikiWindowView(root: root, workspace: nil, autoLoad: true, initiallySelectedEntry: proposal.id),
                                 size: .init(width: 1440, height: 960), to: output.appending(path: "update-proposal.png"))

                let ask = StructureAsk(
                    id: "preview-dependency", kind: .dependency,
                    title: "建议工作台新增对 AI 搭子 DTO 的引用",
                    detail: "工作台开始引用 AI 搭子的数据对象。这里只确认静态引用变化，运行行为仍需核验。",
                    anchors: [["workbench", "api"]],
                    evidence: [.init(file: "src/Workbench.swift", line: 1, sign: "+", text: "import SuggestionDTO")],
                    remedy: "先确认对外数据契约和用户可见范围，再调整实现。"
                )
                let references = VStack(alignment: .leading, spacing: 12) {
                    Text("结构提示与业务依据联动 · 隔离测试数据").font(.headline)
                    StructureAskRow(ask: ask, path: [], onNavigate: { _ in }, onOpenFile: { _ in },
                                    onDecide: { _, _ in }, onAdopt: { _ in }, decision: .violation,
                                    knowledgeEntries: store.entries, knowledgeReport: store.knowledgeReport,
                                    onSelectKnowledge: { _ in })
                    Text(StructureVerdict.scopeNote).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                try await render(references, size: .init(width: 900, height: 410), to: output.appending(path: "structure-reference.png"))
                let context = await WikiKnowledgeContext.load(root: root)
                try context.text.write(to: output.appending(path: "knowledge-context.txt"), atomically: true, encoding: .utf8)
                guard context.items.count == 2, context.excludedCount == 4 else {
                    throw NSError(domain: "KnowledgePreview.ExpectedContext", code: 1)
                }
                try FileManager.default.removeItem(at: root)
                previewRoot = nil
                print("[knowledge-preview] \(output.path)")
                print("[knowledge-preview] \(store.entries.count) entries; \(context.items.count) eligible; \(context.excludedCount) excluded")
                exit(0)
            } catch {
                if let previewRoot { try? FileManager.default.removeItem(at: previewRoot) }
                print("[knowledge-preview] failed: \(error)")
                exit(1)
            }
        }
    }

    private static func add(
        _ store: WikiStore, title: String, type: WikiEntryType, body: String,
        sources: [String] = [], confirm: Bool = false
    ) throws -> WikiEntry {
        var entry = try store.create(type: type, title: title)
        entry.body = body
        entry.domains = ["workbench"]
        entry.sources = sources
        try store.save(entry)
        if confirm { try store.confirm(store.entry(id: entry.id)!) }
        return store.entry(id: entry.id)!
    }

    private static func render<Content: View>(_ view: Content, size: NSSize, to url: URL) async throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: .init(origin: .init(x: -6000, y: -6000), size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 1_600_000_000)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "KnowledgePreview", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "KnowledgePreview", code: 2)
        }
        try data.write(to: url)
        print("[knowledge-preview] \(url.lastPathComponent): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        window.orderOut(nil)
    }
}
