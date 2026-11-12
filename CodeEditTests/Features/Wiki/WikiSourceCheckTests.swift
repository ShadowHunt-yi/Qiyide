import Foundation
import Testing
@testable import CodeEdit

private final class SourceCheckFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "qiyide-source-check-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func entry(scope: String) -> WikiEntry {
        var entry = WikiEntry(id: "domain", title: "领域说明", type: .module, tags: ["domain"], sources: [],
            relations: [], body: "领域划分需要人工核对", updatedAt: Date(), fileURL: root.appending(path: ".qiyide/wiki/domain.md"))
        entry.scopePaths = [scope]
        entry.status = .confirmed
        entry.confirmation = WikiKnowledgeReview.confirmation(for: entry, root: root)
        return entry
    }
}

@Suite(.serialized) @MainActor struct WikiSourceCheckTests {
    @Test func unresolvedScopeExplainsTheExactBlockingPathOnEveryRecheck() throws {
        let f = try SourceCheckFixture(), entry = f.entry(scope: "agent/orders")
        let first = WikiKnowledgeReview.evaluate(entries: [entry], root: f.root).assessment(for: entry)
        let second = WikiKnowledgeReview.evaluate(entries: [entry], root: f.root).assessment(for: entry)
        #expect(first.state == .unverifiable)
        #expect(second.state == .unverifiable)
        #expect(first.detail.contains("agent/orders"))
        #expect(first.detail.contains("来源"))
    }

    @Test func domainSeedingRestoresJavaBusinessAliasesToRealFileEvidence() throws {
        let f = try SourceCheckFixture()
        try f.write("app/src/main/java/com/example/platform/agent/orders/Order.java", "package com.example.platform.agent.orders; class Order {}")
        try f.write("app/src/main/java/com/example/platform/service/users/User.java", "package com.example.platform.service.users; class User {}")
        var root = MindNode(id: "system", title: "root", kind: .system)
        var domain = MindNode(id: "domain:orders", title: "订单", kind: .domain)
        domain.parentID = root.id; domain.packages = ["agent/orders"]; root.childIDs = [domain.id]
        let store = WikiStore(root: f.root)
        _ = try WikiDomainSeeding.seed(graph: .init(nodes: [root, domain], rootID: root.id), into: store)
        let entry = try #require(store.entries.first)
        #expect(entry.sources == ["app/src/main/java/com/example/platform/agent/orders/Order.java"])
        #expect(entry.scopePaths == ["app/src/main/java/com/example/platform/agent/orders"])
    }

    @Test func manualDuplicateCheckDoesNotReplaceAnInFlightRun() throws {
        let f = try SourceCheckFixture(), store = WikiStore(root: f.root)
        store.refreshKnowledge()
        let generation = store.knowledgeGeneration
        store.refreshKnowledge()
        #expect(store.knowledgeGeneration == generation)
    }
}

