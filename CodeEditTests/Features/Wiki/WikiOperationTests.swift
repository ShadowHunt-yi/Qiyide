import Foundation
import Testing
@testable import CodeEdit

private final class ArchitectureFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "qiyide-operation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func source() throws {
        try write("Sources/API/Entry.swift", "struct EntryPoint { var value = DomainValue() }")
        try write("Sources/Domain/Value.swift", "struct DomainValue { var amount = 1 }")
    }
}

private enum OperationTestError: Error { case failedSave, timeout }

private final class WorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didFinish = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return didStart }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    func start() { lock.lock(); didStart = true; lock.unlock() }
    func finish() { lock.lock(); didFinish = true; lock.unlock() }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    throw OperationTestError.timeout
}

@MainActor
private func fakeArchitecture() -> WikiArchitectureBuilder.Result {
    var architecture = WikiArchitecture()
    architecture.domains = [.init(name: "示例域", layer: .domain, purpose: "测试", modules: ["Domain"], keyRules: [])]
    architecture.moduleCount = 1
    architecture.generation = .init(method: .staticAnalysis, inputDigest: "fixture")
    return .init(architecture: architecture, domainEdges: [], moduleCount: 1, inputDigest: "fixture")
}

@Suite(.serialized) @MainActor struct WikiOperationTests {
    @Test func unknownProgressHasNoInventedPercentage() {
        var snapshot = WikiOperationSnapshot(id: UUID(), status: .running)
        snapshot.receive(.init(.scan, "已发现 100 个文件", completed: 100))
        #expect(snapshot.progress.fraction == nil)
        snapshot.receive(.init(.dependencies, "文件证据", completed: 10, total: 20))
        #expect(snapshot.progress.fraction == 0.5)
        snapshot.receive(.init(.scan, "迟到的扫描回调", completed: 120))
        #expect(snapshot.progress.stage == .dependencies)
        #expect(snapshot.progress.completed == 10)
        snapshot.status = .cancelling
        snapshot.receive(.init(.save, "不应提交"))
        #expect(snapshot.progress.stage == .dependencies)
        #expect(!snapshot.canCancel)
    }

    @Test func terminalElapsedTimeDoesNotKeepIncreasing() {
        let start = Date(timeIntervalSince1970: 100)
        let snapshot = WikiOperationSnapshot(status: .completed, startedAt: start, finishedAt: start.addingTimeInterval(8))
        #expect(snapshot.elapsed(at: start.addingTimeInterval(99)) == 8)
    }

    @Test func staticGenerationNeedsNeitherAIKnowledgeNorDomainModel() async throws {
        let f = try ArchitectureFixture()
        try f.source()
        let result = try await WikiArchitectureBuilder.build(root: f.root, mode: .staticOnly)
        #expect(!result.architecture.isEmpty)
        #expect(result.architecture.generation?.method == .staticAnalysis)
        #expect(result.architecture.generatedBy == "静态分析")
        #expect(result.architecture.moduleCount == result.moduleCount)
        #expect(!result.inputDigest.isEmpty)
        #expect(WikiArchitecture.load(root: f.root).generation?.inputDigest == result.inputDigest)
        #expect(WikiStore(root: f.root).entries.isEmpty)
        #expect(DomainModelStore(root: f.root).graph.isEmpty)
    }

    @Test func inputDigestIncludesContentAdditionsAndRemovals() throws {
        let f = try ArchitectureFixture()
        try f.source()
        let initial = try WikiArchitectureInput.capture(root: f.root).digest
        try f.write("Sources/Domain/Value.swift", "struct DomainValue { var amount = 2 }")
        let changed = try WikiArchitectureInput.capture(root: f.root).digest
        #expect(changed != initial)
        try f.write("Sources/New.swift", "struct NewSource {}")
        let added = try WikiArchitectureInput.capture(root: f.root).digest
        #expect(added != changed)
        try FileManager.default.removeItem(at: f.root.appending(path: "Sources/New.swift"))
        #expect(try WikiArchitectureInput.capture(root: f.root).digest == changed)
        try f.write(".qiyide/wiki/ignored.swift", "this is not project code")
        #expect(try WikiArchitectureInput.capture(root: f.root).digest == changed)
    }

