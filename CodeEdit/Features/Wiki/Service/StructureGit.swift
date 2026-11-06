//
//  StructureGit.swift
//  CodeEdit
//
//  结构地图用到的 git 读取：分叉点、改动文件、基准版本的文件内容。
//
//  都是只读命令。和 `WikiChangeSource` 分开放，是因为那边的输入是「给模型看的 diff 文本」，
//  这里要的是结构化的结果（哪个文件、什么状态、改名前叫什么）。
//

import Foundation

enum StructureGit {

    /// `git diff --name-status` 的一行。
    struct RawChange: Hashable, Sendable {
        enum Status: Sendable {
            case added
            case modified
            case deleted
            case renamed
        }

        var status: Status
        var path: String
        /// 改名前的路径。
        var oldPath: String?
    }

    /// `-U0` diff 里的一行改动，带行号。
    struct DiffLine: Hashable, Sendable {
        var isAddition: Bool
        /// 新增行是新文件里的行号，删除行是旧文件里的行号。
        var number: Int
        var text: String
    }

    static func run(_ arguments: [String], at root: URL) -> String? {
        // quotepath=false：中文路径原样输出，不转成八进制转义。
        WikiChangeSource.run(["-c", "core.quotepath=false"] + arguments, at: root)
    }

    private static func line(_ arguments: [String], at root: URL) -> String? {
        let text = run(arguments, at: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    // MARK: 分支

    /// 当前分支名；游离 HEAD 时返回短提交号。
    static func headName(root: URL) -> String {
        if let name = line(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root) { return name }
        return line(["rev-parse", "--short", "HEAD"], at: root) ?? "HEAD"
    }

    /// 默认拿谁当目标分支：远端的默认分支优先，其次是常见的主干名。
    static func defaultTarget(root: URL) -> String? {
        if let remoteHead = line(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], at: root) {
            return remoteHead
        }
        return ["origin/main", "origin/master", "main", "master"].first { exists($0, root: root) }
    }

    /// 可选的目标分支。当前分支自己不在里面：和自己比没有意义。
    static func targets(root: URL) -> [String] {
        let current = headName(root: root)
        let refs = run(["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes"], at: root) ?? ""
        var result = refs.split(separator: "\n").map(String.init)
            .filter { $0 != current && !$0.hasSuffix("/HEAD") && $0 != "origin" }
        if let preferred = defaultTarget(root: root), let offset = result.firstIndex(of: preferred) {
            result.remove(at: offset)
            result.insert(preferred, at: 0)
        }
        return result
    }

    static func exists(_ ref: String, root: URL) -> Bool {
        line(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], at: root) != nil
    }

    static func mergeBase(target: String, root: URL) -> String? {
        line(["merge-base", "HEAD", target], at: root)
    }

    static func commitCount(since base: String, root: URL) -> Int {
        Int(line(["rev-list", "--count", base + "..HEAD"], at: root) ?? "") ?? 0
    }

    // MARK: 改动文件

    /// 分叉点到头部的改动。`includeWorkingTree` 为真时头部是工作区（含暂存与未跟踪文件）。
    static func changes(base: String, includeWorkingTree: Bool, root: URL) -> [RawChange] {
        var arguments = ["diff", "-M", "--name-status", base]
        if !includeWorkingTree { arguments.append("HEAD") }
        var result = parseNameStatus(run(arguments, at: root) ?? "")

        if includeWorkingTree {
            let untracked = run(["ls-files", "--others", "--exclude-standard"], at: root) ?? ""
            for path in untracked.split(separator: "\n") {
                result.append(RawChange(status: .added, path: String(path)))
            }
        }
        // `.qiyide/` 是知识库自己的产物（锁定模型、条目、缓存），不是这个分支「改的代码」。
        return result.filter { !$0.path.hasPrefix(".qiyide/") }
    }

