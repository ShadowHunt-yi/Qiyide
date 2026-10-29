//
//  WikiKnowledgeSegmentation.swift
//  CodeEdit
//
//  知识单元的切分：粒度不预设，由结构自己决定。
//
//  为什么不能用「固定三段路径」当单元：
//  有的功能一个文件就是一整块（一个大 coordinator），
//  有的要几个文件才构成一个概念（Store + Graph + Entry），
//  还有的整个目录才是一个单元（Features/Wiki）。
//  固定切法必然在某个仓库上切错——要么把一个大文件切成碎片，
//  要么把一个完整功能拆成互不相干的几块。
//
//  这里的做法是自顶向下判定「内聚度」，够内聚就整块收下、停止下钻：
//    1. 规模适配（文件数、总字节在合理区间）
//    2. 命名亲和（文件名共享词干，如 WikiEntry/WikiStore/WikiGraph）
//    3. 结构收敛（子目录不多，说明它是单元而不是容器）
//  三项加权决定「能不能作为一个单元」，不能就下钻；下钻到底就是文件级。
//
//  这样同一个仓库里三种粒度可以共存，而且每个单元的判定理由都能说清。
//

import Foundation

enum WikiKnowledgeSegmentation {

    /// 单个单元的文件数上限。超过说明它是容器，不是概念。
    static let maxFilesPerUnit = 36
    /// 单个单元的总字节上限，避免「文件数不多但每个都巨大」的目录被整块吞下。
    static let maxBytesPerUnit = 600_000
    /// 判定成单元的最低分。三项满分 4.5。
    static let unitThreshold = 3.0

    // MARK: 入口

    /// 把候选文件切成知识单元。
    ///
    /// 返回的顺序是「按总分降序」，调用方通常还要再按依赖图拓扑序调整。
    static func segment(files: [RepoFileCandidate]) -> [RepoModule] {
        guard !files.isEmpty else { return [] }

        var directFiles: [String: [RepoFileCandidate]] = [:]
        var allDirectories: Set<String> = [""]

        for file in files {
            directFiles[file.directory, default: []].append(file)
            // 把每一层父目录都登记下来，后面才能自顶向下遍历。
            var accumulated: [String] = []
            for component in file.directory.split(separator: "/") {
                accumulated.append(String(component))
                allDirectories.insert(accumulated.joined(separator: "/"))
            }
        }

        var children: [String: Set<String>] = [:]
        for dir in allDirectories where !dir.isEmpty {
            let parent = (dir as NSString).deletingLastPathComponent
            children[parent, default: []].insert(dir)
        }

        var units: [RepoModule] = []
        for child in (children[""] ?? []).sorted() {
            units.append(contentsOf: walk(
                directory: child,
                directFiles: directFiles,
                children: children,
                depth: 0
            ))
        }
        // 仓库根目录下的散文件（Package.swift、README 之类）。
        if let rootFiles = directFiles[""], !rootFiles.isEmpty {
            units.append(contentsOf: groupLoose(rootFiles, directory: ""))
        }

        return units.sorted { $0.totalScore > $1.totalScore }
    }

    // MARK: 递归

    private static func walk(
        directory: String,
        directFiles: [String: [RepoFileCandidate]],
        children: [String: Set<String>],
        depth: Int
    ) -> [RepoModule] {
        let own = directFiles[directory] ?? []
        let subdirectories = children[directory] ?? []
        let subtreeFiles = filesUnder(directory, directFiles: directFiles, children: children)
        guard !subtreeFiles.isEmpty else { return [] }

        // 根目录永远不成单元：它是容器。
        if !directory.isEmpty {
            let assessment = assess(
                files: subtreeFiles,
                subdirectoryCount: subdirectories.count
            )
            if assessment.score >= unitThreshold {
                return [RepoModule(
                    name: directory,
                    files: subtreeFiles.sorted { $0.score > $1.score },
                    granularity: .folder,
                    cohesion: assessment.normalized
                )]
            }
        }

        // 不能整体成单元：先处理直属文件，再下钻子目录。
        var result: [RepoModule] = []
        if !own.isEmpty {
            result.append(contentsOf: groupLoose(own, directory: directory))
        }
        for child in subdirectories.sorted() {
            result.append(contentsOf: walk(
                directory: child,
                directFiles: directFiles,
                children: children,
                depth: depth + 1
            ))
        }
        return result
    }

