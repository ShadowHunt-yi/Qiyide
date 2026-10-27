//
//  HistoryInspectorView.swift
//  CodeEdit
//
//  Created by Nanashi Li on 2022/03/24.
//
import SwiftUI

struct HistoryInspectorView: View {
    @AppSettings(\.sourceControl.git.showMergeCommitsPerFileLog)
    var showMergeCommitsPerFileLog

    @EnvironmentObject private var workspace: WorkspaceDocument

    @EnvironmentObject private var editorManager: EditorManager

    @ObservedObject private var model: HistoryInspectorModel

    @State var selection: GitCommit?

    /// Initialize with GitClient
    /// - Parameter gitClient: a GitClient
    init() {
        self.model = .init()
    }

    var body: some View {
        Group {
            if model.sourceControlManager != nil {
                VStack {
                    if model.commitHistory.isEmpty {
                        CEContentUnavailableView("No History")
                    } else {
                        List(selection: $selection) {
                            ForEach(model.commitHistory) { commit in
                                HistoryInspectorItemView(commit: commit, selection: $selection)
                                    .tag(commit)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            } else {
                NoSelectionInspectorView()
            }
        }
        .onReceive(editorManager.activeEditor.objectWillChange) { _ in
            Task { await syncActiveFileRepository() }
        }
        .onChange(of: editorManager.activeEditor) { _, _ in
            Task { await syncActiveFileRepository() }
        }
        .onChange(of: editorManager.activeEditor.selectedTab) { _, _ in
            Task { await syncActiveFileRepository() }
        }
        .task {
            await syncActiveFileRepository()
        }
        .onChange(of: showMergeCommitsPerFileLog) { _, _ in
            Task {
                await model.updateCommitHistory()
            }
        }
    }

    /// 让历史面板同时跟随「当前文件」与「该文件所属的仓库」。
    ///
    /// 多根工作区下 `workspace.sourceControlManager` 只代表当前活动仓库，
    /// 若正在查看另一个仓库中的文件，历史会错误地显示活动仓库的提交。
    private func syncActiveFileRepository() async {
        let fileURL = editorManager.activeEditor.selectedTab?.file.url
        let manager = fileURL.flatMap {
            workspace.sourceControlWorkspace?.manager(containingFileAt: $0)
        } ?? workspace.sourceControlManager
        await model.setWorkspace(sourceControlManager: manager)
        await model.setFile(url: fileURL?.path())
    }
}