    @Test func changedSourcesRejectCandidateAndKeepOldFile() async throws {
        let f = try ArchitectureFixture()
        try f.source()
        let old = try await WikiArchitectureBuilder.build(root: f.root, mode: .staticOnly)
        let oldData = try Data(contentsOf: WikiArchitecture.url(root: f.root))
        let candidate = try await WikiArchitectureBuilder.prepare(root: f.root, mode: .staticOnly, onProgress: { _ in })
        try f.write("Sources/New.swift", "struct AddedDuringGeneration {}")
        do {
            try await WikiArchitectureBuilder.commit(candidate, root: f.root, onProgress: { _ in })
            Issue.record("Changed sources must not be saved")
        } catch let error as WikiArchitectureBuildError {
            guard case .changedInput = error else { throw error }
        }
        #expect(try Data(contentsOf: WikiArchitecture.url(root: f.root)) == oldData)
        #expect(WikiArchitecture.load(root: f.root).generation?.inputDigest == old.inputDigest)
    }

    @Test func encodeFailureDoesNotOverwriteOldArchitecture() throws {
        let f = try ArchitectureFixture()
        let initial = fakeArchitecture().architecture
        try initial.save(root: f.root)
        let before = try Data(contentsOf: WikiArchitecture.url(root: f.root))
        var invalid = initial
        invalid.generatedAt = .nan
        #expect(throws: (any Error).self) { try invalid.save(root: f.root) }
        #expect(try Data(contentsOf: WikiArchitecture.url(root: f.root)) == before)
    }

    @Test func filesystemFailureIsNotSilentlyAccepted() throws {
        let f = try ArchitectureFixture()
        try f.write(".qiyide", "not a directory")
        #expect(throws: (any Error).self) { try fakeArchitecture().architecture.save(root: f.root) }
        #expect(!FileManager.default.fileExists(atPath: WikiArchitecture.url(root: f.root).path))
    }

    @Test func oldArchitectureSchemaRemainsReadable() throws {
        let f = try ArchitectureFixture()
        var old = fakeArchitecture().architecture
        old.generation = nil
        try old.save(root: f.root)
        let loaded = WikiArchitecture.load(root: f.root)
        #expect(loaded.domains.count == 1)
        #expect(loaded.generation == nil)
    }

    @Test func invalidModelStructureIsNotReportedAsSuccessfulStaticFallback() throws {
        let groups: [WikiArchitecturePlanner.CandidateGroup] = [
            .init(key: "Domain", modules: ["Domain"], fileCount: 1, fanIn: 0, fanOut: 0, edges: [])
        ]
        for object: [String: Any] in [["unexpected": true], ["domains": []], ["domains": [["name": "编造域", "groups": ["Missing"]]]]] {
            #expect(throws: (any Error).self) { try WikiArchitecturePlanner.assemble(object: object, groups: groups) }
        }
        let duplicate: [String: Any] = ["domains": [
            ["name": "甲", "groups": ["Domain"]], ["name": "乙", "groups": ["Domain"]]
        ]]
        #expect(throws: (any Error).self) { try WikiArchitecturePlanner.assemble(object: duplicate, groups: groups) }
    }

    @Test func missingModelGroupsBecomeVisibleWarnings() throws {
        let groups: [WikiArchitecturePlanner.CandidateGroup] = [
            .init(key: "API", modules: ["API"], fileCount: 1, fanIn: 0, fanOut: 0, edges: []),
            .init(key: "Domain", modules: ["Domain"], fileCount: 1, fanIn: 0, fanOut: 0, edges: [])
        ]
        let result = try WikiArchitecturePlanner.assemble(object: ["domains": [["name": "入口", "groups": ["API"]]]], groups: groups)
        #expect(!result.generation!.warnings.isEmpty)
        #expect(result.domainOfModule.count == 2)
        #expect(result.domains.contains { $0.name == "未覆盖模块" })
    }

    @Test func sameProjectReusesRunnerButSameNamedProjectsDoNot() throws {
        let a = try ArchitectureFixture()
        let b = try ArchitectureFixture()
        let x = a.root.appending(path: "same")
        let y = b.root.appending(path: "same")
        let first = WikiArchitectureRunner.forProject(x)
        #expect(first === WikiArchitectureRunner.forProject(x))
        #expect(first !== WikiArchitectureRunner.forProject(y))
    }

