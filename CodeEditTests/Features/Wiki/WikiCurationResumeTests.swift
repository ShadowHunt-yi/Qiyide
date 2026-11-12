import Foundation
import Testing
@testable import CodeEdit

private final class ResumeFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "qiyide-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("Sources/Order.swift", "struct Order {}")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor ResumeModel {
    var requests: [String] = []
    func complete(_ request: AINarrativeRequest) throws -> String {
        requests.append(request.systemPrompt.contains("\"files\"") ? "files" : "module")
        if request.systemPrompt.contains("\"files\"") {
            let paths = request.userPrompt.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("=== "), line.hasSuffix(" ===") else { return nil }
                return String(line.dropFirst(4).dropLast(4))
            }
            let files = paths.map { ["path": $0, "purpose": "当前代码观察", "keyPoints": []] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["files": files]), as: UTF8.self)
        }
        return "{\"action\":\"create\",\"responsibility\":\"完整模块的观察，不证明业务意图\",\"decisions\":[],\"rules\":[]}"
    }
}

@Suite(.serialized) @MainActor struct WikiCurationResumeTests {
    private func runner(_ model: ResumeModel) -> WikiCurationRunner {
        let request = AINarrativeRequest(baseURL: "https://local-test.invalid/v1", model: "resume-test", apiKey: "",
            systemPrompt: "test", userPrompt: "", maxTokens: 2_048, temperature: 0.1, timeout: 5)
        return .init(request: request, complete: { try await model.complete($0) })
    }
    private func finish(_ runner: WikiCurationRunner) async throws {
        for _ in 0..<400 {
            if !runner.isRunning { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        runner.stop()
        throw WikiGenerationError.invalidOutput("隔离续跑没有结束")
    }

    @Test func historicalRequestsNeverConsumeTheNewRunBudget() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        try old.save(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 2
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(await model.requests == ["files", "module"])
        #expect(runner.job.status == .finished)
        #expect(runner.job.callsUsed == 2364)
        #expect(store.entries.count == 1)
    }

    @Test func resumeAfterExhaustionUsesSavedFileObservationsAndANewBudget() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.status == .paused)
        #expect(runner.job.callsUsed == 1)
        #expect(WikiInsightStore.load(root: f.root).count == 1)
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(await model.requests == ["files", "module"])
        #expect(runner.job.callsUsed == 2)
        #expect(runner.job.status == .finished)
        #expect(store.entries.count == 1)
    }

    @Test func previewDoesNotReplaceLegacySavedCountersWithZero() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model)
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        old.filesTotal = 2654; old.filesDone = 2627
        try old.save(root: f.root)
        let before = try Data(contentsOf: WikiCurationJob.url(root: f.root))
        await runner.preview(root: f.root, curatedPaths: [], entries: [])
        #expect(runner.job.filesDone == 2627)
        #expect(runner.job.filesTotal == 2654)
        #expect(runner.job.callsUsed == 2362)
        #expect(try Data(contentsOf: WikiCurationJob.url(root: f.root)) == before)
    }
}

private final class ResumeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = 1_794_500_000.0
    func date() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) }
    func advance(_ amount: Double) { lock.lock(); seconds += amount; lock.unlock() }
}

