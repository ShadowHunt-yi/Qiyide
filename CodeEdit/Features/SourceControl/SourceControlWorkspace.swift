//
//  SourceControlWorkspace.swift
//  CodeEdit
//
//  多根工作区下的 Git 仓库集合。
//

import Foundation
import Combine

/// 管理一个工作区内所有根目录对应的 ``SourceControlManager``。
///
/// 单根工作区时 `repositories` 只有一个元素，行为与原实现完全一致；
/// 多根工作区时每个根目录拥有独立的 Git 客户端、分支、暂存区与提交历史。
///
/// 该类只负责「有哪些仓库」与「当前显示哪个仓库」，不复制任何 Git 逻辑，
/// 所有操作仍通过 ``SourceControlManager`` 完成。
final class SourceControlWorkspace: ObservableObject {
    /// 一个根目录对应的仓库。
    struct Repository: Identifiable {
        /// 标准化后的根目录路径，同时作为稳定标识。
        let id: String
        let rootURL: URL
        /// 展示名称。同名根目录会自动带上父目录名以区分。
        let displayName: String
        let manager: SourceControlManager
    }

    /// 当前工作区的全部仓库，顺序与根目录顺序一致。
    @Published private(set) var repositories: [Repository] = []

    /// 当前选中仓库的 `id`。始终指向一个存在的仓库。
    @Published private(set) var activeRepositoryID: String?

    /// 是否处于「全部仓库」聚合视图。
    @Published private(set) var isShowingAllRepositories: Bool = false

    /// 每个 manager 的通知订阅，按仓库 id 索引。
    private var managerCancellables: [String: AnyCancellable] = [:]

    // MARK: - 查询

    var activeRepository: Repository? {
        guard let activeRepositoryID else { return nil }
        return repositories.first { $0.id == activeRepositoryID }
    }

    /// 当前工作仓库。聚合视图下仍返回最近一次选中的仓库，供工具栏等只支持单仓库的界面使用。
    var activeManager: SourceControlManager? {
        activeRepository?.manager ?? repositories.first?.manager
    }

    /// 主根对应的仓库。工作区至少有根目录时不为空。
    var primaryManager: SourceControlManager? {
        repositories.first?.manager
    }

    var primaryRepository: Repository? {
        repositories.first
    }

    /// 有改动的仓库，按根目录顺序。
    var repositoriesWithChanges: [Repository] {
        repositories.filter { !$0.manager.changedFiles.isEmpty }
    }

    /// 全部仓库的改动文件总数，用于聚合角标。
    var totalChangedFiles: Int {
        repositories.reduce(0) { $0 + $1.manager.changedFiles.count }
    }

    /// 有未同步提交的仓库数量。
    var repositoriesWithUnsyncedCommits: Int {
        repositories.filter {
            $0.manager.numberOfUnsyncedCommits.ahead > 0 || $0.manager.numberOfUnsyncedCommits.behind > 0
        }.count
    }

    /// 返回给定路径所属的仓库管理器。用于把文件系统事件路由到正确的仓库。
    func manager(forRoot url: URL) -> SourceControlManager? {
        let path = url.standardizedFileURL.path
        return repositories.first { $0.id == path }?.manager
    }

    /// 返回包含给定文件路径的仓库管理器。
    func manager(containingFileAt url: URL) -> SourceControlManager? {
        let path = url.standardizedFileURL.path
        // 取最长前缀匹配，避免嵌套根目录时匹配到外层仓库。
        return repositories
            .filter { path == $0.id || path.hasPrefix($0.id + "/") }
            .max { $0.id.count < $1.id.count }?
            .manager
    }

    // MARK: - 选择

    func select(_ repositoryID: String) {
        guard repositories.contains(where: { $0.id == repositoryID }) else { return }
        isShowingAllRepositories = false
        activeRepositoryID = repositoryID
    }

    func showAllRepositories() {
        isShowingAllRepositories = true
    }

