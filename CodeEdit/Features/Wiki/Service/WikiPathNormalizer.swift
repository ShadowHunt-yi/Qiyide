//
//  WikiPathNormalizer.swift
//  CodeEdit
//
//  把仓库路径压成「人能读的名字」。
//
//  为什么必须有这一步：
//  实测 232 条知识的标题中位数是 122 个字符，而其中 100 个字符
//  （`saas-plus-ai-platform-app/src/main/java/com/jd/home/shj/server/...`）
//  在每一条里都一模一样——它不是名字，是全仓库共享的噪音。
//
//  剥法：先求所有路径的最长公共目录前缀，再剥掉 `src/main/java` 这类
//  语言约定段。剥完剩下的 `agent/memory/mapper` 才是语义本身。
//
//  纯函数，不读文件、不调模型，可以随每次扫描重算。
//

import Foundation

enum WikiPathNormalizer {

    /// 语言/构建工具约定的固定段，出现在任何仓库里都不携带语义。
    private static let boilerplateSegments: Set<String> = [
        "src", "main", "test", "tests", "java", "kotlin", "resources",
        "com", "org", "net", "io", "cn", "internal", "pkg", "lib"
    ]

    /// 把一组路径压短，返回与输入同序的短名。
    ///
    /// 关键点：**先按首段分桶，桶内各自求公共前缀**。
    /// 直接对全仓库求公共前缀是行不通的——一个仓库里同时有 `sql/`、`admin-ui/`、
    /// `xxx-app/src/main/java/...` 三类顶层目录时，公共前缀是空，等于没剥。
    ///
    /// 保证：结果互不重复（冲突时保留更多段），且每个结果都是原路径的后缀，
    /// 所以可以安全地作为「人看的名字」使用，原始路径仍然可查。
    static func normalize(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }

        let allSegments = paths.map { $0.split(separator: "/").map(String.init) }
        var buckets: [String: [Int]] = [:]
        for (index, parts) in allSegments.enumerated() {
            buckets[parts.first ?? "", default: []].append(index)
        }

        var short = Array(repeating: "", count: paths.count)
        for (_, indices) in buckets {
            let segments = indices.map { allSegments[$0] }
            // 桶里只有一条时没有参照，不剥公共前缀，只剥语言约定段。
            let common = noiseDepth(segments)
            for (offset, index) in indices.enumerated() {
                var trimmed = Array(segments[offset].dropFirst(common))
                while let first = trimmed.first,
                      trimmed.count > 1,
                      boilerplateSegments.contains(first) {
                    trimmed.removeFirst()
                }
                short[index] = trimmed.isEmpty
                    ? paths[index]
                    : trimmed.joined(separator: "/")
            }
        }

        // 全局去重：冲突时逐级加长，最多退回完整路径。
        var seen: Set<String> = []
        for index in short.indices {
            var candidate = short[index]
            var length = candidate.split(separator: "/").count
            while seen.contains(candidate) && length < allSegments[index].count {
                length += 1
                candidate = allSegments[index].suffix(length).joined(separator: "/")
            }
            seen.insert(candidate)
            short[index] = candidate
        }
        return short
    }

    /// 统计意义上的「噪音前缀」段数。
    ///
    /// 单纯求最长公共前缀不够：Java 仓库剥掉 `src/main/java/com` 之后还剩
    /// `jd/home/shj/server/saas/plus/ai/platform/app` —— 这些是组织域名，
    /// 每一条路径都带着，但它们不是公共前缀意义上的「全同」，而是「绝大多数相同」。
    ///
    /// 所以按频率判定：某一段在 ≥80% 的路径里出现在同一位置，就视为噪音剥掉。
    /// 一旦某段占比跌破 80%（比如 `agent` 只出现在 60% 的路径里），立即停止——
    /// 那才是真正把模块区分开的第一段。
    static func noiseDepth(_ segments: [[String]]) -> Int {
        guard segments.count > 1 else { return 0 }
        // 用中位深度的路径作参照：桶里只要有一条 `pom.xml` 这种两段路径，
        // 取最短就会把 limit 压到 1，整个桶都剥不干净。
        let sorted = segments.sorted { $0.count < $1.count }
        let reference = sorted[sorted.count / 2]
        // 最后一段是文件名或叶子目录名，永远不当作前缀。
        let limit = max(reference.count - 1, 0)
        var depth = 0
        while depth < limit {
            let value = reference[depth]
            let matching = segments.filter { $0.count > depth + 1 && $0[depth] == value }.count
            guard Double(matching) / Double(segments.count) >= 0.8 else { break }
            depth += 1
        }
        return depth
    }
}