    @Test func blockedAIHasExplicitStaticAlternativeWithoutDoingWork() async throws {
        let f = try ArchitectureFixture()
        var preparations = 0
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false, aiReady: { false }, blockedReason: { "没有模型" }, prepare: { _, _, _ in
            preparations += 1
            return fakeArchitecture()
        }, commit: { _, _, _ in })
        runner.start()
        #expect(runner.snapshot.status == .blocked)
        #expect(preparations == 0)
        #expect(runner.snapshot.outcome?.contains("静态分析") == true)
        runner.start(mode: .staticOnly)
        try await eventually { runner.snapshot.status == .completed }
        #expect(preparations == 1)
    }

    @Test func duplicateStartAndCancelCannotCreateTwoWorkers() async throws {
        let f = try ArchitectureFixture()
        var preparations = 0
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false, prepare: { _, _, progress in
            preparations += 1
            progress(.init(.scan, "测试扫描"))
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return fakeArchitecture()
        }, commit: { _, _, _ in Issue.record("Cancelled task must not commit") })
        #expect(runner.start(mode: .staticOnly))
        let id = runner.snapshot.id
        #expect(!runner.start(mode: .staticOnly))
        #expect(runner.snapshot.id == id)
        try await eventually { preparations == 1 }
        runner.cancel()
        #expect(runner.snapshot.status == .cancelling)
        #expect(!runner.start(mode: .staticOnly))
        try await eventually { runner.snapshot.status == .cancelled }
        #expect(runner.result == nil)
        #expect(preparations == 1)
    }

    @Test func cancellationRejectsLateCallbacksAndLateCandidate() async throws {
        let f = try ArchitectureFixture()
        var started = false
        var commits = 0
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false, prepare: { _, _, progress in
            started = true
            progress(.init(.scan, "扫描"))
            // 模拟底层晚返回，故意吞掉 sleep 的取消。
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            progress(.init(.save, "迟到，不应显示"))
            return fakeArchitecture()
        }, commit: { _, _, _ in commits += 1 })
        runner.start(mode: .staticOnly)
        try await eventually { started }
        runner.cancel()
        try await eventually { runner.snapshot.status == .cancelled }
        #expect(commits == 0)
        #expect(runner.snapshot.progress.stage == .scan)
    }

    @Test func failedSaveRetriesCandidateWithoutRegenerating() async throws {
        let f = try ArchitectureFixture()
        var preparations = 0
        var commits = 0
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false, prepare: { _, _, _ in
            preparations += 1
            return fakeArchitecture()
        }, commit: { _, _, progress in
            commits += 1
            progress(.init(.save, "保存"))
            if commits == 1 { throw OperationTestError.failedSave }
        })
        runner.start(mode: .staticOnly)
        try await eventually { runner.snapshot.status == .failed }
        #expect(runner.canRetrySave)
        #expect(runner.result == nil)
        runner.retry()
        try await eventually { runner.snapshot.status == .completed }
        #expect(preparations == 1)
        #expect(commits == 2)
        #expect(!runner.canRetrySave)
        #expect(runner.result?.moduleCount == 1)
    }

    @Test func detachedWorkReceivesCancellationAndExitsBeforeParentCompletes() async throws {
        let probe = WorkerProbe()
        let task = Task {
            try await WikiBackgroundWork.run {
                probe.start()
                defer { probe.finish() }
                let deadline = Date().addingTimeInterval(3)
                while !Task.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
                try Task.checkCancellation()
                return 0
            }
        }
        try await eventually { probe.started }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Detached worker must throw cancellation")
        } catch is CancellationError {}
        #expect(probe.finished)
    }
    @Test func curationPreviewCountsOnlyActualKnowledgeCoverage() async throws {
        let f = try ArchitectureFixture()
        try f.source()
        let runner = WikiCurationRunner()
        await runner.preview(root: f.root, curatedPaths: [])
        #expect(runner.totalCandidates == 2)
        #expect(runner.alreadyProcessed == 0)
        #expect(runner.progress == 0)
        #expect(runner.stageProgress == nil)
        #expect(!runner.isPreviewing)
        #expect(!runner.isRunning)
    }

    @Test func cancelledPreviewDoesNotPublishAnotherProject() async throws {
        let f = try ArchitectureFixture()
        try f.source()
        let runner = WikiCurationRunner()
        let task = Task { await runner.preview(root: f.root, curatedPaths: []) }
        task.cancel()
        await task.value
        #expect(runner.root == nil)
        #expect(!runner.isPreviewing)
    }

    @Test func shortAtomicSaveCannotBeMisreportedAsCancelled() async throws {
        let f = try ArchitectureFixture()
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false,
            prepare: { _, _, _ in fakeArchitecture() },
            commit: { _, _, progress in
                progress(.init(.save, "原子保存"))
                try await Task.sleep(nanoseconds: 30_000_000)
            })
        runner.start(mode: .staticOnly)
        try await eventually { runner.snapshot.progress.stage == .save }
        #expect(!runner.snapshot.canCancel)
        runner.cancel()
        #expect(runner.snapshot.status == .running)
        try await eventually { runner.snapshot.status == .completed }
        #expect(runner.result != nil)
    }

    @Test func sourceConflictDiscardsCandidateInsteadOfRepeatingStaleSave() async throws {
        let f = try ArchitectureFixture()
        var preparations = 0
        let runner = WikiArchitectureRunner(root: f.root, reportsActivity: false,
            prepare: { _, _, _ in preparations += 1; return fakeArchitecture() },
            commit: { _, _, _ in throw WikiArchitectureBuildError.changedInput })
        runner.start(mode: .staticOnly)
        try await eventually { runner.snapshot.status == .failed }
        #expect(!runner.canRetrySave)
        runner.retry()
        try await eventually { runner.snapshot.status == .failed }
        #expect(preparations == 2)
    }

    @Test func unreadableArchitectureIsNotPresentedAsAnEmptyFirstRun() throws {
        let f = try ArchitectureFixture()
        try f.source()
        try fakeArchitecture().architecture.save(root: f.root)
        let store = WikiStore(root: f.root)
        store.reloadNow()
        #expect(store.architecture.domains.count == 1)
        try f.write(".qiyide/wiki/architecture.json", "not valid JSON")
        store.reloadNow()
        #expect(store.architectureReadError != nil)
        #expect(store.architecture.domains.count == 1)
        #expect(store.entries.isEmpty)
    }

}

