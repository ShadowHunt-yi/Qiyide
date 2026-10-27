//
//  GitChangedFileListView.swift
//  CodeEdit
//
//  Created by Nanashi Li on 2022/05/20.
//

import SwiftUI

/// A view to display a changed file's information in a list view. Optionally displays the staged status.
struct GitChangedFileListView: View {
    @AppSettings(\.general.fileIconStyle)
    private var fileIconStyle
    @EnvironmentObject private var workspace: WorkspaceDocument
    @EnvironmentObject private var sourceControlManager: SourceControlManager
    @Binding private var changedFile: GitChangedFile

    @State private var staged: Bool
    private let showStaged: Bool

    init(changedFile: Binding<GitChangedFile>, showStaged: Bool = true) {
        self._changedFile = changedFile
        self.showStaged = showStaged
        self._staged = State(initialValue: changedFile.wrappedValue.isStaged)
    }

    var body: some View {
        HStack(spacing: 6) {
            if showStaged {
                Toggle("", isOn: $staged)
                    .labelsHidden()
                    .onChange(of: staged) { _, newStaged in
                        Task {
                            if changedFile.isStaged != newStaged {
                                if newStaged {
                                    try await sourceControlManager.add([changedFile.fileURL])
                                } else {
                                    try await sourceControlManager.reset([changedFile.fileURL])
                                }
                            }
                        }
                    }
            }

            GitChangedFileLabel(file: changedFile)
            Spacer()
            Text(changedFile.anyStatus().description)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
                .frame(minWidth: 10, alignment: .center)
        }
        .listItemTint(listItemTint)
        .help(changedFile.fileURL.relativePath)
        // 拖拽到编辑区打开完整文件；与单击（显示差异）互不影响。
        .onDrag {
            NSItemProvider(object: changedFile.fileURL as NSURL)
        }
        .onChange(of: changedFile.isStaged) { _, newStaged in
            staged = newStaged
        }
    }

    private var listItemTint: Color {
        // 渲染路径只查缓存：createIfNotFound 会为每个可见行做文件系统索引，滚动时卡顿。
        if let ceFile = workspace.workspaceFileManager?.getFile(changedFile.ceFileKey) {
            iconForegroundColor(ceFile)
        } else {
            iconForegroundColor(nil)
        }
    }

    private func iconForegroundColor(_ file: CEWorkspaceFile?) -> Color {
        switch fileIconStyle {
        case .color:
            if let file {
                return file.iconColor
            } else {
                return FileIcon.iconColor(fileType: nil)
            }
        case .monochrome:
            return Color("CoolGray")
        }
    }
}
