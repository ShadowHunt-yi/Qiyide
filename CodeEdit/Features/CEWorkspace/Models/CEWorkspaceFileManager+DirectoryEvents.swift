//
//  CEWorkspaceFileManager+DirectoryEvents.swift
//  CodeEdit
//
//  Created by Axel Martinez on 5/8/24.
//

import Foundation

/// This extension handles the file system events triggered by changes in the root folder.
extension CEWorkspaceFileManager {
    /// Called by `fsEventStream` when an event occurs.
    ///
    /// This method may be called on a background thread, but all work done by this function will be queued on the main
    /// thread.
    /// - Parameter events: An array of events that occurred.
    func fileSystemEventReceived(events: [DirectoryEventStream.Event]) {
        DispatchQueue.main.async {
            var files: Set<CEWorkspaceFile> = []
            for event in events {
                // Event returns file/folder that was changed, but in tree we need to update it's parent
                guard let parentUrl = URL(string: event.path, relativeTo: self.folderUrl)?.deletingLastPathComponent(),
                      let parentFileItem = self.flattenedFileItems[parentUrl.path] else {
                    continue
                }

                switch event.eventType {
                case .changeInDirectory, .itemChangedOwner, .itemModified:
                    // Can be ignored for now, these I think not related to tree changes
                    continue
                case .rootChanged:
                    // TODO: #1880 - Handle workspace root changing.
                    continue
                case .itemCreated, .itemCloned, .itemRemoved, .itemRenamed:
                    do {
                        try self.rebuildFiles(fromItem: parentFileItem)
                    } catch {
                        // swiftlint:disable:next line_length
                        self.logger.error("Failed to rebuild files for event: \(event.eventType.rawValue), path: \(event.path, privacy: .sensitive)")
                    }
                    files.insert(parentFileItem)
                }
            }
            if !files.isEmpty {
                self.notifyObservers(updatedItems: files)
            }

            if Settings.shared.preferences.sourceControl.general.sourceControlIsEnabled &&
                Settings.shared.preferences.sourceControl.general.refreshStatusLocally {
                self.handleGitEvents(events: events)
            }
        }
    }

    func handleGitEvents(events: [DirectoryEventStream.Event]) {
        // 多根工作区下，每个根目录是一个独立的 Git 仓库，需要分别判断、分别刷新，
        // 否则附加根里的改动不会反映到 Git 面板。
        for root in rootUrls {
            let rootPath = root.standardizedFileURL.path
            let rootEvents = events.filter { event in
                event.path == rootPath || event.path.hasPrefix(rootPath + "/")
            }
            guard !rootEvents.isEmpty else { continue }

            // 该根目录对应的仓库；单根（无仓库集合）时回退到工作区默认仓库。
            guard let manager = sourceControlWorkspace?.manager(forRoot: root) ?? sourceControlManager else {
                continue
            }

            let gitPrefix = "\(root.relativePath)/.git"

            // Changes excluding .git folder
            let notGitChanges = rootEvents.filter({ !$0.path.contains(".git/") })

            // .git folder was changed
            let gitFolderChange = rootEvents.first(where: { $0.path == gitPrefix })

            // Change made to git index file, staged/unstaged files
            let gitIndexChange = rootEvents.first(where: { $0.path == "\(gitPrefix)/index" })

            // Change made to git stash
            let gitStashChange = rootEvents.first(where: { $0.path == "\(gitPrefix)/refs/stash" })

            // Changes made to git branches
            let gitBranchChange = rootEvents.first(where: { $0.path.contains("\(gitPrefix)/refs/heads") })

            // Changes made to git HEAD - current branch changed
            let gitHeadChange = rootEvents.first(where: { $0.path.contains("\(gitPrefix)/HEAD") })

            // Change made to remotes by looking at .git/config
            let gitConfigChange = rootEvents.first(where: { $0.path == "\(gitPrefix)/config" })

            // If changes were made to project OR files were staged, refresh changes.
            // 走合并入口：短时间内大量事件（自动保存/构建产物）只触发一次 `git status`。
            if !notGitChanges.isEmpty || gitIndexChange != nil {
                manager.scheduleChangedFilesRefresh()
            }

            // If changes were stashed, refresh stashed entries
            if gitStashChange != nil {
                Task {
                    try await manager.refreshStashEntries()
                }
            }

            // If branches were added or removed, refresh branches
            if gitBranchChange != nil {
                Task {
                    await manager.refreshBranches()
                }
            }

            // If HEAD was changed, refresh the current branch
            if gitHeadChange != nil {
                Task {
                    await manager.refreshCurrentBranch()
                }
            }

            // If git config changed, refresh remotes
            if gitConfigChange != nil {
                Task {
                    try await manager.refreshRemotes()
                }
            }

            // If .git folder was added or removed, check if repository is valid
            if gitFolderChange != nil {
                Task {
                    try await manager.validate()
                }
            }
        }
    }

