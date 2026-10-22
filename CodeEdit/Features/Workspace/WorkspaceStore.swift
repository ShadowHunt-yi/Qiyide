//
//  WorkspaceStore.swift
//  CodeEdit
//
//  工作区持久化：工作区定义与最近打开记录的读写。
//

import Foundation
import OSLog

enum WorkspaceStoreError: LocalizedError {
    case emptyFolders
    case invalidFolder(String)
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .emptyFolders:
            return "A workspace requires at least one folder."
        case .invalidFolder(let path):
            return "The folder does not exist: \(path)"
        case .notFound(let id):
            return "Workspace not found: \(id.uuidString)"
        }
    }
}

/// 工作区的持久化存储。
///
/// 设计要点：
/// - **磁盘布局**：`~/Library/Application Support/Qiyide/Workspaces/workspaces.json`。
///   单文件保存全部工作区定义，便于原子写入与人工检查；每个工作区在文件中是独立条目，
///   配置互不影响。
/// - **状态与定义分离**：窗口/编辑器状态仍按 `workspace.id` 存放在各自的存储键中，
///   不写入本文件，避免频繁写盘。
/// - **可测试**：`init(directory:fileManager:)` 允许注入临时目录，单元测试无需触碰真实用户目录。
final class WorkspaceStore {
    /// 最近打开列表的最大长度。
    static let maxRecents = 20

    /// 持久化文件的结构。
    struct Index: Codable {
        var workspaces: [Workspace]
        var recents: [UUID]

        static let empty = Index(workspaces: [], recents: [])
    }

    static let shared = WorkspaceStore()

    private(set) var index: Index

    private let fileManager: FileManager
    private let directoryURL: URL
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "WorkspaceStore")

    /// 存储文件位置。
    var fileURL: URL {
        directoryURL.appending(path: "workspaces.json")
    }

    /// 创建存储。
    /// - Parameters:
    ///   - directoryURL: 存储目录；传 `nil` 时使用应用支持目录。
    ///   - fileManager: 便于测试注入。
    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = directoryURL ?? fileManager
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Qiyide/Workspaces", directoryHint: .isDirectory)
        self.directoryURL = directory
        self.index = Self.load(from: directory.appending(path: "workspaces.json"))
    }

    // MARK: - 查询

    var allWorkspaces: [Workspace] {
        index.workspaces
    }

    func workspace(id: UUID) -> Workspace? {
        index.workspaces.first { $0.id == id }
    }

    /// 最近打开的工作区，按最近使用排序，忽略已删除的条目。
    func recentWorkspaces(limit: Int = WorkspaceStore.maxRecents) -> [Workspace] {
        index.recents
            .compactMap { id in index.workspaces.first { $0.id == id } }
            .prefix(limit)
            .map { $0 }
    }

    /// 查找与给定根目录集合完全一致的工作区。
    /// 用于「打开文件夹时复用已有工作区」，避免同一目录产生多个记录。
    func workspace(matchingFolders urls: [URL]) -> Workspace? {
        let paths = Set(urls.map { $0.standardizedFileURL.path })
        return index.workspaces.first { workspace in
            Set(workspace.folders.map { $0.url.standardizedFileURL.path }) == paths
        }
    }

    // MARK: - 修改

    /// 创建工作区。
    /// - Parameters:
    ///   - name: 显示名称；传空时自动生成。
    ///   - folders: 根目录 URL 列表，至少一个，且必须存在。
    @discardableResult
    func create(name: String, folders: [URL], settings: [String: JSONValue] = [:]) throws -> Workspace {
        guard !folders.isEmpty else { throw WorkspaceStoreError.emptyFolders }
        for url in folders where !fileManager.fileExists(atPath: url.path) {
            throw WorkspaceStoreError.invalidFolder(url.path)
        }

        let workspaceFolders = folders.map { WorkspaceFolder(url: $0) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = Workspace(
            name: trimmedName.isEmpty ? Workspace.defaultName(for: workspaceFolders) : trimmedName,
            folders: workspaceFolders,
            settings: settings
        )

        index.workspaces.append(workspace)
        try markOpened(workspace.id)
        return workspace
    }

    /// 更新工作区定义（名称、根目录、设置覆盖）。
    func update(_ workspace: Workspace) throws {
        guard let idx = index.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            throw WorkspaceStoreError.notFound(workspace.id)
        }
        index.workspaces[idx] = workspace
        try persist()
    }

    /// 删除工作区定义。仅删除元数据，不触碰磁盘上的源码目录。
    func delete(id: UUID) throws {
        guard index.workspaces.contains(where: { $0.id == id }) else {
            throw WorkspaceStoreError.notFound(id)
        }
        index.workspaces.removeAll { $0.id == id }
        index.recents.removeAll { $0 == id }
        try persist()
    }

    /// 记录一次打开，用于最近列表排序。
    func markOpened(_ id: UUID) throws {
        index.recents.removeAll { $0 == id }
        index.recents.insert(id, at: 0)
        if index.recents.count > Self.maxRecents {
            index.recents = Array(index.recents.prefix(Self.maxRecents))
        }
        try persist()
    }

    /// 为工作区写入设置覆盖（合并到已有覆盖之上）。
    func setSettingsOverride(_ override: [String: JSONValue], for id: UUID) throws {
        guard var workspace = workspace(id: id) else { throw WorkspaceStoreError.notFound(id) }
        var merged = workspace.settings
        for (key, value) in override {
            merged[key] = value
        }
        workspace.settings = merged
        try update(workspace)
    }

    // MARK: - 持久化

    private static func load(from url: URL) -> Index {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Index.self, from: data)) ?? .empty
    }

    private func persist() throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(index)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist workspaces: \(error.localizedDescription)")
            throw error
        }
    }
}
