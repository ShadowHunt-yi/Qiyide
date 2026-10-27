//
//  GitChangedFileLabel.swift
//  CodeEdit
//
//  Created by Khan Winter on 8/23/24.
//

import SwiftUI

struct GitChangedFileLabel: View {
    @EnvironmentObject private var workspace: WorkspaceDocument
    @EnvironmentObject private var sourceControlManager: SourceControlManager

    let file: GitChangedFile

    var body: some View {
        Label {
            displayName
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            // 同上：渲染不建树，未索引到就用系统图标兜底。
            if let ceFile = workspace.workspaceFileManager?.getFile(file.ceFileKey) {
                Image(nsImage: ceFile.nsIcon)
                    .renderingMode(.template)
            } else {
                Image(systemName: FileIcon.fileIcon(fileType: nil))
                    .renderingMode(.template)
            }
        }
    }

    /// 改动列表的展示文本：`目录/文件名`。
    ///
    /// 只显示文件名时，深目录或多仓库下同名文件完全无法区分，
    /// 用户会误以为扫描出了重复条目。
    private var displayName: Text {
        let name = file.fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = relativeDirectory
        guard !directory.isEmpty else { return Text(name) }
        return Text(directory + "/").foregroundColor(.secondary) + Text(name)
    }

    /// 文件相对当前仓库根的目录部分；文件不在仓库内时退回父目录名。
    private var relativeDirectory: String {
        let filePath = file.fileURL.standardizedFileURL.path
        let rootPath = sourceControlManager.workspaceURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            if let lastSlash = relative.lastIndex(of: "/") {
                return String(relative[..<lastSlash])
            }
            return ""
        }
        return file.fileURL.deletingLastPathComponent().lastPathComponent
    }
}

// 用 PreviewProvider 而不是 #Preview 宏：
// 命令行构建下该宏的 swift-plugin-server 偶发 "malformed response" 导致整包编译失败，
// PreviewProvider 不依赖宏，画布预览能力相同。
#if DEBUG
struct GitChangedFileLabel_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            GitChangedFileLabel(file: GitChangedFile(
                status: .modified,
                stagedStatus: .none,
                fileURL: URL(filePath: "/Users/CodeEdit/app.jsx"),
                originalFilename: nil
            ))
            .environmentObject(SourceControlManager(workspaceURL: URL(filePath: "/Users/CodeEdit"), editorManager: .init()))
            .environmentObject(WorkspaceDocument())

            GitChangedFileLabel(file: GitChangedFile(
                status: .none,
                stagedStatus: .renamed,
                fileURL: URL(filePath: "/Users/CodeEdit/app.jsx"),
                originalFilename: "app2.jsx"
            ))
            .environmentObject(SourceControlManager(workspaceURL: URL(filePath: "/Users/CodeEdit"), editorManager: .init()))
            .environmentObject(WorkspaceDocument())
        }.padding()
    }
}
#endif
