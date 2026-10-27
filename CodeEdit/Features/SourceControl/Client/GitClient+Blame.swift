//
//  GitClient+Blame.swift
//  CodeEdit
//
//  行级 blame 标注与行历史的数据源。
//

import Foundation

/// 一行 blame 信息（该行最后一次修改的提交）。
struct GitBlameLine {
    /// 提交哈希；未提交行是全 0。
    let commitHash: String
    let author: String
    /// 提交时间（author-time）。
    let authorTime: Date?
    let summary: String
    /// 该行来源文件名（重命名前可能是旧路径）。
    let filename: String
    /// 是否是边界提交（分支起点等，信息不完整）。
    let isBoundary: Bool

    /// 未提交的本地修改行。
    var isNotCommitted: Bool { commitHash.allSatisfy { $0 == "0" } }

    /// 标注文本：`abc1234 作者 日期 摘要`。
    var annotationText: String {
        if isNotCommitted {
            return "未提交的修改"
        }
        let date: String
        if let authorTime {
            date = Self.dateFormatter.string(from: authorTime)
        } else {
            date = ""
        }
        let hash = String(commitHash.prefix(7))
        let boundaryMark = isBoundary ? " (边界)" : ""
        return "\(hash)  \(author)  \(date)  \(summary)\(boundaryMark)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// 行历史中的一条提交记录。
struct GitLineHistoryEntry: Identifiable {
    let id: String
    let commitHash: String
    let author: String
    let date: String
    let summary: String
    /// `git log -L` 输出的该次提交差异片段。
    let diff: String
}

/// blame / 行历史无法提供的「预期原因」。
///
/// 这些情况不是故障（空仓库、未跟踪文件、文件在仓库外），调用方应静默降级，
/// 不能把它们当作错误弹窗——否则新建仓库或新增文档一打开就会弹「无法获取 blame」。
enum GitBlameUnavailable: Error, LocalizedError {
    /// 文件不在任何 git 仓库内。
    case notARepository
    /// 仓库存在但还没有任何提交（HEAD 未指向提交）。
    case noCommits
    /// 文件未被 git 跟踪（新建/未 add/被忽略）。
    case untracked
    /// 文件已不在磁盘上（恢复的标签页指向已删除/移动的文件）。
    case fileMissing
    /// git 输出不是合法 UTF-8（例如 GBK 编码的历史文档），无法解析。
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .notARepository: return "该文件不在 Git 仓库中。"
        case .noCommits: return "仓库还没有任何提交。"
        case .untracked: return "该文件尚未纳入 Git 跟踪。"
        case .fileMissing: return "该文件已不在磁盘上。"
        case .unsupportedEncoding: return "文件编码不是 UTF-8，无法解析 blame 输出。"
        }
    }
}