    /// 直属文件在目录未能整体成单元时的归并。
    ///
    /// 数量少就作为一个「文件组」单元——它们共享同一个目录，本身就是一个弱边界；
    /// 数量多且命名不一致说明彼此无关，按文件逐个成单元。
    private static func groupLoose(
        _ files: [RepoFileCandidate],
        directory: String
    ) -> [RepoModule] {
        guard !files.isEmpty else { return [] }

        if files.count == 1 {
            let file = files[0]
            return [RepoModule(
                name: file.path,
                files: [file],
                granularity: .singleFile,
                cohesion: 1
            )]
        }

        let affinity = namingAffinity(files)
        if files.count <= 8 || affinity >= 0.5 {
            return [RepoModule(
                name: directory.isEmpty ? "根目录" : directory,
                files: files.sorted { $0.score > $1.score },
                granularity: .fileGroup,
                cohesion: affinity
            )]
        }

        // 既多又散：按单个文件建单元，但每个单元的文件数可控。
        return files.map { file in
            RepoModule(
                name: file.path,
                files: [file],
                granularity: .singleFile,
                cohesion: 1
            )
        }
    }

    // MARK: 内聚度

    struct Assessment {
        /// 原始分，满分 4.5。
        var score: Double
        /// 归一化到 0...1，用于界面展示判定理由。
        var normalized: Double { min(1, max(0, score / 4.5)) }
        var reasons: [String]
    }

    static func assess(files: [RepoFileCandidate], subdirectoryCount: Int) -> Assessment {
        var score = 0.0
        var reasons: [String] = []

        let bytes = files.reduce(0) { $0 + $1.bytes }
        if files.count <= maxFilesPerUnit {
            score += 1
        } else {
            reasons.append("文件过多（\(files.count)）")
        }
        if bytes <= maxBytesPerUnit {
            score += 1
        } else {
            reasons.append("体量过大（\(bytes / 1024) KB）")
        }

        let affinity = namingAffinity(files)
        if affinity >= 0.5 {
            score += 1.5
            reasons.append("命名同源（\(Int(affinity * 100))%）")
        }

        if subdirectoryCount <= 2 {
            score += 1
            reasons.append("子目录 \(subdirectoryCount) 个")
        } else {
            reasons.append("子目录 \(subdirectoryCount) 个，偏容器")
        }

        if files.count <= 8 {
            score += 0.5
        }

        return Assessment(score: score, reasons: reasons)
    }

    /// 命名亲和：文件词干的最长公共前缀命中率。
    ///
    /// 这是一个便宜但有效的信号——`WikiStore` / `WikiGraph` / `WikiEntry` 共享 `Wiki`，
    /// 通常意味着同一概念；`AppDelegate` / `ContentView` / `main` 共享不到 3 个字符，
    /// 就不该被当成一个单元。
    static func namingAffinity(_ files: [RepoFileCandidate]) -> Double {
        guard files.count > 1 else { return 1 }
        let stems = files.map { ($0.fileName as NSString).deletingPathExtension }
        let prefix = longestCommonPrefix(stems)
        guard prefix.count >= 3 else { return 0 }
        let hit = stems.filter { $0.hasPrefix(prefix) }.count
        return Double(hit) / Double(stems.count)
    }

    static func longestCommonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first, !prefix.isEmpty else { return "" }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix
    }

    // MARK: 工具

    private static func filesUnder(
        _ directory: String,
        directFiles: [String: [RepoFileCandidate]],
        children: [String: Set<String>]
    ) -> [RepoFileCandidate] {
        var result = directFiles[directory] ?? []
        for child in children[directory] ?? [] {
            result.append(contentsOf: filesUnder(child, directFiles: directFiles, children: children))
        }
        return result
    }
}
