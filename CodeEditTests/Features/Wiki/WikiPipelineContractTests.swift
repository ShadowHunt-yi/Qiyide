import Foundation
import Testing
@testable import CodeEdit

private final class PipelineFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "qiyide-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func draft(_ title: String = "Module", action: WikiDraft.Action = .create, body: String = "模块职责") -> WikiDraft {
        .init(action: action, target: action == .update ? title : "", title: title, type: .module,
              tags: [], relations: [], body: body, reason: "test", sources: [])
    }
}

@Suite(.serialized) @MainActor struct WikiPipelineContractTests {
    @Test func appendedKnowledgeTracksNewSource() throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "let first = 1")
        try f.write("Sources/B.swift", "let second = 1")
        let store = WikiStore(root: f.root)
        _ = try store.applyDraft(f.draft(), generatedBy: "test", sources: ["Sources/A.swift"])
        let updated = try store.applyDraft(f.draft(action: .update, body: "B 的新规则"), generatedBy: "test", sources: ["Sources/B.swift"])
        #expect(Set(updated.sources) == ["Sources/A.swift", "Sources/B.swift"])
        try store.confirm(updated)
        let confirmed = try #require(store.entry(id: updated.id))
        try f.write("Sources/B.swift", "let second = 2")
        #expect(WikiKnowledgeReview.evaluate(entries: [confirmed], root: f.root).assessment(for: confirmed).state == .stale)
    }

    @Test func fullReplacementRemovesObsoleteSources() throws {
        let f = try PipelineFixture()
        let store = WikiStore(root: f.root)
        _ = try store.applyDraft(f.draft(), generatedBy: "test", sources: ["Sources/A.swift", "Sources/B.swift"])
        var replace = f.draft(action: .update, body: "现在只包含 A")
        replace.mergeMode = .replace
        let updated = try store.applyDraft(replace, generatedBy: "test", sources: ["Sources/A.swift"])
        #expect(updated.sources == ["Sources/A.swift"])
    }

    @Test func aGeneratedDomainDraftCanBeConfirmedWithoutReload() throws {
        let f = try PipelineFixture()
        try f.write("Sources/Order/Order.swift", "struct Order {}")
        var root = MindNode(id: "system", title: "repo", kind: .system)
        var domain = MindNode(id: "domain:order", title: "订单域", kind: .domain)
        domain.parentID = root.id
        domain.packages = ["Sources/Order"]
        root.childIDs = [domain.id]
        let graph = MindGraph(nodes: [root, domain], rootID: root.id)
        let store = WikiStore(root: f.root)
        _ = try WikiDomainSeeding.seed(graph: graph, into: store)
        let entry = try #require(store.entries.first)
        try store.confirm(entry)
    }

    @Test func aNoKnowledgeResultIsValidAndUnknownActionIsRejected() {
        let skip = WikiCurator.parse("{\"action\":\"skip\",\"reason\":\"只有格式调整\"}")
        #expect(skip != nil)
        #expect(WikiCurator.parse("{\"action\":\"unknown\",\"title\":\"不应创建\",\"body\":\"占位\"}") == nil)
    }
}

private func pipelineRequest(baseURL: String = "https://local-test.invalid/v1", model: String = "isolated", apiKey: String = "") -> AINarrativeRequest {
    .init(baseURL: baseURL, model: model, apiKey: apiKey, systemPrompt: "test", userPrompt: "",
          maxTokens: 2_048, temperature: 0.1, timeout: 5)
}

private actor PipelineModel {
    var fileRequests: [[String]] = []
    var modulePrompts: [String] = []
    var skipModules = false
    var changeOnFileResponse: URL?
    var partialOnce = false

    func skip() { skipModules = true }
    func changeSource(_ url: URL) { changeOnFileResponse = url }
    func partial() { partialOnce = true }
    func resetRequests() { fileRequests = []; modulePrompts = [] }

    func complete(_ request: AINarrativeRequest) throws -> String {
        if request.systemPrompt.contains("\"files\"") {
            var paths = request.userPrompt.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("=== "), line.hasSuffix(" ===") else { return nil }
                return String(line.dropFirst(4).dropLast(4))
            }
            fileRequests.append(paths)
            if let url = changeOnFileResponse {
                try "struct ChangedWhileReading {}".write(to: url, atomically: true, encoding: .utf8)
                changeOnFileResponse = nil
            }
            if partialOnce { partialOnce = false; paths = Array(paths.prefix(1)) }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["files": paths.map {
                ["path": $0, "purpose": "观察：" + ($0 as NSString).lastPathComponent, "keyPoints": []] as [String: Any]
            }]), as: UTF8.self)
        }
        modulePrompts.append(request.userPrompt)
        if skipModules { return "{\"action\":\"skip\",\"reason\":\"没有可复用的新判断\"}" }
        return "{\"action\":\"create\",\"responsibility\":\"依据完整文件观察描述职责，业务意图待人工核对\",\"decisions\":[],\"rules\":[]}"
    }
}