extension GitClient {
    /// 取文件逐行 blame（工作区版本；未提交行标记为 Not Committed Yet）。
    ///
    /// - `-w` 忽略空白，`-M` 检测行移动，`-C` 检测跨文件复制；
    ///   重命名由 blame 内部自动跟随。
    /// - Parameter file: 文件绝对路径。
    /// - Returns: 与文件行一一对应的 blame 记录。
    /// - Throws: ``GitBlameUnavailable`` 表示预期内的不可用；其余为真实故障。
    func blameLines(for file: URL) async throws -> [GitBlameLine] {
        // 恢复的标签页可能指向已删除/移动的文件：先判存在，避免把「文件不存在」
        // 当成故障弹窗（git 会报 cannot stat，不属于仓库问题）。
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            throw GitBlameUnavailable.fileMissing
        }
        let root = try await repositoryRoot(containingFile: file)
        let escaped = "'\(file.path(percentEncoded: false))'"
        do {
            // 必须在该文件所属仓库内执行：多根工作区下文件可能属于嵌套仓库，
            // 用主仓库 cwd 会得到 `no such path` / `no such ref: HEAD`。
            let output = try await run("blame --line-porcelain -w -M -C -- \(escaped)", in: root)
            return Self.parseLinePorcelain(output)
        } catch let error as GitClientError {
            if let reason = Self.unavailableReason(for: error) {
                throw reason
            }
            throw error
        } catch ShellClientError.failedToDecodeOutput {
            // 旧编码文件（GBK 等）的 blame 输出不是合法 UTF-8；
            // ShellClient 严格解码失败，这里降级为「不可用」而不是故障。
            throw GitBlameUnavailable.unsupportedEncoding
        }
    }

    /// 取某一行（或行区间）的完整变更历史。
    ///
    /// 使用 `git log -L`；对未提交的改动只会返回已提交部分（git 语义如此），
    /// 调用方在 UI 上提示本地未提交内容不在历史内。
    func lineHistory(
        for file: URL,
        startLine: Int,
        endLine: Int
    ) async throws -> [GitLineHistoryEntry] {
        let root = try await repositoryRoot(containingFile: file)
        let escaped = "'\(file.path(percentEncoded: false))'"
        let range = "\(startLine),\(endLine)"
        let pretty = "--pretty=format:COMMIT%x1f%H%x1f%h%x1f%an%x1f%ad%x1f%s%x1f--date=short"
        do {
            let output = try await run("log -L \(range):\(escaped) \(pretty) --", in: root)
            return Self.parseLineHistory(output)
        } catch let error as GitClientError {
            // 无提交 / 未跟踪不是错误，历史面板显示空态即可。
            if Self.unavailableReason(for: error) != nil {
                return []
            }
            throw error
        } catch ShellClientError.failedToDecodeOutput {
            // 旧编码文件的历史输出无法解码：按「无历史」处理，不弹故障。
            return []
        }
    }

    /// 解析文件所属的 git 仓库根目录。
    ///
    /// 从文件所在目录向上查找，因此嵌套仓库（子目录自身是独立仓库）能正确解析；
    /// 主仓库 cwd 只适用于「文件就在主仓库内」的场景。
    private func repositoryRoot(containingFile file: URL) async throws -> URL {
        let parent = file.deletingLastPathComponent()
        let base = FileManager.default.fileExists(atPath: parent.path) ? parent : directoryURL
        guard let output = try? await run("rev-parse --show-toplevel", in: base) else {
            throw GitBlameUnavailable.notARepository
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw GitBlameUnavailable.notARepository
        }
        return URL(fileURLWithPath: path)
    }

    /// 把 git 的致命输出归类为「预期不可用」，不能识别的返回 nil（视为真实故障）。
    private static func unavailableReason(for error: GitClientError) -> GitBlameUnavailable? {
        switch error {
        case .notGitRepository:
            return .notARepository
        case .outputError(let message):
            let lower = message.lowercased()
            if lower.contains("does not have any commits yet")
                || lower.contains("no such ref: head")
                || lower.contains("ambiguous argument 'head'")
                || lower.contains("bad revision")
                || lower.contains("unknown revision") {
                return .noCommits
            }
            if lower.contains("is outside repository") {
                return .notARepository
            }
            // 文件在 HEAD 中但磁盘上不存在：cannot stat / No such file or directory。
            if lower.contains("cannot stat")
                || lower.contains("no such file or directory")
                || lower.contains("not a regular file")
                || lower.contains("is a directory") {
                return .fileMissing
            }
            if lower.contains("no such path")
                || lower.contains("did not match any file(s) known to git")
                || lower.contains("pathspec") {
                return .untracked
            }
            return nil
        default:
            return nil
        }
    }

    /// 取提交详情（stat + 完整说明），用于历史面板的详情区。
    func commitDetail(hash: String) async throws -> String {
        try await run("show --stat --format=fuller '\(hash)'")
    }

    // MARK: - 解析

    /// 解析 `git blame --line-porcelain` 输出为逐行记录。
    static func parseLinePorcelain(_ output: String) -> [GitBlameLine] {
        var results: [GitBlameLine] = []
        var current: (hash: String, author: String, time: Date?, summary: String, filename: String, boundary: Bool)?
        var pendingHash = ""
        var pendingBoundary = false

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            // 提交头：`<hash> <origLine> <finalLine> [<num>]`；同一提交后续行是短头（仅 hash+行号）。
            if line.count >= 40, let firstSpace = line.firstIndex(of: " ") {
                let hash = String(line[line.startIndex..<firstSpace])
                if hash.allSatisfy({ $0.isHexDigit }) {
                    // 短头没有元数据：沿用上一个提交的元数据。
                    let rest = line[line.index(after: firstSpace)...]
                    let isShortForm = rest.split(separator: " ").count == 2
                    if isShortForm, let current {
                        results.append(
                            GitBlameLine(
                                commitHash: current.hash,
                                author: current.author,
                                authorTime: current.time,
                                summary: current.summary,
                                filename: current.filename,
                                isBoundary: current.boundary
                            )
                        )
                        continue
                    }
                    pendingHash = hash
                    pendingBoundary = false
                    current = nil
                    continue
                }
            }
            if line == "boundary" {
                pendingBoundary = true
                continue
            }
            if line.hasPrefix("author ") {
                let author = String(line.dropFirst("author ".count))
                var time: Date?
                var summary = ""
                var filename = ""
                // 向前收集该提交的其余元数据，直到内容行（制表符开头）。
                while index < lines.count {
                    let meta = lines[index]
                    if meta.hasPrefix("\t") { break }
                    if meta.hasPrefix("author-time ") {
                        let value = Double(meta.dropFirst("author-time ".count)) ?? 0
                        time = Date(timeIntervalSince1970: value)
                    } else if meta.hasPrefix("summary ") {
                        summary = String(meta.dropFirst("summary ".count))
                    } else if meta.hasPrefix("filename ") {
                        filename = String(meta.dropFirst("filename ".count))
                    } else if meta == "boundary" {
                        pendingBoundary = true
                    }
                    index += 1
                }
                // 跳过内容行
                if index < lines.count, lines[index].hasPrefix("\t") {
                    index += 1
                }
                current = (pendingHash, author, time, summary, filename, pendingBoundary)
                results.append(
                    GitBlameLine(
                        commitHash: pendingHash,
                        author: author,
                        authorTime: time,
                        summary: summary,
                        filename: filename,
                        isBoundary: pendingBoundary
                    )
                )
                continue
            }
        }
        return results
    }

    /// 解析 `git log -L` 输出（`COMMIT\x1f...` 头 + diff 正文）。
    static func parseLineHistory(_ output: String) -> [GitLineHistoryEntry] {
        var entries: [GitLineHistoryEntry] = []
        var current: (hash: String, short: String, author: String, date: String, summary: String)?
        var diffLines: [String] = []

        func flush() {
            guard let current else { return }
            entries.append(
                GitLineHistoryEntry(
                    id: current.hash,
                    commitHash: current.short,
                    author: current.author,
                    date: current.date,
                    summary: current.summary,
                    diff: diffLines.joined(separator: "\n")
                )
            )
            diffLines = []
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("COMMIT\u{1F}") {
                flush()
                let parts = line.components(separatedBy: "\u{1F}")
                if parts.count >= 6 {
                    current = (parts[1], parts[2], parts[3], parts[4], parts[5])
                }
            } else if current != nil {
                diffLines.append(line)
            }
        }
        flush()
        return entries
    }
}
