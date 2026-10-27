//
//  GitClient+CommitAnalysis.swift
//  CodeEdit
//
//  AI 改动审查所需的数据接口：单次提交的文件统计与补丁文本。
//

import Foundation

extension GitClient {
    /// 单次提交中一个文件的增删行数。
    struct CommitFileStat: Sendable {
        let path: String
        let added: Int
        let removed: Int
    }

    /// 取某次提交的文件级增删统计（`git show --numstat`）。
    func commitNumstat(hash: String) async throws -> [CommitFileStat] {
        let output = try await run("show --numstat --format= '\(hash)'")
        var stats: [CommitFileStat] = []
        for row in output.split(separator: "\n") {
            let columns = row.components(separatedBy: "\t")
            guard columns.count == 3 else { continue }
            // 二进制文件在 numstat 里是 "-"，按 0 处理。
            let added = Int(columns[0]) ?? 0
            let removed = Int(columns[1]) ?? 0
            stats.append(CommitFileStat(path: columns[2], added: added, removed: removed))
        }
        return stats
    }

    /// 取某次提交的补丁文本（不含提交头），用于符号提取与「复制补丁」。
    /// - Parameter maxCharacters: 超过该长度即截断，避免超大提交拖垮分析。
    func commitDiffText(hash: String, maxCharacters: Int = 400_000) async throws -> String {
        let output = try await run("show --format= --unified=3 '\(hash)'")
        guard output.count > maxCharacters else { return output }
        return String(output.prefix(maxCharacters))
    }
}