extension WikiSourceCheckTests {
    private func finish(_ store: WikiStore) async throws {
        for _ in 0..<400 {
            if !store.isCheckingKnowledge { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        store.cancelKnowledgeCheck()
        throw WikiGenerationError.invalidOutput("来源校验未在本地超时内结束")
    }

    @Test func manualCheckPublishesStartAndPersistentCompletedResult() async throws {
        let f = try SourceCheckFixture(), store = WikiStore(root: f.root)
        store.refreshKnowledge()
        #expect(store.isCheckingKnowledge)
        #expect(store.knowledgeCheck.status == .checking)
        #expect(store.knowledgeCheck.startedAt != nil)
        try await finish(store)
        #expect(store.knowledgeCheck.status == .completed)
        #expect(store.knowledgeCheck.message.contains("校验完成"))
        #expect(store.knowledgeReport.checkedAt != nil)
        #expect(store.knowledgeCheck.finishedAt != nil)
    }

    @Test func aCompletedCheckCanStillBeUnverifiableAndDoesNotRewriteEvidence() async throws {
        let f = try SourceCheckFixture(), store = WikiStore(root: f.root)
        let entry = f.entry(scope: "agent/orders")
        try store.save(entry)
        let before = try Data(contentsOf: entry.fileURL)
        try await finish(store)
        #expect(store.knowledgeCheck.status == .completed)
        #expect(store.assessment(for: entry).state == .unverifiable)
        #expect(store.knowledgeCheck.message.contains("1 条仍需处理"))
        #expect(store.assessment(for: entry).issues.contains { $0.path == "agent/orders" && $0.kind == .scopeUnbound })
        #expect(store.assessment(for: entry).issues.contains { $0.kind == .sourcesUnbound })
        #expect(try Data(contentsOf: entry.fileURL) == before)
        store.refreshKnowledge()
        try await finish(store)
        #expect(store.assessment(for: entry).state == .unverifiable)
        #expect(store.entry(id: entry.id)?.sources.isEmpty == true)
    }

    @Test func cancelledWorkerCannotPublishLateSuccessOrProgress() async throws {
        let f = try SourceCheckFixture()
        let store = WikiStore(root: f.root, knowledgeChecker: { entries, root, progress in
            try? await Task.sleep(nanoseconds: 80_000_000) // 模拟供应方迟到且不理会取消。
            progress(.init(checkedEntries: entries.count, totalEntries: entries.count, currentEntry: "迟到回调"))
            return WikiKnowledgeReview.evaluate(entries: entries, root: root)
        })
        store.refreshKnowledge()
        await Task.yield()
        store.cancelKnowledgeCheck()
        #expect(store.knowledgeCheck.status == .cancelled)
        #expect(!store.isCheckingKnowledge)
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(store.knowledgeCheck.status == .cancelled)
        #expect(store.knowledgeReport.checkedAt == nil)
        #expect(store.knowledgeCheck.progress.currentEntry != "迟到回调")
    }

    @Test func checkerFailureIsVisibleAndDoesNotClaimCompletion() async throws {
        let f = try SourceCheckFixture()
        let store = WikiStore(root: f.root, knowledgeChecker: { _, _, _ in
            throw WikiGenerationError.unreadableSource("测试来源")
        })
        store.refreshKnowledge()
        try await finish(store)
        #expect(store.knowledgeCheck.status == .failed)
        #expect(store.knowledgeCheck.message.contains("测试来源"))
        #expect(store.knowledgeReport.checkedAt == nil)
    }

    @Test func anIncompleteReportCannotBecomeCompletedOrTrusted() async throws {
        let f = try SourceCheckFixture()
        let store = WikiStore(root: f.root, knowledgeChecker: { _, _, _ in .init() })
        store.refreshKnowledge()
        try await finish(store)
        #expect(store.knowledgeCheck.status == .failed)
        #expect(store.knowledgeCheck.message.contains("不完整"))
        #expect(store.knowledgeReport.checkedAt == nil)
    }

    @Test func contentChangeReplacesTheOldCheckAndOnlyLatestInputIsPublished() async throws {
        let f = try SourceCheckFixture()
        let store = WikiStore(root: f.root, knowledgeChecker: { entries, root, progress in
            try await Task.sleep(nanoseconds: 60_000_000)
            return try WikiKnowledgeReview.evaluateChecked(entries: entries, root: root, onProgress: progress)
        })
        store.refreshKnowledge()
        let oldID = store.knowledgeCheck.id
        var entry = try store.create(type: .rule, title: "新的内容")
        entry.body = "人工规则尚未确认"
        try store.save(entry)
        try await finish(store)
        #expect(store.knowledgeCheck.id != oldID)
        #expect(store.knowledgeCheck.status == .completed)
        #expect(store.knowledgeCheck.progress.totalEntries == 1)
        #expect(store.assessment(for: entry).state == .draft)
    }

    @Test func progressIncludesEntryAndSourceWorkAndFinalReportCounts() throws {
        let f = try SourceCheckFixture()
        let entry = f.entry(scope: "agent/orders")
        let report = try WikiKnowledgeReview.evaluateChecked(entries: [entry], root: f.root)
        #expect(report.sourcesChecked == 1)
        let counts = WikiKnowledgeCheckCounts.count(entries: [entry], report: report)
        #expect(counts.ready == 0)
        #expect(counts.review == 1)
        #expect(counts.reasons[.scopeUnbound] == 1)
        #expect(counts.checking == 0)
    }

    @Test func vanishedScopeIsUnverifiableNotFalselyLabeledAsContentChanged() throws {
        let f = try SourceCheckFixture()
        try f.write("Sources/Order.swift", "struct Order {}")
        var entry = f.entry(scope: "Sources")
        entry.sources = ["Sources/Order.swift"]
        entry.confirmation = WikiKnowledgeReview.confirmation(for: entry, root: f.root)
        try FileManager.default.removeItem(at: f.root.appending(path: "Sources"))
        let assessment = WikiKnowledgeReview.evaluate(entries: [entry], root: f.root).assessment(for: entry)
        #expect(assessment.state == .unverifiable)
        #expect(assessment.issues.contains { $0.kind == .unreadable && $0.path == "Sources" })
        #expect(assessment.changedSources.isEmpty)
    }

    @Test func aSourceBindingCreatesAProposalAndPreservesTheConfirmedOriginal() async throws {
        let f = try SourceCheckFixture()
        try f.write("app/src/main/java/com/example/platform/agent/orders/Order.java", "class Order {}")
        try f.write("app/src/main/java/com/example/platform/service/users/User.java", "class User {}")
        let store = WikiStore(root: f.root), entry = f.entry(scope: "agent/orders")
        try store.save(entry)
        let before = try Data(contentsOf: entry.fileURL)
        let proposal = try await store.proposeSourceBinding(for: entry)
        #expect(proposal.isDraft)
        #expect(proposal.proposalFor == entry.id)
        #expect(proposal.body == entry.body)
        #expect(proposal.sources == ["app/src/main/java/com/example/platform/agent/orders/Order.java"])
        #expect(proposal.scopePaths == ["app/src/main/java/com/example/platform/agent/orders"])
        #expect(try Data(contentsOf: entry.fileURL) == before)
        #expect(store.entry(id: entry.id)?.status == .confirmed)
        let accepted = try store.acceptProposal(proposal)
        let assessment = WikiKnowledgeReview.evaluate(entries: [accepted], root: f.root).assessment(for: accepted)
        #expect(assessment.state == .current)
        #expect(accepted.body == entry.body)
        #expect(accepted.confirmation?.sources.count == 1)
    }

    @Test func ambiguousBusinessAliasesAreNotGuessedOrWritten() async throws {
        let f = try SourceCheckFixture()
        for module in ["app-a", "app-b"] {
            try f.write("\(module)/src/main/java/com/example/platform/agent/orders/Order.java", "class Order {}")
            try f.write("\(module)/src/main/java/com/example/platform/service/users/User.java", "class User {}")
        }
        let resolution = try WikiSourceScopeResolver(root: f.root).resolve(["agent/orders"])
        #expect(resolution.sources.isEmpty)
        #expect(resolution.issues.first?.detail.contains("多个源码模块") == true)
        let store = WikiStore(root: f.root), entry = f.entry(scope: "agent/orders")
        try store.save(entry)
        do {
            _ = try await store.proposeSourceBinding(for: entry)
            Issue.record("多义来源不能自动绑定")
        } catch { #expect(error.localizedDescription.contains("多个源码模块")) }
        #expect(store.entries.count == 1)
    }

    @Test func sourceBindingProposalStillRejectsNewChangesAtAcceptTime() async throws {
        let f = try SourceCheckFixture()
        try f.write("Sources/Order.swift", "struct Order {}")
        let entry = f.entry(scope: "Sources"), store = WikiStore(root: f.root)
        try store.save(entry)
        let proposal = try await store.proposeSourceBinding(for: entry)
        try f.write("Sources/Order.swift", "struct Changed {}")
        #expect(throws: (any Error).self) { try store.acceptProposal(proposal) }
        #expect(store.entry(id: entry.id)?.sources.isEmpty == true)
        #expect(store.entry(id: proposal.id) != nil)
    }

    @Test func scopeResolverUsesExactPathsAndRejectsUnsafeAliasPaths() throws {
        let f = try SourceCheckFixture()
        try f.write("Sources/Order.swift", "struct Order {}")
        let resolver = WikiSourceScopeResolver(root: f.root)
        let resolved = try resolver.resolve(["Sources", "Sources"])
        #expect(resolved.scopes == ["Sources"])
        #expect(resolved.sources == ["Sources/Order.swift"])
        #expect(resolved.issues.isEmpty)
        let invalid = try resolver.resolve(["../outside", "agent/ordersExtra"])
        #expect(invalid.sources.isEmpty)
        #expect(invalid.issues.count == 2)
    }
}