extension WikiCurationResumeTests {
    @Test func budgetPauseShowsPersistedUnderstandingEvenWithoutAModuleOutput() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.coverage.totalFiles == 1)
        #expect(runner.coverage.understoodFiles == 1)
        #expect(runner.coverage.outputFiles == 0)
        #expect(runner.coverage.understandingProgress == 1)
        #expect(runner.coverage.outputProgress == 0)
        #expect(runner.job.lastRun?.requestsUsed == 1)
        #expect(runner.job.lastRun?.remainingRequests == 0)
        #expect(runner.job.lastRun?.pauseReason == .requestBudget)
        #expect(runner.startButtonTitle == "继续建档（新额度）")
        #expect(runner.detail.contains("历史累计不占新额度"))
        #expect(runner.finishedSummary == nil)
        let reopened = self.runner(model)
        await reopened.preview(root: f.root, entries: [])
        #expect(reopened.coverage.understoodFiles == 1)
        #expect(reopened.coverage.outputFiles == 0)
        #expect(reopened.job.lastRun?.requestsUsed == 1)
        #expect(reopened.startButtonTitle == "继续建档（新额度）")
        #expect(await model.requests.count == 1)
    }

    @Test func legacyObservationAndLegacyProgressAreShownWithoutInventingFreshness() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model)
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        old.filesDone = 2627; old.filesTotal = 2654
        try old.save(root: f.root)
        let legacy = RepoFileInsight(path: "Sources/Order.swift", purpose: "旧模型观察，不可事后背书", keyPoints: [])
        try f.write(".qiyide/wiki/.insights.json", String(decoding: try JSONEncoder().encode(["records": [legacy.path: legacy]]), as: UTF8.self))
        let jobBytes = try Data(contentsOf: WikiCurationJob.url(root: f.root))
        let cacheBytes = try Data(contentsOf: WikiInsightStore.url(root: f.root))
        await runner.preview(root: f.root, entries: [])
        #expect(runner.coverage.legacyObservations == 1)
        #expect(runner.coverage.understoodFiles == 0)
        #expect(runner.coverage.outputFiles == 0)
        #expect(runner.job.legacyProgress?.filesDone == 2627)
        #expect(runner.job.legacyProgress?.filesTotal == 2654)
        #expect(runner.job.callsUsed == 2362)
        #expect(try Data(contentsOf: WikiCurationJob.url(root: f.root)) == jobBytes)
        #expect(try Data(contentsOf: WikiInsightStore.url(root: f.root)) == cacheBytes)
        #expect(await model.requests.isEmpty)
    }

    @Test func replacingAnUnversionedObservationPreservesItsHistoryWithoutTrustingIt() throws {
        let f = try ResumeFixture(), path = "Sources/Order.swift"
        let legacy = RepoFileInsight(path: path, purpose: "付款后留下的旧观察", keyPoints: [])
        try f.write(".qiyide/wiki/.insights.json", String(decoding: try JSONEncoder().encode(["records": [path: legacy]]), as: UTF8.self))
        var cache = WikiInsightStore.load(root: f.root)
        let source = try WikiGenerationSources.read(path: path, root: f.root).source
        #expect(cache.insight(for: source, pipelineKey: "new") == nil)
        try cache.record(.init(path: path, purpose: "新版理解", keyPoints: []), source: source, pipelineKey: "new", model: "test")
        try cache.save(root: f.root)
        let loaded = WikiInsightStore.load(root: f.root)
        #expect(loaded.insight(for: source, pipelineKey: "new")?.purpose == "新版理解")
        #expect(loaded.legacyRecords?[path]?.purpose == "付款后留下的旧观察")
        #expect(loaded.legacyRecords?[path]?.sourceDigest == nil)
        #expect(loaded.archivedLegacyCount == 1)
    }

    @Test func legacySnapshotSurvivesRunningAndReopeningTheUpgradedJob() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        old.filesTotal = 2654; old.filesDone = 2627; try old.save(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        let saved = WikiCurationJob.load(root: f.root)
        #expect(saved.callsUsed == 2363)
        #expect(saved.lastRun?.requestsUsed == 1)
        #expect(saved.legacyProgress?.filesDone == 2627)
        #expect(saved.legacyProgress?.filesTotal == 2654)
        #expect(saved.filesDone == 0)
        #expect(saved.filesTotal == 1)
        let newRunner = self.runner(model)
        newRunner.start(root: f.root, store: store, options: options)
        try await finish(newRunner)
        #expect(newRunner.job.callsUsed == 2364)
        #expect(newRunner.job.legacyProgress?.filesDone == 2627)
        #expect(newRunner.job.status == .finished)
    }

    @Test func separateExplicitRunsHaveSeparateIDsAndPreserveTotalCost() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        let firstID = runner.job.lastRun?.id
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.lastRun?.id != firstID)
        #expect(runner.job.lastRun?.requestsUsed == 1)
        #expect(runner.job.callsUsed == 2)
        let count = await model.requests.count
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(await model.requests.count == count)
        #expect(!runner.isRunning)
    }

    @Test func aTimeBudgetPauseCanResumeWithANewClockWindowAndSavedObservations() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), clock = ResumeClock(), store = WikiStore(root: f.root)
        let request = AINarrativeRequest(baseURL: "https://local-test.invalid/v1", model: "time-test", apiKey: "",
            systemPrompt: "test", userPrompt: "", maxTokens: 2_048, temperature: 0.1, timeout: 5)
        let runner = WikiCurationRunner(request: request, complete: { request in
            let result = try await model.complete(request)
            if request.systemPrompt.contains("\"files\"") { clock.advance(61) }
            return result
        }, now: { clock.date() })
        var options = WikiCurationRunner.Options.standard; options.maxMinutes = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.lastRun?.pauseReason == .timeBudget)
        #expect(runner.job.callsUsed == 1)
        #expect(runner.coverage.understoodFiles == 1)
        #expect(runner.startButtonTitle == "继续建档（新额度）")
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(runner.job.callsUsed == 2)
        #expect(runner.job.lastRun?.requestsUsed == 1)
    }

    @Test func outputCoverageAndSavedEntriesRemainVisibleAfterReopening() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        runner.start(root: f.root, store: store)
        try await finish(runner)
        #expect(runner.coverage.understoodFiles == 1)
        #expect(runner.coverage.outputFiles == 1)
        #expect(runner.coverage.savedEntries == 1)
        let reopened = self.runner(model)
        let saved = WikiStore(root: f.root); saved.reloadNow()
        await reopened.preview(root: f.root, entries: saved.entries)
        #expect(reopened.coverage.outputFiles == 1)
        #expect(reopened.coverage.understoodFiles == 1)
        #expect(reopened.coverage.savedEntries == 1)
    }

    @Test func normalizingOptionsRetainsFiniteLimitsAndDoesNotUseHistoricalCost() {
        var options = WikiCurationRunner.Options.standard
        options.maxCallsPerRun = 0; options.maxMinutes = 0; options.concurrency = 99
        #expect(options.normalized().maxCallsPerRun == 1)
        #expect(options.normalized().maxMinutes == 1)
        #expect(options.normalized().concurrency == 6)
        var old = WikiCurationJob(); old.callsUsed = 2362
        old.beginRun(requestLimit: 800, minutesLimit: 40, at: Date())
        #expect(old.lastRun?.requestsUsed == 0)
        #expect(old.lastRun?.remainingRequests == 800)
        #expect(old.callsUsed == 2362)
    }
}