private actor PipelineRequestGate {
    let limit: Int
    private(set) var sent = 0
    init(limit: Int) { self.limit = limit }
    func reserve() throws {
        guard sent < limit else { throw WikiGenerationError.requestLimit }
        sent += 1
    }
}

@Suite(.serialized) @MainActor struct WikiGenerationContractTests {
    private func finish(_ runner: WikiCurationRunner) async throws {
        for _ in 0..<400 {
            if !runner.isRunning { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        runner.stop()
        throw WikiGenerationError.invalidOutput("本地假模型的建档任务未在 10 秒内结束：" + runner.detail)
    }

    private func runner(_ model: PipelineModel) -> WikiCurationRunner {
        WikiCurationRunner(request: pipelineRequest(), complete: { try await model.complete($0) })
    }

    @Test func cacheCannotBlessAnOldReadWithCurrentMetadata() throws {
        let f = try PipelineFixture(), path = "Sources/Scope.swift"
        try f.write(path, "let limit = 1")
        let old = try WikiGenerationSources.read(path: path, root: f.root)
        let url = f.root.appending(path: path)
        let stamp = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        try f.write(path, "let limit = 9")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        var cache = WikiInsightStore()
        try cache.record(.init(path: path, purpose: "旧输入：limit = 1", keyPoints: []), source: old.source,
                         pipelineKey: "v3", model: "isolated")
        let current = try WikiGenerationSources.read(path: path, root: f.root).source
        #expect(cache.insight(for: current, pipelineKey: "v3") == nil)
        #expect(cache.insight(for: path, url: url, model: "v3") == nil)
        #expect(throws: (any Error).self) { try WikiGenerationSources.validate([old.source], root: f.root) }
        try cache.save(root: f.root)
        #expect(WikiInsightStore.load(root: f.root).allInsights.first?.sourceDigest == old.source.digest)
    }

    @Test func legacyCacheIsReadableButNotTrusted() throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        var old = RepoFileInsight(path: path, purpose: "legacy", keyPoints: [])
        old.model = "isolated"
        let data = try JSONEncoder().encode(["records": [path: old]])
        try f.write(".qiyide/wiki/.insights.json", String(decoding: data, as: UTF8.self))
        let loaded = WikiInsightStore.load(root: f.root)
        #expect(loaded.count == 1)
        #expect(loaded.loadIssue == nil)
        let source = try WikiGenerationSources.read(path: path, root: f.root).source
        #expect(loaded.insight(for: source, pipelineKey: "isolated") == nil)
    }

    @Test func cachePolicyIncludesEndpointProtocolAndPromptVersionButNotSecrets() {
        let a = pipelineRequest(apiKey: "secret-a"), b = pipelineRequest(apiKey: "secret-b")
        let key = WikiGenerationPolicy.key(for: a, kind: .openAICompatible)
        #expect(key == WikiGenerationPolicy.key(for: b, kind: .openAICompatible))
        #expect(key != WikiGenerationPolicy.key(for: a, kind: .anthropic))
        #expect(key != WikiGenerationPolicy.key(for: pipelineRequest(baseURL: "https://other.invalid"), kind: .openAICompatible))
        #expect(key != WikiGenerationPolicy.key(for: a, kind: .openAICompatible, promptVersion: "changed-v4"))
        #expect(!key.contains("secret"))
    }

    @Test func pathsDuplicatesAndInvalidStatesAreRejected() {
        let path = "Sources/A.swift"
        let item: [String: Any] = ["path": path, "purpose": "observed", "keyPoints": []]
        #expect(throws: (any Error).self) { try WikiModelClient.parseFiles(["files": [item, item]], requested: [path]) }
        #expect(throws: (any Error).self) {
            try WikiModelClient.parseFiles(["files": [["path": "Sources/Other.swift", "purpose": "unrequested"]]], requested: [path])
        }
        #expect(throws: (any Error).self) {
            try WikiModelClient.parseFiles(["files": [["path": path, "status": "invented", "purpose": "x"]]], requested: [path])
        }
        #expect(throws: (any Error).self) {
            try WikiModelClient.parseFiles(["files": [["path": path, "purpose": "x", "keyPoints": "not an array"]]], requested: [path])
        }
    }

    @Test func partialBatchKeepsSuccessfulItemsWithoutPretendingToBeComplete() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        try f.write("Sources/B.swift", "struct B {}")
        let receipts = try WikiGenerationSources.capture(paths: ["Sources/A.swift", "Sources/B.swift"], root: f.root)
        let job = WikiBatchJob(id: "partial", kind: .openAICompatible, request: pipelineRequest(),
            paths: receipts.map(\.path), sources: receipts, pipelineKey: "v3")
        let outcome = await WikiModelClient.execute(job, complete: { _ in
            "{\"files\":[{\"path\":\"Sources/A.swift\",\"purpose\":\"只完成 A\",\"keyPoints\":[]}]}"
        })
        #expect(outcome.insights.map(\.path) == ["Sources/A.swift"])
        #expect(outcome.error?.contains("Sources/B.swift") == true)
        #expect(!outcome.isSuccess)
        #expect(outcome.attempts == 1)
        #expect(outcome.insights.first?.sourceDigest == receipts.first?.digest)
    }

    @Test func unreadableInputIsNotSilentlyDroppedFromAPreparedBatch() throws {
        let f = try PipelineFixture()
        let files = [RepoFileCandidate(path: "Sources/Missing.swift", bytes: 10, score: 1, reasons: [])]
        #expect(throws: (any Error).self) {
            try WikiRepoIngest.prepareJobs(batches: [files], root: f.root, base: pipelineRequest(), kind: .openAICompatible)
        }
    }

    @Test func fileAndModuleInputsShareRedaction() async throws {
        let f = try PipelineFixture(), path = "Sources/Orders/Order.swift"
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456789"
        try f.write(path, "let api_key = \"\(secret)\"\nstruct Order {}")
        let file = RepoFileCandidate(path: path, bytes: 90, score: 1, reasons: [])
        let job = try #require(try WikiRepoIngest.prepareJobs(batches: [[file]], root: f.root,
            base: pipelineRequest(), kind: .openAICompatible).first)
        #expect(!job.request.userPrompt.contains(secret))
        #expect(job.sources.first?.digest == WikiGenerationPolicy.digest(try Data(contentsOf: f.root.appending(path: path))))
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(await model.modulePrompts.allSatisfy { !$0.contains(secret) })
    }

    @Test func anIncrementalRoundStillSynthesizesTheWholeModule() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/Orders/OrderCreate.swift", "struct OrderCreate {}")
        try f.write("Sources/Orders/OrderCancel.swift", "struct OrderCancel {}")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(store.entries.count == 1)
        let calls = runner.job.callsUsed
        await model.resetRequests()
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.callsUsed == calls)
        #expect(await model.fileRequests.isEmpty)
        try f.write("Sources/Orders/OrderCancel.swift", "struct OrderCancel { let changed = true }")
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(await model.fileRequests == [["Sources/Orders/OrderCancel.swift"]])
        let prompt = try #require(await model.modulePrompts.last)
        #expect(prompt.contains("OrderCreate.swift：观察：OrderCreate.swift"))
        #expect(prompt.contains("OrderCancel.swift：观察：OrderCancel.swift"))
        #expect(!prompt.contains("未解析"))
        #expect(store.entries.count == 1)
        #expect(store.entries[0].sources.count == 2)
    }

    @Test func incompleteUnderstandingNeverReplacesModuleKnowledge() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/Orders/OrderA.swift", "struct OrderA {}")
        try f.write("Sources/Orders/OrderB.swift", "struct OrderB {}")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        await model.partial()
        var options = WikiCurationRunner.Options.standard; options.wholeRepo = false
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(store.entries.isEmpty)
        #expect(await model.modulePrompts.isEmpty)
        #expect(WikiInsightStore.load(root: f.root).count == 1)
        #expect(runner.job.status == .paused)
        #expect(!runner.job.failures.isEmpty)
        await model.resetRequests()
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(await model.fileRequests.flatMap { $0 }.count == 1)
        #expect(store.entries.count == 1)
    }

    @Test func changedSourceResponseCannotWriteCacheOrKnowledge() async throws {
        let f = try PipelineFixture(), path = "Sources/Orders/Order.swift"
        try f.write(path, "struct Order {}")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        await model.changeSource(f.root.appending(path: path))
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(store.entries.isEmpty)
        #expect(WikiInsightStore.load(root: f.root).count == 0)
        #expect(runner.job.status == .failed)
        #expect(runner.errorMessage?.contains("变化") == true)
    }

    @Test func aModuleSkipIsPersistentNormalCompletionNotEmptyFailure() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/Orders/Order.swift", "struct Order {}")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        await model.skip()
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(store.entries.isEmpty)
        #expect(runner.job.callsUsed == 2)
        #expect(runner.job.moduleCheckpoints?.values.first?.noKnowledgeReason != nil)
        #expect(runner.job.failures.isEmpty)
        let calls = runner.job.callsUsed
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.callsUsed == calls)
        #expect(runner.job.status == .finished)
    }

    @Test func aHardRequestBudgetStopsBeforeRelateInsteadOfOvershooting() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.callsUsed == 1)
        #expect(WikiCurationJob.load(root: f.root).callsUsed == 1)
        #expect(await model.modulePrompts.isEmpty)
        #expect(runner.job.status == .paused)
        #expect(runner.finishedSummary == nil)
    }

    @Test func retriesReserveEachActualRequestAndRespectTheSameGate() async {
        let gate = PipelineRequestGate(limit: 1)
        let outcome = await WikiModelClient.execute(
            .init(id: "retry", kind: .openAICompatible, request: pipelineRequest(), paths: ["A.swift"]),
            onAttempt: { _, _ in try await gate.reserve() }, complete: { _ in "invalid JSON" }, budgets: [100, 200, 300])
        #expect(await gate.sent == 1)
        #expect(outcome.attempts == 1)
        #expect(outcome.error?.contains("预算") == true)
    }

    @Test func authenticationAndCancellationErrorsAreNotRetried() async {
        let outcome = await WikiModelClient.execute(
            .init(id: "unauthorized", kind: .openAICompatible, request: pipelineRequest(), paths: ["A.swift"]),
            complete: { _ in throw AINarrativeError.http(status: 401, message: "not authorized") })
        #expect(outcome.attempts == 1)
        let cancelled = await WikiModelClient.execute(
            .init(id: "cancelled", kind: .openAICompatible, request: pipelineRequest(), paths: ["A.swift"]),
            complete: { _ in throw CancellationError() })
        #expect(cancelled.attempts == 1)
    }

    @Test func aSingleEntrySkipDoesNotWriteOrRetry() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        let gate = PipelineRequestGate(limit: 1)
        let input = try #require(WikiChangeSource.files(root: f.root, paths: ["Sources/A.swift"]))
        let draft = try await WikiCurator.propose(input: input, existing: [], root: f.root,
            suppliedRequest: pipelineRequest(), suppliedKind: .openAICompatible, complete: { _ in
                try await gate.reserve()
                return "{\"action\":\"skip\",\"reason\":\"只有格式变化\"}"
            })
        #expect(draft.action == .skip)
        #expect(await gate.sent == 1)
        let store = WikiStore(root: f.root)
        #expect(throws: (any Error).self) { try store.applyDraft(draft, generatedBy: "test", sources: draft.sources) }
        #expect(store.entries.isEmpty)
    }

    @Test func cancellationInSingleEntryCurationIsPreserved() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        let input = try #require(WikiChangeSource.files(root: f.root, paths: ["Sources/A.swift"]))
        do {
            _ = try await WikiCurator.propose(input: input, existing: [], root: f.root,
                suppliedRequest: pipelineRequest(), suppliedKind: .openAICompatible, complete: { _ in throw CancellationError() })
            Issue.record("取消不能变成成功草稿")
        } catch is CancellationError {}
    }

    @Test func aSourceChangeAfterGenerationAlsoRejectsTheWrite() async throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        let input = try #require(WikiChangeSource.files(root: f.root, paths: [path]))
        let draft = try await WikiCurator.propose(input: input, existing: [], root: f.root,
            suppliedRequest: pipelineRequest(), suppliedKind: .openAICompatible, complete: { _ in
                "{\"action\":\"create\",\"title\":\"代码观察\",\"body\":\"职责待核对\"}"
            })
        try f.write(path, "struct B {}")
        let store = WikiStore(root: f.root)
        #expect(throws: (any Error).self) { try store.applyDraft(draft, generatedBy: "test", sources: draft.sources) }
        #expect(store.entries.isEmpty)
    }

    @Test func aSourceFreeDomainAgreementIsUsedOnlyInThatDomain() throws {
        let f = try PipelineFixture()
        var root = MindNode(id: "system", title: "test", kind: .system)
        var orders = MindNode(id: "domain:orders", title: "订单", kind: .domain)
        orders.parentID = root.id; orders.packages = ["Sources/Orders"]
        var accounts = MindNode(id: "domain:accounts", title: "账户", kind: .domain)
        accounts.parentID = root.id; accounts.packages = ["Sources/Accounts"]
        root.childIDs = [orders.id, accounts.id]
        let graph = MindGraph(nodes: [root, orders, accounts], rootID: root.id)
        let store = WikiStore(root: f.root)
        var rule = try store.create(type: .rule, title: "订单人工约定")
        rule.domains = [orders.id]; rule.body = "重复下单需人工复核，不代表代码已经实现"
        try store.save(rule); try store.confirm(try #require(store.entry(id: rule.id)))
        let entries = store.entries, report = WikiKnowledgeReview.evaluate(entries: entries, root: f.root)
        let orderContext = WikiKnowledgeContext.build(entries: entries, report: report, root: f.root,
            paths: ["Sources/Orders/Create.swift"], graph: graph)
        let accountContext = WikiKnowledgeContext.build(entries: entries, report: report, root: f.root,
            paths: ["Sources/Accounts/Login.swift"], graph: graph)
        #expect(orderContext.items.map(\.id) == [rule.id])
        #expect(accountContext.items.isEmpty)
        #expect(orderContext.text.contains("不是测试通过或业务已实现的证明"))
    }

    @Test func scopeMembershipChangesInvalidateConfirmationAndModuleVersion() throws {
        let f = try PipelineFixture()
        try f.write("Sources/Orders/A.swift", "struct A {}")
        let store = WikiStore(root: f.root)
        var draft = f.draft(); draft.sources = ["Sources/Orders/A.swift"]
        draft.scopePaths = ["Sources/Orders"]
        let entry = try store.applyDraft(draft, generatedBy: "test", sources: draft.sources)
        try store.confirm(entry)
        let confirmed = try #require(store.entry(id: entry.id))
        let scope = try WikiGenerationSources.scopeSnapshot("Sources/Orders", root: f.root)
        try f.write("Sources/Orders/B.swift", "struct B {}")
        #expect(throws: (any Error).self) { try WikiGenerationSources.validateScopes([scope], root: f.root) }
        #expect(WikiKnowledgeReview.evaluate(entries: [confirmed], root: f.root).assessment(for: confirmed).state == .stale)
    }

    @Test func staleModuleNotesAreNeverPromptContext() {
        var job = WikiCurationJob()
        job.note("Old", responsibility: "旧模块职责")
        #expect(job.knownModuleContext(excluding: "Other").isEmpty)
        job.moduleCheckpoints = ["Old": .init(basisDigest: "v1")]
        #expect(job.knownModuleContext(excluding: "Other", versions: ["Old": "v2"]).isEmpty)
        #expect(job.knownModuleContext(excluding: "Other", versions: ["Old": "v1"]).contains("旧模块职责"))
    }

    @Test func checkpointsAndCacheFailuresAreVisibleAndDoNotOverwriteCorruptData() throws {
        let f = try PipelineFixture()
        try f.write(".qiyide/wiki/.insights.json", "broken cache")
        let cache = WikiInsightStore.load(root: f.root)
        #expect(cache.loadIssue != nil)
        #expect(throws: (any Error).self) { try cache.save(root: f.root) }
        #expect(try String(contentsOf: WikiInsightStore.url(root: f.root), encoding: .utf8) == "broken cache")
        try f.write(".qiyide/wiki/.ingest-job.json", "broken checkpoint")
        let job = WikiCurationJob.load(root: f.root)
        #expect(job.status == .failed)
        #expect(job.loadIssue != nil)
        #expect(throws: (any Error).self) { try job.save(root: f.root) }
        #expect(try String(contentsOf: WikiCurationJob.url(root: f.root), encoding: .utf8) == "broken checkpoint")
    }

    @Test func persistenceCannotPretendASaveSucceeded() throws {
        let f = try PipelineFixture()
        try f.write(".qiyide", "a file instead of a directory")
        #expect(throws: (any Error).self) { try WikiInsightStore().save(root: f.root) }
        #expect(throws: (any Error).self) { try WikiCurationJob().save(root: f.root) }
    }

    @Test func aMissingUpdateTargetNeverFallsBackToCreation() throws {
        let f = try PipelineFixture(), store = WikiStore(root: f.root)
        var draft = f.draft(action: .update)
        draft.targetID = "not-an-existing-id"
        #expect(throws: (any Error).self) { try store.applyDraft(draft, generatedBy: "test", sources: []) }
        #expect(store.entries.isEmpty)
    }

    @Test func stableIDTargetsRenamedKnowledgeAndPreservesTheHumanOriginal() throws {
        let f = try PipelineFixture(), store = WikiStore(root: f.root)
        let original = try store.applyDraft(f.draft(), generatedBy: "test", sources: [])
        var renamed = original; renamed.title = "人改过的标题"; try store.save(renamed)
        var draft = f.draft(action: .update); draft.targetID = original.id
        let proposal = try store.applyDraft(draft, generatedBy: "test", sources: [])
        #expect(proposal.proposalFor == original.id)
        #expect(store.entry(id: original.id)?.title == "人改过的标题")
    }

    @Test func replacementClearsObsoleteRelationsAndOldAIAppendices() throws {
        let f = try PipelineFixture(), store = WikiStore(root: f.root)
        var original = f.draft(); original.relations = [.init(kind: "依赖", target: "Old")]
        _ = try store.applyDraft(original, generatedBy: "test", sources: [])
        _ = try store.applyDraft(f.draft(action: .update, body: "旧补充"), generatedBy: "test", sources: [])
        var replacement = f.draft(action: .update, body: "完整新观察"); replacement.mergeMode = .replace
        let updated = try store.applyDraft(replacement, generatedBy: "test", sources: [])
        #expect(updated.body == "完整新观察")
        #expect(updated.relations.isEmpty)
    }

    @Test func selectedFileInputOnlyReferencesActuallyReadFiles() throws {
        let f = try PipelineFixture()
        for name in ["A", "B", "C"] { try f.write("Sources/\(name).swift", "struct \(name) {}") }
        let input = try #require(WikiChangeSource.files(root: f.root,
            paths: ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"], limit: 2))
        #expect(input.files.count == 2)
        #expect(Set(input.sourceSnapshots?.map(\.path) ?? []) == Set(input.files))
        #expect(!input.diff.contains("C.swift"))
    }

    @Test func deterministicProvenanceAndCanonicalBodySurviveRoundTrips() throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        var draft = f.draft(body: "\r\n  代码观察\r\n\r\n"); draft.sources = [path]
        draft.provenance = .init(inputDigest: "input", pipeline: "v3",
            sources: try WikiGenerationSources.capture(paths: [path], root: f.root))
        let store = WikiStore(root: f.root)
        let entry = try store.applyDraft(draft, generatedBy: "test", sources: [path])
        let text = try String(contentsOf: entry.fileURL, encoding: .utf8)
        let parsed = WikiEntry.parse(text: text, fileURL: entry.fileURL)
        #expect(entry.body == parsed.body)
        #expect(WikiKnowledgeReview.contentDigest(entry) == WikiKnowledgeReview.contentDigest(parsed))
        for _ in 0..<20 { #expect(entry.markdown() == parsed.markdown()) }
        try store.confirm(entry)
    }

    @Test func unsafeFrontmatterAndNonCanonicalSourcePathsAreRejected() {
        #expect(WikiCurator.parse("{\"action\":\"create\",\"title\":\"x\\nstatus: confirmed\",\"body\":\"x\"}") == nil)
        let root = FileManager.default.temporaryDirectory
        for path in ["../A.swift", "./A.swift", "A//B.swift", "A\nstatus: confirmed", "A,B.swift"] {
            #expect(WikiSourceInspector.resolvedFile(path, root: root) == nil)
        }
    }
}

