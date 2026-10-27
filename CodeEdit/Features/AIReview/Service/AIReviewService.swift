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

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var entries: [ReviewEntry] = []
    @Published private(set) var reviewed: Set<String> = []
    /// 补丁原文按提交哈希缓存，供「复制补丁」使用（不重复调用 git）。
    @Published private(set) var patches: [String: String] = [:]
    /// 最近一次加载的仓库根目录，用于导出清单。
    private(set) var repositoryURL: URL?

    private let manager: SourceControlManager
    private weak var workspace: WorkspaceDocument?
    private var reviewedDefaultsKey: String {
        "aiReview.reviewed.\(repositoryURL?.path ?? manager.workspaceURL.path)"
    }

    init(manager: SourceControlManager, workspace: WorkspaceDocument?) {
        self.manager = manager
        self.workspace = workspace
        self.repositoryURL = manager.workspaceURL
        self.reviewed = Set(UserDefaults.standard.stringArray(forKey: reviewedDefaultsKey) ?? [])
    }

    // MARK: - 加载

    func load(limit: Int = 20) async {
        phase = .loading
        patches = [:]
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
        } catch {
            phase = .failed(error.localizedDescription)
        }
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
