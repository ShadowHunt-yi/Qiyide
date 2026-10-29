//
//  WikiIngestState.swift
//  CodeEdit
//
//  整仓建档的进度记录：哪些文件已经读过、哪些模块已经写过。
//
//  为什么必须有这个文件：
//  一个中型仓库几百到上千个源码文件，一次跑完意味着上百次模型调用——成本、时间、
//  限流都不允许。所以建档必须是「分批 + 可续跑」的：这一轮读一批，下一轮接着读，
//  已经读过且没改动的文件直接跳过。
//
//  判定「读过且没变」用 mtime + size，不用内容哈希：
//  哈希要读全文件内容，几百个文件就是几百次磁盘 IO；mtime+size 对源码足够可靠。
//

import Foundation

struct WikiIngestState: Codable {

    struct FileStamp: Codable {
        var modified: Double
        var size: Int
        var processedAt: Double
    }

    struct ModuleStamp: Codable {
        var updatedAt: Double
        var files: [String]
    }

    /// 相对路径 → 已处理的文件戳。
    var files: [String: FileStamp] = [:]
    /// 模块名 → 上次生成条目时覆盖的文件。
    var modules: [String: ModuleStamp] = [:]

    // MARK: 存取

    static func url(root: URL) -> URL {
        root.appending(path: ".qiyide/wiki/.ingest-state.json")
    }

    static func load(root: URL) -> WikiIngestState {
        guard let data = try? Data(contentsOf: url(root: root)),
              let state = try? JSONDecoder().decode(WikiIngestState.self, from: data) else {
            return WikiIngestState()
        }
        return state
    }

    func save(root: URL) {
        let target = Self.url(root: root)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: target, options: .atomic)
    }

    // MARK: 判定

    /// 该文件是否已处理过且此后没有改动。
    func isFresh(path: String, url: URL) -> Bool {
        guard let stamp = files[path],
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate?.timeIntervalSince1970,
              let size = values.fileSize else {
            return false
        }
        return abs(stamp.modified - modified) < 1 && stamp.size == size
    }

    mutating func markProcessed(path: String, url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate?.timeIntervalSince1970,
              let size = values.fileSize else { return }
        files[path] = FileStamp(
            modified: modified,
            size: size,
            processedAt: Date().timeIntervalSince1970
        )
    }

    mutating func markModule(_ name: String, files: [String]) {
        modules[name] = ModuleStamp(
            updatedAt: Date().timeIntervalSince1970,
            files: files
        )
    }
}
