//
//  AIReviewService.swift
//  CodeEdit
//
//  AI 改动审查的数据服务：拉取提交 → 分析 → 提供导出与审阅状态。
//

import AppKit
import Combine
import Foundation

@MainActor
final class AIReviewService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// 叙述层状态。规则摘要始终存在，模型叙述是可选增强，失败不影响主功能。
    enum NarrativeState: Equatable {
        /// 未开启或未配置，附带原因。
        case unavailable(String)
        case idle
        case streaming(String)
        case ready(String, cached: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [ReviewEntry] = []
    @Published private(set) var reviewed: Set<String> = []
    /// 补丁原文按提交哈希缓存，供「复制补丁」使用（不重复调用 git）。
    @Published private(set) var patches: [String: String] = [:]
    /// 每个提交的叙述状态，键为提交哈希。
    @Published private(set) var narratives: [String: NarrativeState] = [:]
    /// 每个提交在发送前脱敏掉的敏感片段数。
    @Published private(set) var narrativeRedactions: [String: Int] = [:]
    @Published private(set) var knowledgeContexts: [String: WikiContextSnapshot] = [:]
    /// 最近一次加载的仓库根目录，用于导出清单。
    private(set) var repositoryURL: URL?

    private let manager: SourceControlManager
    private let narrativeStore = AINarrativeStore.shared
    private weak var workspace: WorkspaceDocument?
    private var narrativeTasks: [String: Task<Void, Never>] = [:]
    private var narrativeGenerations: [String: UUID] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var reviewedDefaultsKey: String {
        "aiReview.reviewed.\(repositoryURL?.path ?? manager.workspaceURL.path)"
    }

    init(manager: SourceControlManager, workspace: WorkspaceDocument?) {
        self.manager = manager
        self.workspace = workspace
        self.repositoryURL = manager.workspaceURL
        self.reviewed = Set(UserDefaults.standard.stringArray(forKey: reviewedDefaultsKey) ?? [])
        observeNarrativeConfiguration()
    }

    // MARK: - 加载

    func load(limit: Int = 20) async {
        phase = .loading
        patches = [:]
        cancelAllNarratives()
        do {
            let commits = try await manager.gitClient.getCommitHistory(maxCount: limit)
            var result: [ReviewEntry] = []
            var patchCache: [String: String] = [:]

            for commit in commits {
                let stats = (try? await manager.gitClient.commitNumstat(hash: commit.commitHash)) ?? []
                let diffText = (try? await manager.gitClient.commitDiffText(hash: commit.commitHash)) ?? ""
                patchCache[commit.commitHash] = diffText

                let raw = RawCommit(
                    hash: commit.commitHash,
                    shortHash: commit.hash,
                    subject: commit.message,
                    body: commit.body,
                    author: commit.author,
                    date: commit.date,
                    numstat: stats.map { ($0.path, $0.added, $0.removed) },
                    diffText: diffText
                )
                result.append(ChangeReviewAnalyzer.analyze(raw))
            }

            entries = result
            patches = patchCache
            phase = .ready
            primeNarratives()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - AI 叙述
    //
    // 叙述是「补充层」：不参与分层与评分，不可用时静默降级到规则摘要。

    func narrative(for entry: ReviewEntry) -> NarrativeState {
        narratives[entry.id] ?? defaultNarrativeState()
    }

    /// 某次提交的补丁原文，供知识沉淀使用。
    func patch(for entry: ReviewEntry) -> String {
        patches[entry.id] ?? ""
    }

    func redactions(for entry: ReviewEntry) -> Int {
        narrativeRedactions[entry.id] ?? 0
    }

    /// 界面上标注叙述来源：接入方式 + 模型名。
    var narrativeProviderLabel: String {
        narrativeStore.providerLabel
    }

    /// 叙述层是否可用，以及一句可直接展示的状态。
    var isNarrativeReady: Bool { narrativeStore.isReady }

    var narrativeStatusText: String {
        narrativeStore.isReady
            ? "AI 叙述：\(narrativeProviderLabel)"
            : (narrativeStore.blockedReason ?? "AI 叙述未配置")
    }

    /// 生成一条叙述。命中缓存直接返回，不重复计费。
    func generateNarrative(for entry: ReviewEntry, force: Bool = false) {
        cancelNarrative(for: entry)
        guard let provider = narrativeStore.makeProvider() else {
            narratives[entry.id] = .unavailable(narrativeStore.blockedReason ?? "未配置模型")
            return
        }
        let generation = UUID()
        narrativeGenerations[entry.id] = generation
        knowledgeContexts[entry.id] = nil
        let root = repositoryURL ?? manager.workspaceURL
        let paths = entry.files.map(\.path)
        let patch = patches[entry.id] ?? ""
        let limit = narrativeStore.configuration.normalized().diffCharacters
        narratives[entry.id] = .streaming("")
        narrativeTasks[entry.id] = Task { [weak self] in
            let knowledge = await WikiKnowledgeContext.load(root: root, paths: paths)
            guard let self, !Task.isCancelled, self.narrativeGenerations[entry.id] == generation else { return }
            defer {
                if self.narrativeGenerations[entry.id] == generation {
                    self.narrativeTasks[entry.id] = nil
                    self.narrativeGenerations[entry.id] = nil
                }
            }
            self.knowledgeContexts[entry.id] = knowledge
            let key = self.cacheKey(for: entry, knowledge: knowledge.fingerprint, limit: limit)
            if !force, let cached = AINarrativeCache.load(key: key) {
                self.narratives[entry.id] = .ready(cached, cached: true)
                return
            }
            let prompt = AINarrativePrompt.user(for: entry, diff: patch, limit: limit, knowledge: knowledge)
            self.narrativeRedactions[entry.id] = prompt.redactions
            guard let request = self.narrativeStore.makeRequest(system: AINarrativePrompt.system(), user: prompt.text) else {
                self.narratives[entry.id] = .unavailable("模型配置已变化，请重试")
                return
            }
            var buffer = ""
            do {
                for try await chunk in provider.stream(request) {
                    guard !Task.isCancelled, self.narrativeGenerations[entry.id] == generation else { return }
                    buffer += chunk
                    self.narratives[entry.id] = .streaming(buffer)
                }
                let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw AINarrativeError.emptyResponse }
                // 生成期间代码或知识可能又变了；不能把迟到结果保存成当前依据下的解释。
                let current = await WikiKnowledgeContext.load(root: root, paths: paths)
                guard !Task.isCancelled, self.narrativeGenerations[entry.id] == generation else { return }
                guard current.fingerprint == knowledge.fingerprint else {
                    self.narratives[entry.id] = .failed("知识依据在生成期间发生变化，请重新生成；本次结果未保存。")
                    return
                }
                self.narratives[entry.id] = .ready(text, cached: false)
                AINarrativeCache.save(text, key: key)
            } catch {
                guard !Task.isCancelled, self.narrativeGenerations[entry.id] == generation else { return }
                self.narratives[entry.id] = .failed(AINarrativeError.describe(error))
            }
        }
    }

    func cancelNarrative(for entry: ReviewEntry) {
        narrativeGenerations[entry.id] = nil
        narrativeTasks[entry.id]?.cancel()
        narrativeTasks[entry.id] = nil
        if case .streaming = narratives[entry.id] {
            narratives[entry.id] = .idle
        }
    }

    /// 配置变更后重新判定可用性；正在生成时不打断。
    private func observeNarrativeConfiguration() {
        narrativeStore.$configuration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelAllNarratives()
                self.primeNarratives()
            }
            .store(in: &cancellables)
    }

    private func primeNarratives() {
        guard !entries.isEmpty else {
            narratives = [:]
            return
        }
        guard narrativeStore.isReady else {
            let reason = narrativeStore.blockedReason ?? "未配置模型"
            var next: [String: NarrativeState] = [:]
            for entry in entries { next[entry.id] = .unavailable(reason) }
            narratives = next
            return
        }
        // 缓存必须等当前知识重新校验后才读取，不能仅凭提交哈希展示旧依据下的叙述。
        var next: [String: NarrativeState] = [:]
        for entry in entries { next[entry.id] = .idle }
        narratives = next
    }

    private func defaultNarrativeState() -> NarrativeState {
        narrativeStore.isReady ? .idle : .unavailable(narrativeStore.blockedReason ?? "未配置模型")
    }

    private func cacheKey(for entry: ReviewEntry, knowledge: String, limit: Int) -> String {
        let endpoint = narrativeStore.resolvedEndpoint()
        return AINarrativeCache.key(
            hash: entry.id,
            endpoint: endpoint.baseURL,
            model: endpoint.model,
            promptVersion: AINarrativePrompt.version + "|knowledge:" + knowledge + "|diffLimit:\(limit)"
        )
    }

    private func cancelAllNarratives() {
        for task in narrativeTasks.values { task.cancel() }
        narrativeTasks.removeAll()
        narrativeGenerations.removeAll()
        knowledgeContexts.removeAll()
    }

    // MARK: - 审阅状态

    func toggleReviewed(_ id: String) {
        if reviewed.contains(id) {
            reviewed.remove(id)
        } else {
            reviewed.insert(id)
        }
        UserDefaults.standard.set(Array(reviewed), forKey: reviewedDefaultsKey)
    }

    func isReviewed(_ id: String) -> Bool {
        reviewed.contains(id)
    }

    // MARK: - 清单导出

    /// 生成单条清单的 JSON（正式字段，可被 CI 与外部工具消费）。
    func manifestJSON(for entry: ReviewEntry) -> String {
        var payload: [String: Any] = [
            "schema": "qiyide.ai-review/1",
            "id": entry.id,
            "shortHash": entry.shortHash,
            "title": entry.subject,
            "author": entry.author,
            "date": ISO8601DateFormatter().string(from: entry.date),
            "layer": entry.layer.rawValue,
            "score": entry.score,
            "importance": entry.importance.rawValue,
            "signals": entry.signals.map(\.rawValue),
            "summary": entry.summary,
            "diffstat": ["added": entry.added, "removed": entry.removed],
            "reviewed": isReviewed(entry.id),
            "files": entry.files.map { file -> [String: Any] in
                [
                    "path": file.path,
                    "layer": file.layer.rawValue,
                    "added": file.added,
                    "removed": file.removed,
                    "symbols": file.symbols.map { symbol in
                        ["name": symbol.name, "kind": symbol.kind.rawValue, "change": symbol.change.rawValue]
                    }
                ]
            }
        ]
        // generator 字段用于区分「代码生成」与「模型补充」，便于事后审计。
        payload["generator"] = "deterministic-analyzer"
        if case .ready(let narrative, _) = narrative(for: entry) {
            payload["narrative"] = narrative
            payload["generator"] = "deterministic-analyzer+\(narrativeProviderLabel)"
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 把全部清单写入 `<仓库根>/.qiyide/changes/`，返回目录 URL。
    @discardableResult
    func exportManifests() throws -> URL? {
        guard let root = repositoryURL ?? workspace?.fileURL else { return nil }
        let directory = root.appending(path: ".qiyide/changes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries {
            let file = directory.appending(path: "\(entry.shortHash).json")
            try manifestJSON(for: entry).write(to: file, atomically: true, encoding: .utf8)
        }
        return directory
    }

    // MARK: - 打开文件

    func openFirstFile(of entry: ReviewEntry) {
        guard let file = entry.files.first,
              let ceFile = workspace?.workspaceFileManager?.getFile(file.path, createIfNotFound: true) else {
            return
        }
        workspace?.editorManager?.openTab(item: ceFile)
    }
}
