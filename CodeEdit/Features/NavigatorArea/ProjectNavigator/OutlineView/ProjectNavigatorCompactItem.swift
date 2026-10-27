//
//  ProjectNavigatorCompactItem.swift
//  CodeEdit
//
//  项目导航器的紧凑目录链显示项（VS Code Compact Folders）。
//

import Foundation

/// 把「只有一个子项」的目录链合并成一行显示，避免 `src/main/java/com/...` 这类深链吃掉全部缩进。
///
/// - 链以目录结尾：行可展开，展开后显示链终点目录的子项。
/// - 链以文件结尾：行即该文件，单击打开。
final class ProjectNavigatorCompactItem {
    /// 从浅到深的链；最后一个元素是链的终点（文件夹或文件）。
    let chain: [CEWorkspaceFile]

    init(chain: [CEWorkspaceFile]) {
        self.chain = chain
    }

    /// 链的终点。
    var terminal: CEWorkspaceFile { chain[chain.count - 1] }

    /// 该行代表文件（而不是目录）。
    var isFile: Bool { !terminal.isFolder }

    /// 展示文本：`src/main/java` 或 `src/main/java/App.java`。
    var displayPath: String {
        chain.map { $0.name }.joined(separator: "/")
    }

    /// 稳定身份：以链终点的路径为键。
    var id: String { terminal.url.path }

    /// 条目 → 文件的通用映射：紧凑链取终点，其余返回自身。
    static func fileItem(from item: Any?) -> CEWorkspaceFile? {
        switch item {
        case let file as CEWorkspaceFile:
            return file
        case let compact as ProjectNavigatorCompactItem:
            return compact.terminal
        default:
            return nil
        }
    }
}
