//
//  GitClient+Diff.swift
//  CodeEdit
//
//  改动文件的差异视图数据源。
//

import Foundation

extension GitClient {
    /// 差异视图里的一行。
    struct DiffRow: Identifiable {
        enum Kind {
            /// 上下文行（未改动）。
            case context
            /// 新增行。
            case added
            /// 删除行。
            case removed
        }

        let id: Int
        let kind: Kind
        /// 该行在旧版本中的行号；新增行为 nil。
        let oldNumber: Int?
        /// 该行在新版本中的行号；删除行为 nil。
        let newNumber: Int?
        let text: String
    }

    /// 取一个文件相对 `HEAD` 的差异（含已暂存与未暂存改动）。
    ///
    /// 未跟踪文件不在 `git diff HEAD` 的输出里，这里直接读取文件内容，
    /// 合成「整文件新增」的差异，保证新文件也能看差异。
    /// - Parameters:
    ///   - file: 文件绝对路径。
    ///   - isUntracked: 是否为未跟踪文件。
    func diffAgainstHead(for file: URL, isUntracked: Bool) async throws -> [DiffRow] {
        if isUntracked {
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            // 以换行结尾的文件不应多出一条幽灵空行（split 会把结尾的空串也算作一段）。
            if content.hasSuffix("\n") {
                lines.removeLast()
            }
            return lines.enumerated().map { index, line in
                DiffRow(id: index, kind: .added, oldNumber: nil, newNumber: index + 1, text: String(line))
            }
        }

        let escaped = "'\(file.path(percentEncoded: false))'"
        let output = try await run("diff HEAD --unified=3 -- \(escaped)")
        return Self.parseUnifiedDiff(output)
    }

    /// 解析 `git diff` 的统一差异输出为行数组。
    /// - Parameter output: `git diff` 原始输出。
    static func parseUnifiedDiff(_ output: String) -> [DiffRow] {
        var rows: [DiffRow] = []
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var id = 0

        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if line.hasPrefix("@@") {
                // 形如 `@@ -12,7 +12,8 @@ 可选的函数上下文`
                let parts = line.split(separator: " ")
                if parts.count >= 3 {
                    oldLine = Self.hunkStart(parts[1])
                    newLine = Self.hunkStart(parts[2])
                }
                inHunk = true
                continue
            }

            // hunk 头之前的元信息（diff --git / index / --- / +++ 等）直接跳过。
            guard inHunk else { continue }
            if line.hasPrefix("diff --git")
                || line.hasPrefix("index ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("\\") {
                continue
            }

            if line.hasPrefix("+") {
                rows.append(
                    DiffRow(id: id, kind: .added, oldNumber: nil, newNumber: newLine, text: String(line.dropFirst()))
                )
                newLine += 1
            } else if line.hasPrefix("-") {
                rows.append(
                    DiffRow(id: id, kind: .removed, oldNumber: oldLine, newNumber: nil, text: String(line.dropFirst()))
                )
                oldLine += 1
            } else {
                // 上下文行：以空格开头；git 对空上下文行可能输出空字符串。
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                rows.append(
                    DiffRow(id: id, kind: .context, oldNumber: oldLine, newNumber: newLine, text: text)
                )
                oldLine += 1
                newLine += 1
            }
            id += 1
        }

        return rows
    }

    /// 从 `@@ -12,7` 这类片段取起始行号。
    private static func hunkStart(_ fragment: Substring) -> Int {
        let body = fragment.dropFirst()
        let number = body.split(separator: ",").first ?? Substring("1")
        return Int(number) ?? 1
    }
}
