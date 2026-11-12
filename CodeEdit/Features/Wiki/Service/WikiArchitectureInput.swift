//
//  WikiArchitectureInput.swift
//  CodeEdit
//
//  全部参与分析的源文件内容构成输入版本；HEAD 不变也可能有未提交的改动。
//

import CryptoKit
import Foundation

struct WikiArchitectureInput: Sendable {
    var digest: String
    var files: [RepoFileCandidate]

    /// 只读取代码，不调用 git 或模型。扫描与哈希都在可取消的后台任务内执行。
    static func capture(
        root: URL,
        onCount: (@Sendable (Int) -> Void)? = nil
    ) throws -> WikiArchitectureInput {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }

        var files: [RepoFileCandidate] = []
        var digests: [(String, String)] = []
        var lastUpdate = Date.distantPast
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if WikiRepoIngest.skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: keys)
            // 不跟随指向仓库外部的符号链接。
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  WikiRepoIngest.sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = WikiRepoIngest.relativePath(of: url, root: root)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let block = try handle.read(upToCount: 64 * 1024), !block.isEmpty {
                try Task.checkCancellation()
                hash.update(data: block)
            }
            digests.append((path, hash.finalize().map { String(format: "%02x", $0) }.joined()))
            files.append(WikiRepoIngest.score(path: path, bytes: values.fileSize ?? 0, churn: 0))
            if files.count == 1 || Date().timeIntervalSince(lastUpdate) >= 0.2 {
                onCount?(files.count)
                lastUpdate = Date()
            }
        }
        if let enumerationError { throw enumerationError }
        try Task.checkCancellation()
        var hash = SHA256()
        for (path, digest) in digests.sorted(by: { $0.0 < $1.0 }) {
            hash.update(data: Data((path + "\0" + digest + "\0").utf8))
        }
        onCount?(files.count)
        return WikiArchitectureInput(
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            files: files
        )
    }
}

/// detached 不继承父任务的取消；必须明确转发并等它退出。
enum WikiBackgroundWork {
    static func run<Value: Sendable>(
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try work()
            try Task.checkCancellation()
            return value
        }
        let value = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return value
    }
}
