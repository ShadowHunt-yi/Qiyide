//
//  WikiChangeSource.swift
//  CodeEdit
//
//  把「未提交改动」变成知识库的输入。
//
//  未提交的代码才是最需要沉淀的：它还没进历史，作者脑子里的判断还没写下来，
//  一旦提交完就默认「已经知道了」。
//
//  这里直接用 git 命令而不是走 SourceControlManager：知识库窗口只需要一个仓库根，
//  不值得为它把整个版本控制栈注进来。
//

import Foundation

enum WikiChangeSource {

    /// 工作区相对 HEAD 的改动。包含已暂存与未暂存，未跟踪文件只记路径不读内容。
    static func workingTree(root: URL) -> WikiCurationInput? {
        let status = run(["status", "--porcelain"], at: root) ?? ""
        let files: [String] = status
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.count > 3 else { return nil }
                let path = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                // 重命名显示为 "old -> new"，取新路径。
                if let arrow = path.range(of: " -> ") {
                    return String(path[arrow.upperBound...])
                }
                return path
            }
            .filter { !$0.isEmpty }

        guard !files.isEmpty else { return nil }

        let diff = run(["diff", "HEAD", "--unified=3"], at: root) ?? ""
        let staged = run(["diff", "--cached", "--unified=3"], at: root) ?? ""
        let combined = [diff, staged].filter { !$0.isEmpty }.joined(separator: "\n")

        let summary = files.count > 6
            ? "未提交改动（\(files.count) 个文件）"
            : "未提交改动（\(files.prefix(6).joined(separator: "、"))）"

        return WikiCurationInput(
            subject: summary,
            files: files,
            signals: [],
            // 未跟踪文件没有 diff 内容，但路径仍然有价值，标题里已经带上。
            diff: String(combined.prefix(400_000))
        )
    }


    /// 最近一次提交。工作区干净时，这是最接近「刚写完的代码」的输入。
    static func lastCommit(root: URL) -> WikiCurationInput? {
        let subject = (run(["log", "-1", "--pretty=format:%s"], at: root) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let numstat = run(["show", "--numstat", "--format=", "HEAD"], at: root) ?? ""
        let files: [String] = numstat
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { return nil }
                return String(parts[2]).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        let diff = run(["show", "--format=", "--unified=3", "HEAD"], at: root) ?? ""
        return WikiCurationInput(
            subject: "最近提交：\(subject)",
            files: files,
            signals: [],
            diff: String(diff.prefix(400_000))
        )
    }

    /// 现有代码快照。用于「这段代码当初为什么这么写」这类没有对应 diff 的知识。
    static func files(root: URL, paths: [String], limit: Int = 5, perFile: Int = 3000) -> WikiCurationInput? {
        var sections: [String] = []
        for path in paths.prefix(limit) {
            let url = root.appending(path: path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            sections.append("=== \(path) ===\n" + String(text.prefix(perFile)))
        }
        guard !sections.isEmpty else { return nil }

        let names = paths.prefix(3).map { ($0 as NSString).lastPathComponent }
        return WikiCurationInput(
            subject: "现有代码：\(names.joined(separator: "、"))",
            files: paths,
            signals: [],
            diff: sections.joined(separator: "\n\n")
        )
    }

    /// git 不可用时的原因；可用返回 nil。
    ///
    /// 「工作区没有改动」和「根本没跑起来 git」在界面上完全一样，
    /// 排查时会把这两种情况混为一谈，所以单独暴露出来。
    static func unavailableReason(root: URL) -> String? {
        guard let output = run(["rev-parse", "--is-inside-work-tree"], at: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "读不到 git：该目录不在仓库里，或无法执行 git"
        }
        return output == "true" ? nil : "这个目录不在 git 仓库里"
    }

    // MARK: 执行

    /// 执行 git 命令。`DomainAnalyzer` 也用它统计作者归属，所以不是 private。
    static func run(_ arguments: [String], at root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
