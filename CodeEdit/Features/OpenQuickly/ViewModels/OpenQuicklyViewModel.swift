//
//  OpenQuicklyViewModel.swift
//  CodeEditModules/QuickOpen
//
//  Created by Marco Carnevali on 05/04/22.
//

import Combine
import Foundation
import CollectionConcurrencyKit

final class OpenQuicklyViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var searchResults: [SearchResult] = []

    /// 参与搜索的根目录。多根工作区下包含全部根；单根时只有一个元素。
    let fileURLs: [URL]
    /// 主根目录，保留以兼容既有调用点。
    var fileURL: URL { fileURLs.first ?? URL(fileURLWithPath: "/") }
    var runningTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURLs = [fileURL]
    }

    init(fileURLs: [URL]) {
        self.fileURLs = fileURLs
    }

    /// This is used to populate the ``OpenQuicklyListItemView`` view which shows the search results to the user.
    ///
    /// ``OpenQuicklyPreviewView`` also uses this to load the `fileUrl` for preview.
    struct SearchResult: Identifiable, Hashable {
        var id: String { fileURL.id }
        let fileURL: URL
        let matchedCharacters: [NSRange]

        // This custom Hashable implementation prevents the highlighted
        // selection from flickering when searching in 'Open Quickly'.
        //
        // See https://github.com/CodeEditApp/CodeEdit/pull/1790#issuecomment-2206832901
        // for flickering visuals.
        //
        // Before commit 0e28b382f59184b7ebe5a7c3295afa3655b7d4e7, only the fileURL
        // was retrieved from the search results and it worked as expected.
        //
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.fileURL == rhs.fileURL }
        func hash(into hasher: inout Hasher) { hasher.combine(fileURL) }
    }

    func fetchResults() {
        let startTime = Date()
        guard query != "" else {
            searchResults = []
            return
        }

        runningTask?.cancel()
        runningTask = Task.detached(priority: .userInitiated) {
            // 多根工作区：合并所有根目录下的文件。
            let filePaths: [URL] = self.fileURLs.flatMap { root -> [URL] in
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [
                        .isRegularFileKey
                    ],
                    options: [
                        .skipsPackageDescendants
                    ]
                )
                return enumerator?.allObjects as? [URL] ?? []
            }
            if !filePaths.isEmpty {
                guard !Task.isCancelled else { return }
                /// removes all filePaths which aren't regular files
                let filteredFiles = filePaths.filter { url in
                    do {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                        return (values.isRegularFile ?? false)
                    } catch {
                        return false
                    }
                }

                let fuzzySearchResults = await filteredFiles.fuzzySearch(
                    query: self.query.trimmingCharacters(in: .whitespaces)
                ).concurrentMap {
                    SearchResult(
                        fileURL: $0.item,
                        matchedCharacters: $0.result.matchedParts
                    )
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.searchResults = fuzzySearchResults
                    print("Duration: \(Date().timeIntervalSince(startTime))")
                }
            }
        }
    }
}
