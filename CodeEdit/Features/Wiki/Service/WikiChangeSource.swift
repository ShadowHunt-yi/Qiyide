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
        guard let status = run(["status", "--porcelain", "-z", "--untracked-files=all"], at: root) else { return nil }
        let records = status.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [String] = [], untracked: [String] = []
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            guard record.count >= 4 else { continue }
            let state = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            if state.contains("R") || state.contains("C") { index += 1 } // -z 中下一段是旧路径。
            guard !path.hasPrefix(".qiyide/"), !path.hasPrefix(".workflow/") else { continue }
            files.append(path)
            if state == "??" { untracked.append(path) }
        }
        files = Array(Set(files)).sorted()
        guard !files.isEmpty else { return nil }
        var input = WikiCurationInput(subject: "未提交改动（\(files.count) 个文件）", files: files, signals: [], diff: "",
                                      basis: "当前工作区补丁与新文件片段的观察，不是业务意图证明")
        do {
            let sources = try WikiGenerationSources.capture(paths: files, root: root, allowMissing: true)
            // diff HEAD 已包含暂存与未暂存，不能再把 --cached 同一段重复拼一次。
            guard let diff = run(["diff", "HEAD", "--unified=3"], at: root) else {
                throw WikiGenerationError.unreadableSource("工作区补丁")
            }
            var sections = [diff]
            for path in untracked {
                let read = try WikiGenerationSources.read(path: path, root: root)
                guard sources.first(where: { $0.path == path })?.digest == read.source.digest,
                      let text = String(data: read.data, encoding: .utf8) else { throw WikiGenerationError.changedSource(path) }
                sections.append("=== 新文件 \(path) ===\n" + String(text.prefix(3_000)))
            }
            try WikiGenerationSources.validate(sources, root: root)
            input.diff = String(sections.joined(separator: "\n\n").prefix(400_000))
            input.sourceSnapshots = sources
        } catch { input.readIssue = error.localizedDescription }
        return input
    }

    /// 最近一次提交。工作区干净时，这是最接近「刚写完的代码」的输入。
    static func lastCommit(root: URL) -> WikiCurationInput? {
        guard let revision = run(["rev-parse", "HEAD"], at: root)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty else { return nil }
        let subject = (run(["log", "-1", "--pretty=format:%s", revision], at: root) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let numstat = run(["show", "--numstat", "--format=", revision], at: root) ?? ""
        let files: [String] = numstat
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 3 else { return nil }
                return String(parts[2]).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }

        var input = WikiCurationInput(subject: "最近提交：\(subject)", files: files, signals: [], diff: "",
                                      basis: "历史提交 \(revision) 的改动观察，不代表当前工作区已经实现；必须人工核对")
        do {
            let sources = try WikiGenerationSources.capture(paths: files, root: root, allowMissing: true)
            guard let diff = run(["show", "--format=", "--unified=3", revision], at: root) else {
                throw WikiGenerationError.unreadableSource("历史提交补丁")
            }
            try WikiGenerationSources.validate(sources, root: root)
            input.diff = String(diff.prefix(400_000)); input.sourceSnapshots = sources
        } catch { input.readIssue = error.localizedDescription }
        return input
    }

    /// 现有代码快照。用于「这段代码当初为什么这么写」这类没有对应 diff 的知识。
    static func files(root: URL, paths: [String], limit: Int = 5, perFile: Int = 3000) -> WikiCurationInput? {
        let selected = Array(Array(Set(paths)).sorted().prefix(max(0, limit)))
        guard !selected.isEmpty else { return nil }
        var sections: [String] = [], receipts: [WikiSourceSnapshot] = []
        var input = WikiCurationInput(subject: "现有代码：" + selected.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"),
            files: selected, signals: [], diff: "", basis: "选中 \(selected.count)/\(Set(paths).count) 个文件的代码片段，不代表未读取的其它文件")
        do {
            for path in selected {
                let read = try WikiGenerationSources.read(path: path, root: root)
                guard let text = String(data: read.data, encoding: .utf8) else { throw WikiGenerationError.unreadableSource(path) }
                sections.append("=== \(path) ===\n" + String(text.prefix(max(0, perFile))))
                receipts.append(read.source)
            }
            input.diff = sections.joined(separator: "\n\n"); input.sourceSnapshots = receipts
        } catch { input.readIssue = error.localizedDescription }
        return input
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