extension WikiCurationResumeTests {
    @Test func reachingTheBudgetIsNormalPauseNotAModelFailure() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 1
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.status == .paused)
        #expect(runner.job.lastRun?.pauseReason == .requestBudget)
        #expect(runner.job.failures.isEmpty)
        #expect(runner.errorMessage == nil)
        #expect(!runner.log.contains { $0.contains("模块未写入") })
    }

    @Test func concurrentBatchesDoNotSpendMoreThanEachRunsQuota() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        for name in ["Create", "Cancel", "Update"] { try f.write("Sources/Order\(name).swift", "struct Order\(name) {}") }
        var options = WikiCurationRunner.Options.standard
        options.maxCallsPerRun = 2; options.maxFilesPerBatch = 1; options.concurrency = 3
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.callsUsed == 2)
        #expect(runner.job.lastRun?.requestsUsed == 2)
        #expect(runner.coverage.understoodFiles == 2)
        #expect(runner.coverage.outputFiles == 0)
        #expect(runner.job.failures.isEmpty)
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.callsUsed == 4)
        #expect(runner.job.lastRun?.requestsUsed == 2)
        #expect(runner.coverage.understoodFiles == 4)
        #expect(await model.requests.filter { $0 == "files" }.count == 4)
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        #expect(runner.job.status == .finished)
        #expect(runner.job.callsUsed == 5)
        #expect(runner.job.lastRun?.requestsUsed == 1)
        #expect(runner.coverage.outputFiles == 4)
    }
}

extension WikiCurationResumeTests {
    @Test func upgradingAndResegmentingPreservesUnversionedModuleNotesWithoutUsingThem() async throws {
        let f = try ResumeFixture(), model = ResumeModel(), runner = runner(model), store = WikiStore(root: f.root)
        var old = WikiCurationJob(); old.status = .paused; old.round = 50; old.callsUsed = 2362
        old.filesDone = 2627; old.filesTotal = 2654
        old.moduleNotes = ["OldModuleNoLongerInSegmentation": "旧模块职责，缺少输入版本"]
        try old.save(root: f.root)
        var options = WikiCurationRunner.Options.standard; options.maxCallsPerRun = 2
        runner.start(root: f.root, store: store, options: options)
        try await finish(runner)
        let saved = WikiCurationJob.load(root: f.root)
        #expect(saved.legacyModuleNotes?["OldModuleNoLongerInSegmentation"] == "旧模块职责，缺少输入版本")
        #expect(saved.moduleNotes["OldModuleNoLongerInSegmentation"] == nil)
        #expect(!saved.knownModuleContext(excluding: "Other").contains("OldModuleNoLongerInSegmentation"))
        #expect(saved.callsUsed == 2364)
        #expect(saved.status == .finished)
    }
}