    static func parseNameStatus(_ text: String) -> [RawChange] {
        var result: [RawChange] = []
        for raw in text.split(separator: "\n") {
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let code = fields[0].first else { continue }
            switch code {
            case "A":
                result.append(RawChange(status: .added, path: fields[1]))
            case "D":
                result.append(RawChange(status: .deleted, path: fields[1]))
            case "R" where fields.count >= 3:
                result.append(RawChange(status: .renamed, path: fields[2], oldPath: fields[1]))
            case "C" where fields.count >= 3:
                // 复制：原文件还在，新路径当新增。
                result.append(RawChange(status: .added, path: fields[2]))
            default:
                result.append(RawChange(status: .modified, path: fields[1]))
            }
        }
        return result
    }

    /// 还没提交的路径（暂存区 + 工作区 + 未跟踪）。
    static func uncommittedPaths(root: URL) -> Set<String> {
        var result = Set<String>()
        for raw in (run(["status", "--porcelain"], at: root) ?? "").split(separator: "\n") where raw.count > 3 {
            let path = String(raw.dropFirst(3))
            // 改名显示为 "old -> new"，两端都算。
            if let arrow = path.range(of: " -> ") {
                result.insert(String(path[..<arrow.lowerBound]))
                result.insert(String(path[arrow.upperBound...]))
            } else {
                result.insert(path)
            }
        }
        return result
    }

    static func files(at commit: String, root: URL) -> [String] {
        (run(["ls-tree", "-r", "--name-only", commit], at: root) ?? "")
            .split(separator: "\n").map(String.init)
    }

    // MARK: 内容

    /// 一次取回多个文件在某个提交上的内容。
    ///
    /// 用 `cat-file --batch` 而不是逐个 `git show`：大重构的分支会改几百个文件，
    /// 每个文件起一个进程要好几秒，批量读只起一个。
    static func contents(of paths: [String], at commit: String, root: URL) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "cat-file", "--batch"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return [:]
        }

        // 写和读必须并行：输出管道写满时 git 会停下来等我们读，
        // 这时如果我们还卡在写输入上，两边就互相等死了。
        let request = Data((paths.map { "\(commit):\($0)" }.joined(separator: "\n") + "\n").utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            input.fileHandleForWriting.write(request)
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBatch(data, paths: paths)
    }

    /// 解析 `cat-file --batch` 的输出：每个对象是「一行头 + 内容 + 换行」，缺失的对象只有一行。
    static func parseBatch(_ data: Data, paths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = data.startIndex
        for path in paths {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[cursor..<newline], as: UTF8.self)
            cursor = data.index(after: newline)
            if header.hasSuffix(" missing") { continue }
            guard let size = Int(header.split(separator: " ").last ?? ""),
                  data.distance(from: cursor, to: data.endIndex) >= size else { break }
            let end = data.index(cursor, offsetBy: size)
            result[path] = String(decoding: data[cursor..<end], as: UTF8.self)
            // 内容后面还跟着一个换行。
            cursor = end < data.endIndex ? data.index(after: end) : end
        }
        return result
    }

    /// 一个文件相对分叉点改了哪些行（不带上下文）。
    static func changedLines(of path: String, base: String, includeWorkingTree: Bool, root: URL) -> [DiffLine] {
        var arguments = ["diff", "-U0", base]
        if !includeWorkingTree { arguments.append("HEAD") }
        arguments += ["--", path]
        return parseUnifiedDiff(run(arguments, at: root) ?? "")
    }

    static func parseUnifiedDiff(_ text: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var inHunk = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("@@") {
                // @@ -12,3 +14,4 @@
                let fields = raw.split(separator: " ")
                guard fields.count >= 3 else { continue }
                oldNumber = Int(fields[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                newNumber = Int(fields[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                inHunk = true
            } else if !inHunk {
                continue
            } else if raw.hasPrefix("+") {
                result.append(DiffLine(isAddition: true, number: newNumber, text: String(raw.dropFirst())))
                newNumber += 1
            } else if raw.hasPrefix("-") {
                result.append(DiffLine(isAddition: false, number: oldNumber, text: String(raw.dropFirst())))
                oldNumber += 1
            }
        }
        return result
    }
}
