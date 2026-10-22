//
//  FileSystemClient.swift
//  CodeEdit
//
//  Created by Matthijs Eikelenboom on 04/02/2023.
//

import Combine
import Foundation
import AppKit
import OSLog

protocol CEWorkspaceFileManagerObserver: AnyObject {
    func fileManagerUpdated(updatedItems: Set<CEWorkspaceFile>)
}

/// This class is used to load, modify, and listen to files on a user's machine.
///
/// The workspace file manager provides an API for:
/// - Navigating and loading file items.
/// - Moving and modifying files.
/// - Listening for file system updates and notifying observers.
///
/// File caching in CodeEdit is done lazily. the ``CEWorkspaceFileManager`` will only create ``CEWorkspaceFile``s for
/// from files that are needed for some UI component, and ignores all other files. This is done primarily to prevent
/// CodeEdit from wasting resources finding and caching a potentially large file tree (eg, a user's home directory).
///
/// When the workspace is first loaded, the file manager will only load the contents of the workspace directory. To find
/// files after this, calls to ``CEWorkspaceFileManager/getFile(_:createIfNotFound:)`` or
/// ``CEWorkspaceFileManager/childrenOfFile(_:)`` can cause the children for a file to be loaded into CodeEdit's cache
/// of files.
///
/// Moving and modifying files is done via the methods: ``CEWorkspaceFileManager/addFile(fileName:toFile:)``,
/// ``CEWorkspaceFileManager/addFolder(folderName:toFile:)``, ``CEWorkspaceFileManager/delete(file:)``,
/// ``CEWorkspaceFileManager/copy(file:to:)``, and ``CEWorkspaceFileManager/duplicate(file:)``.
///
/// To listen for updates, the ``CEWorkspaceFileManager`` uses a ``DirectoryEventStream`` to listen to updates for any
/// files under the ``CEWorkspaceFileManager/folderUrl`` url. Those can be passed on to listeners that conform to the
/// ``CEWorkspaceFileManagerObserver`` protocol. Use the ``CEWorkspaceFileManager/addObserver(_:)``
/// and ``CEWorkspaceFileManager/removeObserver(_:)`` to add or remove observers. Observers are kept as weak references.
final class CEWorkspaceFileManager {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "CEWorkspaceFileManager")
    private(set) var fileManager: FileManager
    private(set) var ignoredFilesAndFolders: Set<String>

    var flattenedFileItems: [String: CEWorkspaceFile]
    /// Maps all directories to it's children's paths.
    var childrenMap: [String: [String]] = [:]
    /// 每个根目录一个文件系统事件流（多根工作区时会有多个）。
    private var fsEventStreams: [DirectoryEventStream] = []
    var observers: NSHashTable<AnyObject> = .weakObjects()

    /// 主根目录。保留该属性以兼容既有只支持单根的调用点。
    let folderUrl: URL
    /// 主根对应的文件节点。
    let workspaceItem: CEWorkspaceFile
    /// 全部根目录（多根工作区）。单根时只有一个元素，首元素即 ``folderUrl``。
    private(set) var rootUrls: [URL]
    /// 全部根目录对应的文件节点，顺序与 ``rootUrls`` 一致。
    private(set) var rootItems: [CEWorkspaceFile]
    weak var sourceControlManager: SourceControlManager?
    /// 多根工作区下的仓库集合，用于把文件系统事件路由到所属仓库。
    weak var sourceControlWorkspace: SourceControlWorkspace?

    /// 单根工作区的便利初始化器。
    /// - Parameters:
    ///   - folderUrl: 作为唯一根目录的文件夹。
    ///   - ignoredFilesAndFolders: 需要忽略的文件名（如 `.DS_Store`），不是路径。
    convenience init(
        folderUrl: URL,
        ignoredFilesAndFolders: Set<String>,
        fileManager: FileManager = FileManager.default,
        sourceControlManager: SourceControlManager?
    ) {
        self.init(
            rootUrls: [folderUrl],
            ignoredFilesAndFolders: ignoredFilesAndFolders,
            fileManager: fileManager,
            sourceControlManager: sourceControlManager
        )
    }

    /// 多根工作区初始化器。
    /// - Parameters:
    ///   - rootUrls: 根目录列表，至少一个；重复路径会被自动去重。
    ///   - ignoredFilesAndFolders: 需要忽略的文件名（如 `.DS_Store`），不是路径。
    init(
        rootUrls: [URL],
        ignoredFilesAndFolders: Set<String>,
        fileManager: FileManager = FileManager.default,
        sourceControlManager: SourceControlManager?
    ) {
        // 去重并保持顺序，避免同一目录被注册两次导致事件重复与键冲突。
        var seen: Set<String> = []
        let roots = rootUrls
            .map { $0.standardizedFileURL }
            .filter { seen.insert($0.path).inserted }

        precondition(!roots.isEmpty, "A workspace requires at least one root folder")

        self.rootUrls = roots
        self.folderUrl = roots[0]
        self.ignoredFilesAndFolders = ignoredFilesAndFolders

        let items = roots.map { CEWorkspaceFile(url: $0) }
        self.rootItems = items
        self.workspaceItem = items[0]
        self.flattenedFileItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        self.sourceControlManager = sourceControlManager
        self.fileManager = fileManager

        for item in items {
            self.loadChildrenForFile(item)
        }

        self.fsEventStreams = roots.map { root in
            DirectoryEventStream(directory: root.path) { [weak self] events in
                self?.fileSystemEventReceived(events: events)
            }
        }

        Task {
            try await self.sourceControlManager?.validate()
        }
    }

    /// 添加一个根目录，使其成为工作区的一部分（多根工作区）。
    ///
    /// 已存在的根会被忽略，因此该方法对重复调用是安全的。
    /// - Parameter url: 要添加的文件夹。
    /// - Returns: 新加入的根节点；若已存在则返回已有的节点。
    @discardableResult
    func addRoot(_ url: URL) -> CEWorkspaceFile {
        let root = url.standardizedFileURL
        if let existing = zip(rootUrls, rootItems).first(where: { $0.0.path == root.path })?.1 {
            return existing
        }

        let item = CEWorkspaceFile(url: root)
        rootUrls.append(root)
        rootItems.append(item)
        flattenedFileItems[item.id] = item
        loadChildrenForFile(item)

        fsEventStreams.append(
            DirectoryEventStream(directory: root.path) { [weak self] events in
                self?.fileSystemEventReceived(events: events)
            }
        )

        observers.allObjects.forEach { observer in
            (observer as? CEWorkspaceFileManagerObserver)?.fileManagerUpdated(updatedItems: [item])
        }

        return item
    }

    /// 移除一个根目录。不会删除磁盘上的任何内容，只是不再将其纳入工作区。
    /// - Parameter url: 要移除的根目录。
    func removeRoot(_ url: URL) {
        let target = url.standardizedFileURL.path
        guard rootUrls.count > 1, let index = rootUrls.firstIndex(where: { $0.path == target }) else {
            return
        }

        let removed = rootItems.remove(at: index)
        rootUrls.remove(at: index)

        // 清理该根下的缓存条目，避免内存中残留已移除项目的文件树。
        let removedPrefix = removed.url.path
        let staleIDs = flattenedFileItems.compactMap { id, item in
            item.url.path == removedPrefix || item.url.path.hasPrefix(removedPrefix + "/") ? id : nil
        }
        for id in staleIDs {
            flattenedFileItems.removeValue(forKey: id)
            childrenMap.removeValue(forKey: id)
        }

        if fsEventStreams.indices.contains(index) {
            fsEventStreams.remove(at: index).cancel()
        }

        observers.allObjects.forEach { observer in
            (observer as? CEWorkspaceFileManagerObserver)?.fileManagerUpdated(updatedItems: [])
        }
    }

    // MARK: - Public API

    /// A function that, given a file's path, returns a `FileItem` if it exists
    /// within the scope of the `FileSystemClient`. 
    /// - Parameters:
    ///   - path: The file's relative path.
    ///   - createIfNotFound: Set to true if the function should index any intermediate directories to find the file,
    ///                       as well as index the file if it is not already.
    /// - Returns: The file item corresponding to the file
    func getFile(
        _ path: String,
        createIfNotFound: Bool = false
    ) -> CEWorkspaceFile? {
        if let file = flattenedFileItems[path] {
            return file
        } else if createIfNotFound {
            // 支持绝对路径与相对主根的路径两种写法。
            let url: URL
            if path.hasPrefix("/") {
                url = URL(fileURLWithPath: path)
            } else if let relative = URL(string: path, relativeTo: folderUrl) {
                url = relative.standardizedFileURL
            } else {
                return nil
            }

            // 找到包含该路径的根目录。必须取「最长前缀」的根：嵌套根目录时
            // （如 project 与 project/sub 同时是根），first(where:) 会命中外层根，
            // 从错误的根向下钻取，最终查不到文件、点击改动文件无反应。
            guard let root = rootUrls
                .filter({ $0.containsSubPath(url) || $0.path == url.path })
                .max(by: { $0.pathComponents.count < $1.pathComponents.count }) else {
                return nil
            }

            // Drill down towards the file, indexing any directories needed.
            let pathComponents = url.pathComponents.dropFirst(root.pathComponents.count)
            var currentURL = root

            for component in pathComponents {
                currentURL.append(component: component)

                if let file = flattenedFileItems[currentURL.relativePath], childrenMap[file.id] == nil {
                    loadChildrenForFile(file)
                }
            }

            if let file = flattenedFileItems[url.relativePath] {
                return file
            } else if let parent = getFile(currentURL.deletingLastPathComponent().path) {
                // This catches the case where each parent dir has been loaded, their children cached, and this is a new
                // file, so we still need to create it and add it to the cache.
                let newFileItem = createChild(url, forParent: parent)
                flattenedFileItems[newFileItem.id] = newFileItem
                childrenMap[parent.id]?.append(newFileItem.id)
                return newFileItem
            }
        }

        return nil
    }

    /// Returns all children for the given file.
    /// - Note: Will find and cache new children if they have not been already, see
    ///         ``CEWorkspaceFileManager/getFile(_:createIfNotFound:)`` to force a file to be loaded.
    /// - Parameter file: The file to find children for.
    /// - Returns: An array of children for the file, or `nil` if the file was not a directory.
    func childrenOfFile(_ file: CEWorkspaceFile) -> [CEWorkspaceFile]? {
        if file.isFolder {
            if childrenMap[file.id] == nil {
                // Load the children
                loadChildrenForFile(file)
            }

            return childrenMap[file.id]?.compactMap { flattenedFileItems[$0] }
        }

        return nil
    }

    /// Loads and caches all children for the given file item.
    ///
    /// After calling this method, you can expect `childrenMap` to contain some value
    /// for the file object, even an empty array.
    ///
    /// - Parameter file: The file item to load children for.
    private func loadChildrenForFile(_ file: CEWorkspaceFile) {
        guard let children = urlsForDirectory(file.resolvedURL) else {
            return
        }
        var addedChildrenUrls: [String] = []
        for child in children {
            let newFileItem = createChild(child, forParent: file)
            flattenedFileItems[newFileItem.id] = newFileItem
            addedChildrenUrls.append(newFileItem.id)
        }
        childrenMap[file.id] = addedChildrenUrls
        Task {
            await sourceControlManager?.refreshAllChangedFiles()
        }
    }

    /// Creates an ordered array of all files and directories at the given file object.
    /// - Parameter file: The file to use.
    /// - Returns: An ordered array of URLs sorted alphabetically with directories first.
    private func urlsForDirectory(_ url: URL) -> [URL]? {
        try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.includesDirectoriesPostOrder, .skipsSubdirectoryDescendants]
        )
        .compactMap {
            ignoredFilesAndFolders.contains($0.lastPathComponent) && (try? $0.checkResourceIsReachable()) ?? false
            ? nil
            : URL(filePath: $0.path(percentEncoded: false), relativeTo: folderUrl)
        }
        .sortItems(foldersOnTop: true)
    }

    /// Creates a child item for the specified parent item. Th child item's id is based on the
    /// parent's id to take into account symlinks.
    /// - Parameter url: The file url of the child element.
    /// - Parameter file: The parent element.
    /// - Returns: A child element with an associated parent.
    func createChild(_ url: URL, forParent file: CEWorkspaceFile) -> CEWorkspaceFile {
        let relativeURL = URL(filePath: file.id).appending(path: url.lastPathComponent)
        let childId = relativeURL.relativePath
        let newFileItem = CEWorkspaceFile(id: childId, url: relativeURL)
        newFileItem.parent = file
        return newFileItem
    }

#if DEBUG
    /// Determines if the file has had it's children loaded from disk.
    /// - Parameter file: The file to check.
    /// - Returns: True if the file's children have been cached.
    func hasLoadedChildrenFor(file: CEWorkspaceFile) -> Bool {
        childrenMap[file.id] != nil
    }
#endif

    /// Run when the owner of the ``CEWorkspaceFileManager`` doesn't need it anymore.
    /// This de-inits most functions in the ``CEWorkspaceFileManager``, so that in case it isn't de-init'd it does not
    /// use up significant amounts of RAM, and clears any file system event watchers.
    func cleanUp() {
        fsEventStreams.forEach { $0.cancel() }
        fsEventStreams.removeAll()
        flattenedFileItems = Dictionary(rootItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    deinit {
        fsEventStreams.forEach { $0.cancel() }
        observers.removeAllObjects()
    }
}
