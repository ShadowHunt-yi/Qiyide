//
//  ProjectNavigatorViewController+NSOutlineViewDataSource.swift
//  CodeEdit
//
//  Created by Khan Winter on 7/13/24.
//

import AppKit

extension ProjectNavigatorViewController: NSOutlineViewDataSource {
    /// 统一的排序规则：目录优先（可配置），同级按名称自然排序。
    ///
    /// 旧实现只判断「是否为目录」：两个文件互相比较时两边都返回 false，
    /// 等于「相等」，于是同组内的顺序完全取决于文件系统枚举顺序（不排序）。
    private func sortedChildren(_ children: [CEWorkspaceFile]) -> [CEWorkspaceFile] {
        guard children.count > 1 else { return children }
        let foldersFirst = workspace?.sortFoldersOnTop == true
        // 预取排序键：`isFolder` 虽是 lazy，但每次比较都访问它意味着 n log n 次属性读取，
        // 而首次读取会做磁盘 stat（符号链接解析）。预取后每个元素只读一次。
        let keyed = children.map { (file: $0, isFolder: $0.isFolder, name: $0.name) }
        let sorted = keyed.sorted { lhs, rhs in
            if foldersFirst, lhs.isFolder != rhs.isFolder {
                return lhs.isFolder
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return sorted.map(\.file)
    }

    /// Retrieves the children of a given item for the outline view, applying the current filter if necessary.
    private func getOutlineViewItems(for item: CEWorkspaceFile) -> [CEWorkspaceFile] {
        if let cachedChildren = filteredContentChildren[item] {
            return sortedChildren(cachedChildren)
        }

        if let workspace, let children = workspace.workspaceFileManager?.childrenOfFile(item) {
            if !workspace.navigatorFilter.isEmpty || workspace.sourceControlFilter || workspace.navigatorRecentsFilter {
                let filteredChildren = sortedChildren(children.filter {
                    fileSearchMatches(
                        workspace.navigatorFilter,
                        for: $0,
                        sourceControlFilter: workspace.sourceControlFilter
                    )
                })

                filteredContentChildren[item] = filteredChildren
                return filteredChildren
            }

            return sortedChildren(children)
        }

        return []
    }

    /// 把 outline 条目解析为文件：紧凑目录链映射为其终点文件。
    func fileItem(for item: Any?) -> CEWorkspaceFile? {
        ProjectNavigatorCompactItem.fileItem(from: item)
    }

    /// 计算一个目录的展示子项：把「只有一个子项」的目录链合并为紧凑行（VS Code Compact Folders）。
    ///
    /// 例如 `src` → `main` → `java` → `com` 每层只有一个子目录时，
    /// 直接显示为一行 `src/main/java/com`，链终点是目录时可继续展开。
    /// 链以单个文件结尾时同样合并为 `dir/File.java` 一行，单击即打开该文件。
    /// 搜索过滤时不合并，保持结果与关键词的直观对应。
    func displayChildren(for folder: CEWorkspaceFile) -> [Any] {
        let children = getOutlineViewItems(for: folder)
        guard let workspace,
              workspace.navigatorFilter.isEmpty,
              !workspace.sourceControlFilter,
              !workspace.navigatorRecentsFilter else {
            return children
        }

        var result: [Any] = []
        var index = 0
        while index < children.count {
            let child = children[index]
            index += 1
            guard child.isFolder else {
                result.append(child)
                continue
            }

            // 沿「只有一个子项」的链向下合并。
            // 带上访问集合与长度上限：符号链接自引用会让「单子项」链无限延伸。
            var chain = [child]
            var visited: Set<String> = [child.url.path]
            var node = child
            while chain.count < 64 {
                let subs = getOutlineViewItems(for: node)
                guard subs.count == 1 else { break }
                let next = subs[0]
                guard visited.insert(next.url.path).inserted else { break }
                chain.append(next)
                node = next
                if !next.isFolder { break }
            }

            if chain.count == 1 {
                result.append(child)
            } else {
                result.append(compactItem(for: chain))
            }
        }
        return result
    }

    /// 取（或创建）链对应的紧凑条目实例。缓存保证展开状态稳定。
    func compactItem(for chain: [CEWorkspaceFile]) -> ProjectNavigatorCompactItem {
        let key = chain[chain.count - 1].url.path
        if let cached = compactItemCache[key] {
            return cached
        }
        let item = ProjectNavigatorCompactItem(chain: chain)
        compactItemCache[key] = item
        for member in chain {
            compactItemByMemberPath[member.url.path] = item
        }
        return item
    }

    /// 文件被合并进紧凑目录链时，返回承载它的链条目（用于选中/揭示回退）。
    /// 走路径索引：原来每个选中变化都要遍历全部链条并逐项比较路径。
    func compactItem(containing file: CEWorkspaceFile) -> ProjectNavigatorCompactItem? {
        compactItemByMemberPath[file.url.path]
    }

    /// 缓存键：文件夹/文件用路径，紧凑条目用终点路径加前缀，根用空串。
    private func displayCacheKey(for item: Any?) -> String {
        if let file = item as? CEWorkspaceFile {
            return file.url.path
        }
        if let compact = item as? ProjectNavigatorCompactItem {
            return "c:" + compact.id
        }
        return ""
    }

    /// outline 的展示子项：目录与紧凑条目都要按展示规则展开。
    ///
    /// 结果按数据「代」缓存：`child(index:)` 会被逐行调用，不缓存时每取一行都会
    /// 重排整层并重建紧凑链，单层退化为 O(k² log k)。
    private func displayItems(for item: Any?) -> [Any] {
        let key = displayCacheKey(for: item)
        if let cached = displayChildrenCache[key] {
            return cached
        }
        let items: [Any]
        if let compact = item as? ProjectNavigatorCompactItem {
            items = displayChildren(for: compact.terminal)
        } else if let folder = item as? CEWorkspaceFile {
            items = displayChildren(for: folder)
        } else {
            items = content
        }
        displayChildrenCache[key] = items
        return items
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        displayItems(for: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        displayItems(for: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let compact = item as? ProjectNavigatorCompactItem {
            return !compact.isFile
        }
        if let item = item as? CEWorkspaceFile {
            return item.isFolder
        }
        return false
    }

    /// Write dragged file(s) to pasteboard
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let fileItem = fileItem(for: item) else { return nil }
        return fileItem.url as NSURL
    }

    /// Declare valid drop target
    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let fileItem = fileItem(for: item) else { return [] }
        // -1 index indicates that we are hovering over a row in outline view (folder or file)
        if index == -1 {
            if !fileItem.isFolder {
                outlineView.setDropItem(fileItem.parent, dropChildIndex: index)
            }
            return info.draggingSourceOperationMask == .copy ? .copy : .move
        }
        return []
    }

    /// Handle successful or unsuccessful drop
    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let pasteboardItems = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) else { return false }
        let fileItemURLS = pasteboardItems.compactMap { $0 as? URL }

        guard let fileItemDestination = fileItem(for: item) else { return false }
        let destParentURL = fileItemDestination.url

        for fileItemURL in fileItemURLS {
            let destURL = destParentURL.appending(path: fileItemURL.lastPathComponent)
            // cancel dropping file item on self or in parent directory
            if fileItemURL == destURL || fileItemURL == destParentURL {
                return false
            }

            // Needs to come before call to .removeItem or else race condition occurs
            var srcFileItem: CEWorkspaceFile? = workspace?.workspaceFileManager?.getFile(fileItemURL.path)
            // If srcFileItem is nil, fileItemUrl is an external file url.
            if srcFileItem == nil {
                srcFileItem = CEWorkspaceFile(url: URL(fileURLWithPath: fileItemURL.path))
            }

            guard let srcFileItem else {
                return false
            }

            if CEWorkspaceFile.fileManager.fileExists(atPath: destURL.path) {
                let shouldReplace = replaceFileDialog(fileName: fileItemURL.lastPathComponent)
                guard shouldReplace else {
                    return false
                }
                do {
                    try CEWorkspaceFile.fileManager.removeItem(at: destURL)
                } catch {
                    fatalError(error.localizedDescription)
                }
            }
            if info.draggingSourceOperationMask == .copy {
                self.copyFile(file: srcFileItem, to: destURL)
            } else {
                self.moveFile(file: srcFileItem, to: destURL)
            }
        }
        return true
    }

    func replaceFileDialog(fileName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = """
        A file or folder with the name \(fileName) already exists in the destination folder. Do you want to replace it?
        """
        alert.informativeText = "This action is irreversible!"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
