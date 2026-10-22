//
//  GitClient+Merge.swift
//  CodeEdit
//
//  合并分支相关命令。
//

import Foundation

extension GitClient {
    /// 把指定分支合并进当前分支。
    ///
    /// 冲突时 `git merge` 以非零状态退出，`run` 会抛出 `outputError`；
    /// 调用方随后刷新状态即可从改动列表中读到 `U`（未合并）文件。
    /// - Parameter branch: 分支名，本地分支为 `main`，远程跟踪分支为 `origin/main`。
    func merge(branch: String) async throws {
        _ = try await run("merge \"\(branch)\"")
    }

    /// 中止进行中的合并，把工作区恢复到合并前的状态。
    func abortMerge() async throws {
        _ = try await run("merge --abort")
    }

    /// 当前存在冲突的文件路径（相对仓库根目录）。
    ///
    /// 不用 `status` 里的 `U` 字符判断：`UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD` 七种组合里，
    /// 只有部分是 `U`，用 `diff --diff-filter=U` 才能覆盖全部未合并路径。
    func conflictedFiles() async -> [String] {
        guard let output = try? await run("diff --name-only --diff-filter=U") else {
            return []
        }
        return output
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 当前是否处于合并过程中（存在 `MERGE_HEAD`）。
    func isMerging() async -> Bool {
        guard let output = try? await run("rev-parse --verify MERGE_HEAD") else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