    // MARK: - 同步

    /// 让仓库集合与根目录列表保持一致：新增缺失的仓库，移除已不存在的仓库。
    ///
    /// - Parameters:
    ///   - roots: 当前工作区的全部根目录。
    ///   - editorManager: 传给每个仓库的编辑器管理器。
    ///   - fileManager: 文件管理器，用于把 Git 状态回写到文件树。
    func sync(roots: [URL], editorManager: EditorManager, fileManager: CEWorkspaceFileManager?) {
        let standardized = roots.map { $0.standardizedFileURL }
        let keep = Set(standardized.map { $0.path })

        // 移除已被移出工作区的根目录，并释放其通知订阅。
        for repository in repositories where !keep.contains(repository.id) {
            managerCancellables.removeValue(forKey: repository.id)?.cancel()
        }
        if repositories.contains(where: { !keep.contains($0.id) }) {
            repositories.removeAll { !keep.contains($0.id) }
            if let activeRepositoryID, !keep.contains(activeRepositoryID) {
                self.activeRepositoryID = repositories.first?.id
            }
        }

        // 为新增根目录创建仓库。
        let existingIDs = Set(repositories.map { $0.id })
        let names = Self.displayNames(for: standardized)
        var didAdd = false

        for url in standardized where !existingIDs.contains(url.path) {
            let manager = SourceControlManager(workspaceURL: url, editorManager: editorManager)
            manager.fileManager = fileManager

            let repository = Repository(
                id: url.path,
                rootURL: url,
                displayName: names[url.path] ?? url.lastPathComponent,
                manager: manager
            )
            repositories.append(repository)
            observe(manager, id: repository.id)
            didAdd = true

            Task { [weak manager] in
                guard let manager else { return }
                try? await manager.validate()
                // 远程信息必须逐仓库刷新：WorkspaceView 的全局 task 只覆盖主仓库，
                // 次要仓库不在这里刷会永远显示「无远程」。
                try? await manager.refreshRemotes()
                try? await manager.refreshStashEntries()
                await manager.refreshCurrentBranch()
                await manager.refreshAllChangedFiles()
            }
        }

        if activeRepositoryID == nil {
            activeRepositoryID = repositories.first?.id
        }

        // 新建仓库时若数量超过一个，默认进入聚合视图，让用户先看到全貌。
        if didAdd, repositories.count > 1 {
            isShowingAllRepositories = true
        }

        // 只剩一个仓库时聚合视图没有意义，回到单仓库视图，避免切换器消失后无法退出。
        if repositories.count <= 1 {
            isShowingAllRepositories = false
        }
    }

    /// 当仓库被移出工作区时，释放其通知订阅。
    func clear() {
        managerCancellables.values.forEach { $0.cancel() }
        managerCancellables.removeAll()
        repositories.removeAll()
        activeRepositoryID = nil
        isShowingAllRepositories = false
    }

    // MARK: - 私有

    private func observe(_ manager: SourceControlManager, id: String) {
        // 转发子仓库的变化，使聚合角标与仓库选择器能实时更新。
        managerCancellables[id] = manager.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if Thread.isMainThread {
                self.objectWillChange.send()
            } else {
                DispatchQueue.main.async { self.objectWillChange.send() }
            }
        }
    }

    /// 计算展示名。重名时使用「父目录/名称」消除歧义。
    private static func displayNames(for urls: [URL]) -> [String: String] {
        var counts: [String: Int] = [:]
        for url in urls {
            counts[url.lastPathComponent, default: 0] += 1
        }

        var result: [String: String] = [:]
        for url in urls {
            let name = url.lastPathComponent
            if counts[name, default: 0] > 1 {
                let parent = url.deletingLastPathComponent().lastPathComponent
                result[url.path] = parent.isEmpty ? name : "\(parent)/\(name)"
            } else {
                result[url.path] = name
            }
        }
        return result
    }
}