    /// Creates or deletes children of the ``CEWorkspaceFile`` so that they are accurate with the file system,
    /// instead of creating an entirely new ``CEWorkspaceFile``. Can optionally run a deep rebuild.
    ///
    /// This method will return immediately if the given file item is not a directory.
    /// This will also only rebuild *already cached* directories.
    /// - Parameters:
    ///   - fileItem: The ``CEWorkspaceFile``  to correct the children of
    ///   - deep: Set to `true` if this should perform the rebuild recursively.
    func rebuildFiles(fromItem fileItem: CEWorkspaceFile, deep: Bool = false) throws {
        // Do not index directories that are not already loaded.
        guard childrenMap[fileItem.id] != nil else { return }

        // get the actual directory children
        let directoryContentsUrls = try fileManager.contentsOfDirectory(
            at: fileItem.resolvedURL,
            includingPropertiesForKeys: nil
        )

        // test for deleted children, and remove them from the index
        // Folders may or may not have slash at the end, this will normalize check
        let directoryContentsUrlsRelativePaths = directoryContentsUrls.map({ $0.relativePath })
        for (idx, oldURL) in (childrenMap[fileItem.id] ?? []).map({ URL(filePath: $0) }).enumerated().reversed()
        where !directoryContentsUrlsRelativePaths.contains(oldURL.relativePath) {
            flattenedFileItems.removeValue(forKey: oldURL.relativePath)
            childrenMap[fileItem.id]?.remove(at: idx)
        }

        // test for new children, and index them
        for newContent in directoryContentsUrls {
            // if the child has already been indexed, continue to the next item.
            guard !ignoredFilesAndFolders.contains(newContent.lastPathComponent) &&
                    !(childrenMap[fileItem.id]?.contains(newContent.relativePath) ?? true) else { continue }

            if fileManager.fileExists(atPath: newContent.path) {
                let newFileItem = createChild(newContent, forParent: fileItem)
                flattenedFileItems[newFileItem.id] = newFileItem
                childrenMap[fileItem.id]?.append(newFileItem.id)
            }
        }

        childrenMap[fileItem.id] = childrenMap[fileItem.id]?
            .map { URL(filePath: $0) }
            .sortItems(foldersOnTop: true)
            .map { $0.relativePath }

        if deep && childrenMap[fileItem.id] != nil {
            for child in (childrenMap[fileItem.id] ?? []).compactMap({ flattenedFileItems[$0] }) {
                try rebuildFiles(fromItem: child)
            }
        }
    }

    /// Notify observers that an update occurred in the watched files.
    func notifyObservers(updatedItems: Set<CEWorkspaceFile>) {
        observers.allObjects.reversed().forEach { delegate in
            guard let delegate = delegate as? CEWorkspaceFileManagerObserver else {
                observers.remove(delegate)
                return
            }
            delegate.fileManagerUpdated(updatedItems: updatedItems)
        }
    }

    /// Add an observer for file system events.
    /// - Parameter observer: The observer to add.
    func addObserver(_ observer: CEWorkspaceFileManagerObserver) {
        observers.add(observer as AnyObject)
    }

    /// Remove an observer for file system events.
    /// - Parameter observer: The observer to remove.
    func removeObserver(_ observer: CEWorkspaceFileManagerObserver) {
        observers.remove(observer as AnyObject)
    }
}