#if canImport(CodeEditKit)
@Suite(.serialized) @MainActor struct WikiAppInteractionTests {
    @Test func taskResumeIsAvailableOnlyWhenStopped() {
        #expect(CETaskStatus.stopped.canResume)
        #expect(!CETaskStatus.running.canResume)
        #expect(!CETaskStatus.finished.canResume)
        #expect(CETaskStatus.running.canSuspend)
        #expect(!CETaskStatus.stopped.canSuspend)
    }

    @Test func activityCanSwitchFromMeasuredToIndeterminateProgress() async throws {
        let f = try ArchitectureFixture()
        let handler = TaskNotificationHandler(workspaceURL: f.root)
        let id = UUID().uuidString
        TaskNotificationHandler.postTask(toWorkspace: f.root, action: .create,
            model: .init(id: id, title: "当前阶段", message: nil, percentage: 0.5, isLoading: true))
        try await eventually { handler.notifications.count == 1 }
        #expect(handler.notifications[0].percentage == 0.5)
        TaskNotificationHandler.postTask(toWorkspace: f.root, action: .update,
            model: .init(id: id, title: "等待模型", message: nil, percentage: nil, isLoading: true))
        try await eventually { handler.notifications[0].title == "等待模型" }
        #expect(handler.notifications[0].percentage == nil)
    }

    @Test func activityDoesNotLeakBetweenProjects() async throws {
        let a = try ArchitectureFixture()
        let b = try ArchitectureFixture()
        let handler = TaskNotificationHandler(workspaceURL: a.root)
        NotificationCenter.default.post(name: .taskNotification, object: nil, userInfo: [
            "id": UUID().uuidString, "action": "create", "workspace": b.root,
            "title": "另一个项目"
        ])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(handler.notifications.isEmpty)
    }
}
#endif
