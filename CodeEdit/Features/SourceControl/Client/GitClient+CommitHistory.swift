//
//  GitClient+CommitHistory.swift
//  CodeEdit
//
//  Created by Albert Vinizhanau on 10/20/23.
//

import Foundation

extension GitClient {
    /// Gets the commit history log for the specified branch or file
    /// - Parameters:
    ///   - branchName: Name of the branch
    ///   - maxCount: Maximum amount of entries to get
    ///   - fileLocalPath: Optional path of file to get history for
    /// - Returns: Array of git commits
    func getCommitHistory(
        branchName: String? = nil,
        maxCount: Int? = nil,
        fileLocalPath: String? = nil,
        showMergeCommits: Bool = false
    ) async throws -> [GitCommit] {
        let branchString = branchName != nil ? "\"\(branchName ?? "")\"" : ""
        let fileString = fileLocalPath != nil ? "\"\(fileLocalPath ?? "")\"" : ""
        let countString = maxCount != nil ? "-n \(maxCount ?? 0)" : ""

        // 日期必须用机器可读格式：`%aI` 是严格的 ISO 8601（不受 log.date 配置影响）。
        //
        // 原实现取 `%aD`（RFC 2822，如 "Thu, 11 Jun 2026 15:29:27 +0800"），
        // 却用 `Locale.current` 的 DateFormatter 解析：git 始终输出 C locale 的英文月日，
        // 在中文等非英文环境下解析必然失败，失败后又回退 `Date()`，
        // 于是历史列表的每一项都显示成「现在」（relativeStringToNow 得到「刚刚」）。
        let output = try await run(
            """
            log \(showMergeCommits ? "" : "--no-merges") -z \
            --pretty=%h¦%H¦%s¦%aN¦%ae¦%cn¦%ce¦%aI¦%b¦%D¦ \
            \(countString) \(branchString) -- \(fileString)
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let remoteURL = try await getRemoteURL()

        return output
            .split(separator: "\0")
            .map { line -> GitCommit in
                let parameters = String(line).components(separatedBy: "¦")
                let infoRef = parameters[safe: 9]
                var refs: [String] = []
                var tag = ""
                if let infoRef = infoRef {
                    if infoRef.contains("tag:") {
                        tag = infoRef.components(separatedBy: "tag:")[1].trimmingCharacters(in: .whitespaces)
                    } else {
                        refs = infoRef.split(separator: ",").compactMap {
                            var element = String($0)
                            if element.contains("origin/HEAD") { return nil }
                            if element.contains("HEAD -> ") {
                                element = element.replacingOccurrences(of: "HEAD -> ", with: "")
                            }
                            return element.trimmingCharacters(in: .whitespaces)
                        }
                    }
                }

                return GitCommit(
                    hash: parameters[safe: 0] ?? "",
                    commitHash: parameters[safe: 1] ?? "",
                    message: parameters[safe: 2] ?? "",
                    author: parameters[safe: 3] ?? "",
                    authorEmail: parameters[safe: 4] ?? "",
                    committer: parameters[safe: 5] ?? "",
                    committerEmail: parameters[safe: 6] ?? "",
                    body: parameters[safe: 8] ?? "",
                    refs: refs,
                    tag: tag,
                    remoteURL: remoteURL,
                    date: Self.parseISODate(parameters[safe: 7]) ?? .distantPast
                )
            }
    }

    /// 解析 `%aI` 输出的 ISO 8601 时间。
    ///
    /// 解析失败时返回 nil 而不是 `Date()`：历史列表按「距今多久」展示，
    /// 用当前时间兜底会把真实提交时间伪装成「刚刚」，比显示空值更有误导性。
    private static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        // 兜底：带毫秒或纯时间戳的变体（兼容不同 git 版本/配置）。
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        if let seconds = TimeInterval(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
