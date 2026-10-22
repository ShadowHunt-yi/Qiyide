//
//  SourceControlNavigatorChangesList.swift
//  CodeEdit
//
//  Created by Austin Condiff on 11/18/23.
//

import AppKit
import SwiftUI

struct SourceControlNavigatorChangesList: View {
    @EnvironmentObject var workspace: WorkspaceDocument
    @EnvironmentObject var sourceControlManager: SourceControlManager

    @State var selection = Set<GitChangedFile>()

    var body: some View {
        List($sourceControlManager.changedFiles, selection: $selection) { $file in
            GitChangedFileListView(changedFile: $file)
                .listRowSeparator(.hidden)
                .padding(.vertical, -1)
                .tag($file.wrappedValue)
        }
        .environment(\.defaultMinListRowHeight, 22)
        .contextMenu(
            forSelectionType: GitChangedFile.self,
            menu: { selectedFiles in
                if selectedFiles.count == 1,
                   let file = selectedFiles.first {
                    Group {
                        Button("View in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.fileURL.absoluteURL])
                        }
                        Button("Reveal in Project Navigator") {}
                            .disabled(true) // TODO: Implementation Needed
                        Divider()
                    }
                    Group {
                        Button("Open in New Tab") {
                            openGitFile(file)
                        }
                        Button("View Diff") {
                            GitDiffWindowPresenter.show(file: file, manager: sourceControlManager)
                        }
                        Button("Open in New Window") {}
                            .disabled(true) // TODO: Implementation Needed
                    }
                    if file.anyStatus() != .none {
                        Group {
                            Divider()
                            Button("Discard Changes in \(file.fileURL.lastPathComponent)...") {
                                sourceControlManager.discardChanges(for: file.fileURL)
                            }
                            Divider()
                        }
                    }
                } else {
                    EmptyView()
                }
            },
            // double-click action
            primaryAction: { selectedFiles in
                if selectedFiles.count == 1,
                   let file = selectedFiles.first {
                    openGitFile(file)
                }
            }
        )
        .onChange(of: selection) { _, newSelection in
            if newSelection.count == 1,
               let file = newSelection.first {
                openGitFile(file)
            }
        }
    }

    private func openGitFile(_ file: GitChangedFile) {
        // 文件树尚未索引到该文件时（多根工作区、新建文件常见），直接用 URL 构造兜底。
        // 原实现在这里静默 return，是「点击改动文件无反应」的直接来源。
        let ceFile = workspace.workspaceFileManager?.getFile(file.ceFileKey, createIfNotFound: true)
            ?? CEWorkspaceFile(url: file.fileURL)
        DispatchQueue.main.async {
            workspace.editorManager?.openTab(item: ceFile, asTemporary: true)
        }
    }
}