extension WikiGenerationContractTests {
    @Test func aChangedHumanContextRejectsAnAlreadyGeneratedDraft() async throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        let store = WikiStore(root: f.root)
        let input = try #require(WikiChangeSource.files(root: f.root, paths: [path]))
        let draft = try await WikiCurator.propose(input: input, existing: [], root: f.root,
            suppliedRequest: pipelineRequest(), suppliedKind: .openAICompatible, complete: { _ in
                "{\"action\":\"create\",\"title\":\"待核对观察\",\"body\":\"假模型的解释\"}"
            })
        var rule = try store.create(type: .rule, title: "新增全局人工约定")
        rule.body = "人工要求必须二次确认"
        try store.save(rule); try store.confirm(try #require(store.entry(id: rule.id)))
        #expect(throws: (any Error).self) { try store.applyDraft(draft, generatedBy: "test", sources: draft.sources) }
        #expect(store.entries.count == 1)
        #expect(store.entries[0].id == rule.id)
    }

    @Test func acceptingAProposalRejectsChangesSinceItsGeneration() async throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        let store = WikiStore(root: f.root)
        var old = f.draft("人工原文", body: "原始规则")
        old.sources = [path]
        let original = try store.applyDraft(old, generatedBy: "test", sources: [path])
        try store.confirm(original)
        let current = try #require(store.entry(id: original.id))
        let input = try #require(WikiChangeSource.files(root: f.root, paths: [path]))
        let id = original.id
        let draft = try await WikiCurator.propose(input: input, existing: store.entries, root: f.root,
            suppliedRequest: pipelineRequest(), suppliedKind: .openAICompatible, complete: { _ in
                "{\"action\":\"update\",\"targetID\":\"\(id)\",\"title\":\"人工原文\",\"body\":\"新增待核对规则\"}"
            })
        let proposal = try store.applyDraft(draft, generatedBy: "test", sources: draft.sources)
        #expect(proposal.proposalFor == original.id)
        try f.write(path, "struct Changed {}")
        #expect(throws: (any Error).self) { try store.acceptProposal(proposal) }
        #expect(store.entry(id: original.id)?.body == current.body)
        #expect(store.entry(id: proposal.id) != nil)
    }

    @Test func concurrentBatchesShareAHardGlobalBudget() async throws {
        let f = try PipelineFixture()
        for name in ["A", "B", "C"] { try f.write("Sources/Orders/Order\(name).swift", "struct Order\(name) {}") }
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard
        options.maxFilesPerBatch = 1; options.concurrency = 3; options.maxCallsPerRun = 2
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.callsUsed == 2)
        #expect(await model.fileRequests.count == 2)
        #expect(await model.modulePrompts.isEmpty)
        #expect(runner.job.status == .paused)
        #expect(store.entries.isEmpty)
    }

    @Test func emptyFilesCanFinishWithoutInventingModuleContent() async throws {
        let f = try PipelineFixture(), path = "Sources/Empty.swift"
        try f.write(path, "")
        let gate = PipelineRequestGate(limit: 1)
        let runner = WikiCurationRunner(request: pipelineRequest(), complete: { _ in
            try await gate.reserve()
            return "{\"files\":[{\"path\":\"Sources/Empty.swift\",\"status\":\"skip\",\"reason\":\"空文件没有可观察的实现\"}]}"
        })
        let store = WikiStore(root: f.root)
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(runner.job.callsUsed == 1)
        #expect(runner.alreadyProcessed == 1)
        #expect(store.entries.isEmpty)
        #expect(WikiInsightStore.load(root: f.root).allInsights.first?.noKnowledgeReason != nil)
        await runner.preview(root: f.root, curatedPaths: [], entries: [])
        #expect(runner.alreadyProcessed == 1)
    }

    @Test func numericActionsAreNotTreatedAsDefaultCreation() async {
        let outcome = await WikiModelClient.executeRelate(
            .init(module: "A", kind: .openAICompatible, request: pipelineRequest()), complete: { _ in
                "{\"action\":42,\"responsibility\":\"不应创建\",\"decisions\":[],\"rules\":[]}"
            })
        #expect(outcome.payload == nil)
        #expect(outcome.error != nil)
    }

    @Test func corruptCheckpointPreventsRequestsAndIsNotResetToIdle() async throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        try f.write(".qiyide/wiki/.ingest-job.json", "corrupted")
        let model = PipelineModel(), runner = runner(model), store = WikiStore(root: f.root)
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.job.status == .failed)
        #expect(runner.errorMessage != nil)
        #expect(await model.fileRequests.isEmpty)
        #expect(try String(contentsOf: WikiCurationJob.url(root: f.root), encoding: .utf8) == "corrupted")
    }

    @Test func aDomainDraftStoresFilesAsEvidenceAndDirectoriesOnlyAsScope() throws {
        let f = try PipelineFixture()
        try f.write("Sources/Orders/A.swift", "struct A {}")
        var root = MindNode(id: "system", title: "system", kind: .system)
        var domain = MindNode(id: "domain:orders", title: "订单域", kind: .domain)
        root.childIDs = [domain.id]; domain.parentID = root.id; domain.packages = ["Sources/Orders"]
        let store = WikiStore(root: f.root)
        _ = try WikiDomainSeeding.seed(graph: .init(nodes: [root, domain], rootID: root.id), into: store)
        let entry = try #require(store.entries.first)
        #expect(entry.scopePaths == ["Sources/Orders"])
        #expect(entry.sources == ["Sources/Orders/A.swift"])
        #expect(entry.isDraft)
        try store.confirm(entry)
        let confirmed = try #require(store.entry(id: entry.id))
        #expect(WikiKnowledgeReview.evaluate(entries: [confirmed], root: f.root).assessment(for: confirmed).state == .current)
    }
}

