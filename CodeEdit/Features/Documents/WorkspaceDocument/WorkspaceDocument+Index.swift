//
//  WorkspaceDocument+Index.swift
//  CodeEdit
//
//  Created by Tommy Ludwig on 02.01.24.
//

import Foundation

extension WorkspaceDocument.SearchState {
    /// Adds the contents of the current workspace URL to the search index.
    /// That means that the contents of the workspace will be indexed and searchable.
    func addProjectToIndex() {
        guard let indexer = indexer else { return }
        // 多根工作区：索引全部根目录，保证搜索能覆盖所有被管理的项目。
        let rootURLs = workspace.workspaceFileManager?.rootUrls ?? []
        guard !rootURLs.isEmpty else { return }

        indexStatus = .indexing(progress: 0.0)
        let uuidString = UUID().uuidString
        let createInfo: [String: Any] = [
            "id": uuidString,
            "action": "create",
            "title": "Indexing | Processing files",
            "message": "Creating an index to enable fast and accurate searches within your codebase.",
            "isLoading": true
        ]
        NotificationCenter.default.post(name: .taskNotification, object: nil, userInfo: createInfo)

        Task.detached {
            let filePaths = rootURLs.flatMap { self.getFileURLs(at: $0) }

            let asyncController = SearchIndexer.AsyncManager(index: indexer)
            var lastProgress: Double = 0

            for await (file, index) in AsyncFileIterator(fileURLs: filePaths) {
                _ = await asyncController.addText(files: [file], flushWhenComplete: false)
                let progress = Double(index) / Double(filePaths.count)

                // Send only if difference is > 0.5%, to keep updates from sending too frequently
                if progress - lastProgress > 0.005 || index == filePaths.count - 1 {
                    lastProgress = progress
                    await MainActor.run {
                        self.indexStatus = .indexing(progress: progress)
                    }
                    let updateInfo: [String: Any] = [
                        "id": uuidString,
                        "action": "update",
                        "percentage": progress
                    ]
                    NotificationCenter.default.post(name: .taskNotification, object: nil, userInfo: updateInfo)
                }
            }
            asyncController.index.flush()

            await MainActor.run {
                self.indexStatus = .done
            }
            let updateInfo: [String: Any] = [
                "id": uuidString,
                "action": "update",
                "title": "Finished indexing",
                "isLoading": false
            ]
            NotificationCenter.default.post(name: .taskNotification, object: nil, userInfo: updateInfo)

            let deleteInfo = [
                "id": uuidString,
                "action": "deleteWithDelay",
                "delay": 4.0
            ]
            NotificationCenter.default.post(name: .taskNotification, object: nil, userInfo: deleteInfo)
        }
    }

    /// 索引时跳过的目录：构建产物与依赖缓存。
    ///
    /// 这些目录通常包含成千上万个生成文件（本机 `saas-plus-ai-platform` 的 `target/` 就有 4400+ 个），
    /// 索引它们既显著拉长建索引时间，也会让搜索结果里混入大量无意义条目。
    private static let indexExcludedDirectories: Set<String> = [
        "node_modules", "target", "build", "dist", "out", "Pods", "DerivedData",
        ".build", ".gradle", "__pycache__", ".venv", "venv", ".tox"
    ]

    /// Retrieves an array of file URLs within the specified directory URL.
    ///
    /// - Parameter url: The URL of the directory to search for files.
    ///
    /// - Returns: An array of file URLs found within the specified directory.
    func getFileURLs(at url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        // 逐个取而不是 `allObjects`：碰到构建产物目录要用 `skipDescendants()` 整棵跳过，
        // 否则仍会枚举完再过滤（4000+ 文件的目录白走一遍）。
        var urls: [URL] = []
        while let element = enumerator.nextObject() as? URL {
            let isDirectory = (try? element.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory, Self.indexExcludedDirectories.contains(element.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            urls.append(element)
        }
        return urls
    }

    /// Retrieves the contents of a files  from the specified file paths.
    ///
    /// - Parameter filePaths: An array of file URLs representing the paths of the files.
    ///
    /// - Returns: An array of `TextFile` objects containing the standardised file URLs and text content.
    func getFileContent(from filePaths: [URL]) async -> [SearchIndexer.AsyncManager.TextFile] {
        var textFiles = [SearchIndexer.AsyncManager.TextFile]()
        for file in filePaths {
            if let content = try? String(contentsOf: file) {
                textFiles.append(
                    SearchIndexer.AsyncManager.TextFile(url: file.standardizedFileURL, text: content)
                )
            }
        }
        return textFiles
    }
}
