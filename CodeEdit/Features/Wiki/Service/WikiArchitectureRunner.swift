//
//  WikiArchitectureRunner.swift
//  CodeEdit
//
//  每个项目一份架构任务。关闭窗口只结束订阅，不能丢掉进度或重复启动任务。
//

import Combine
import Foundation

@MainActor
final class WikiArchitectureRunner: ObservableObject {
    typealias Prepare = @MainActor (
        URL, WikiArchitectureMode, @escaping WikiArchitectureBuilder.ProgressHandler
    ) async throws -> WikiArchitectureBuilder.Result
    typealias Commit = @MainActor (
        WikiArchitectureBuilder.Result, URL, @escaping WikiArchitectureBuilder.ProgressHandler
    ) async throws -> Void

    private static var projects: [String: WikiArchitectureRunner] = [:]

    static func forProject(_ root: URL) -> WikiArchitectureRunner {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let runner = projects[key] { return runner }
        let runner = WikiArchitectureRunner(root: root)
        projects[key] = runner
        return runner
    }

    @Published private(set) var snapshot = WikiOperationSnapshot()
    @Published private(set) var completionID: UUID?
    @Published private(set) var result: WikiArchitectureBuilder.Result?
    let root: URL
    private var task: Task<Void, Never>?
    private var candidate: WikiArchitectureBuilder.Result?
    private let prepare: Prepare
    private let commit: Commit
    private let aiReady: @MainActor () -> Bool
    private let blockedReason: @MainActor () -> String
    private let reportsActivity: Bool

    init(
        root: URL,
        reportsActivity: Bool = true,
        aiReady: @escaping @MainActor () -> Bool = { AINarrativeStore.shared.isReady },
        blockedReason: @escaping @MainActor () -> String = { AINarrativeStore.shared.blockedReason ?? "模型未配置" },
        prepare: @escaping Prepare = { root, mode, progress in
            try await WikiArchitectureBuilder.prepare(root: root, mode: mode, onProgress: progress)
        },
        commit: @escaping Commit = { result, root, progress in
            try await WikiArchitectureBuilder.commit(result, root: root, onProgress: progress)
        }
    ) {
        self.root = root.standardizedFileURL
        self.aiReady = aiReady
        self.blockedReason = blockedReason
        self.prepare = prepare
        self.commit = commit
        self.reportsActivity = reportsActivity
    }

    var canRetrySave: Bool { candidate != nil && snapshot.status == .failed }

    /// 返回 false 表示已有任务在运行；调用方应展示既有任务，而非无反馈地拒绝。
    @discardableResult
    func start(mode: WikiArchitectureMode = .automatic) -> Bool {
        guard task == nil else { return false }
        candidate = nil
        if mode == .automatic, !aiReady() {
            replaceSnapshot(mode: mode)
            snapshot.status = .blocked
            snapshot.outcome = blockedReason() + "。可以先使用静态分析，不需要创建知识条目。"
            publishActivity(action: "create")
            return true
        }
        launch(mode: mode, retryCandidate: nil)
        return true
    }

    func retry() {
        guard task == nil else { return }
        if let candidate {
            launch(mode: snapshot.mode, retryCandidate: candidate)
        } else {
            start(mode: snapshot.mode)
        }
    }

    func cancel() {
        guard snapshot.canCancel, let task else { return }
        snapshot.status = .cancelling
        snapshot.outcome = "等待请求与后台工作退出；退出前不会启动新的冲突任务。"
        publishActivity(action: "update")
        task.cancel()
    }

    private func replaceSnapshot(mode: WikiArchitectureMode) {
        if let previous = snapshot.id { publishDelete(id: previous) }
        snapshot = WikiOperationSnapshot(id: UUID(), mode: mode)
    }

    private func launch(mode: WikiArchitectureMode, retryCandidate: WikiArchitectureBuilder.Result?) {
        replaceSnapshot(mode: mode)
        snapshot.status = .running
        snapshot.startedAt = Date()
        snapshot.receive(.init(.prepare, retryCandidate == nil ? "检查项目与执行方式" : "重新核对候选来源，然后重试保存"))
        publishActivity(action: "create")
        guard let id = snapshot.id else { return }
        let progress: WikiArchitectureBuilder.ProgressHandler = { [weak self] update in
            guard let self, self.snapshot.id == id else { return }
            self.snapshot.receive(update)
            self.publishActivity(action: "update")
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                // 不释放 task 就不能启动下一份；只有底层真正结束才退出 cancelling。
                if self.snapshot.id == id { self.task = nil }
            }
            do {
                let built: WikiArchitectureBuilder.Result
                if let retryCandidate {
                    built = retryCandidate
                } else {
                    built = try await self.prepare(self.root, mode, progress)
                }
                try Task.checkCancellation()
                self.candidate = built
                try await self.commit(built, self.root, progress)
                guard self.snapshot.id == id else { return }
                self.result = built
                self.candidate = nil
                self.snapshot.status = .completed
                self.snapshot.finishedAt = Date()
                self.snapshot.warnings = built.architecture.generation?.warnings ?? []
                let method = built.architecture.generation?.method == .staticAnalysis ? "静态分析" : "AI 草稿"
                self.snapshot.outcome = "\(built.architecture.domains.count) 个域 · \(built.moduleCount) 个模块 · \(method)；已保存，不代表业务已验证。"
                if !self.snapshot.steps.isEmpty { self.snapshot.steps[self.snapshot.steps.count - 1].finished = true }
                self.completionID = id
            } catch {
                guard self.snapshot.id == id else { return }
                self.snapshot.finishedAt = Date()
                if Task.isCancelled || error is CancellationError || (error as? AINarrativeError) == .cancelled {
                    self.candidate = nil
                    self.snapshot.status = .cancelled
                    self.snapshot.outcome = "已取消，未替换原架构；已有结果仍可查看。"
                } else {
                    if error is WikiArchitectureBuildError { self.candidate = nil }
                    self.snapshot.status = .failed
                    self.snapshot.outcome = self.candidate == nil
                        ? error.localizedDescription
                        : "候选已生成，但未保存：\(error.localizedDescription)"
                }
            }
            self.publishActivity(action: "update")
        }
    }

    /// 适配现有 ActivityViewer，工作区订阅与知识库窗口使用同一个任务身份。
    private func publishActivity(action: String) {
        guard reportsActivity, let id = snapshot.id else { return }
        var info: [String: Any] = [
            "id": id.uuidString,
            "action": action,
            "workspace": root,
            "title": snapshot.title,
            "message": snapshot.outcome ?? snapshot.progress.detail,
            "isLoading": snapshot.isActive,
            "percentage": NSNull()
        ]
        // 这是当前阶段的真实计数，不是整条生成链路的百分比。
        if snapshot.isActive, let fraction = snapshot.progress.fraction { info["percentage"] = fraction }
        NotificationCenter.default.post(name: Notification.Name("taskNotification"), object: nil, userInfo: info)
    }

    private func publishDelete(id: UUID) {
        guard reportsActivity else { return }
        NotificationCenter.default.post(name: Notification.Name("taskNotification"), object: nil, userInfo: [
            "id": id.uuidString, "action": "delete", "workspace": root
        ])
    }
}