extension WikiGenerationContractTests {
    @Test func firstConfirmationCannotBlessAChangedSourceWithANewReceipt() throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        var draft = f.draft(); draft.sources = [path]
        draft.provenance = .init(inputDigest: "input", pipeline: "v3",
            sources: try WikiGenerationSources.capture(paths: [path], root: f.root))
        let store = WikiStore(root: f.root)
        let entry = try store.applyDraft(draft, generatedBy: "test", sources: [path])
        try f.write(path, "struct Changed {}")
        #expect(throws: (any Error).self) { try store.confirm(entry) }
        #expect(store.confirm(ids: [entry.id]) == 0)
        #expect(store.entry(id: entry.id)?.isDraft == true)
        #expect(WikiKnowledgeReview.evaluate(entries: [entry], root: f.root).assessment(for: entry).changedSources == [path])
    }

    @Test func aHumanCanReviewAndReconfirmTheirExistingKnowledge() throws {
        let f = try PipelineFixture(), path = "Sources/A.swift"
        try f.write(path, "struct A {}")
        var draft = f.draft(); draft.sources = [path]
        draft.provenance = .init(inputDigest: "input", pipeline: "v3",
            sources: try WikiGenerationSources.capture(paths: [path], root: f.root))
        let store = WikiStore(root: f.root)
        let entry = try store.applyDraft(draft, generatedBy: "test", sources: [path])
        try store.confirm(entry)
        try f.write(path, "struct Changed {}")
        let reviewed = try #require(store.entry(id: entry.id))
        try store.confirm(reviewed)
        let confirmed = try #require(store.entry(id: entry.id))
        #expect(WikiKnowledgeReview.evaluate(entries: [confirmed], root: f.root).assessment(for: confirmed).state == .current)
    }

    @Test func replacementProposalUsesOnlyCurrentSourcesAndArchivesTheOldVersion() throws {
        let f = try PipelineFixture()
        try f.write("Sources/A.swift", "struct A {}")
        try f.write("Sources/B.swift", "struct B {}")
        let store = WikiStore(root: f.root)
        let old = try store.applyDraft(f.draft(body: "旧版包含 A 和 B"), generatedBy: "test", sources: ["Sources/A.swift", "Sources/B.swift"])
        try store.confirm(old)
        var replacement = f.draft(action: .update, body: "现在只包含 A"); replacement.mergeMode = .replace
        let proposal = try store.applyDraft(replacement, generatedBy: "test", sources: ["Sources/A.swift"])
        #expect(proposal.sources == ["Sources/A.swift"])
        #expect(store.entry(id: old.id)?.sources.count == 2)
        let accepted = try store.acceptProposal(proposal)
        #expect(accepted.sources == ["Sources/A.swift"])
        let archive = store.directory.appending(path: "revisions")
        let prior = try #require(try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(old.id + "-") })
        #expect(try String(contentsOf: prior, encoding: .utf8).contains("Sources/B.swift"))
    }
}
