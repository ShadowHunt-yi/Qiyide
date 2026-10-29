//
//  AINarrativeCache.swift
//  CodeEdit
//
//  叙述文本的磁盘缓存。
//
//  同一份提交、同一提示词版本、同一个模型，叙述不会变；
//  重复打开审查窗口不应该重复计费。键里带版本与模型，任一变化即自然失效。
//

import CryptoKit
import Foundation

enum AINarrativeCache {

    /// 缓存键：端点、模型与提示词版本都参与，避免换服务或换模型后读到旧文案。
    static func key(
        hash: String,
        endpoint: String,
        model: String,
        promptVersion: String
    ) -> String {
        "\(endpoint)|\(model)|\(promptVersion)|\(hash)"
    }

    static func load(key: String) -> String? {
        guard let url = fileURL(for: key),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ text: String, key: String) {
        guard let url = fileURL(for: key) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() {
        guard let directory = directoryURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 路径

    private static var directoryURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches
            .appending(path: "app.qiyide", directoryHint: .isDirectory)
            .appending(path: "aiReviewNarratives", directoryHint: .isDirectory)
    }

    private static func fileURL(for key: String) -> URL? {
        guard let directory = directoryURL else { return nil }
        // 键里有冒号、斜杠和模型名，直接做文件名不安全，取摘要。
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).txt")
    }
}
