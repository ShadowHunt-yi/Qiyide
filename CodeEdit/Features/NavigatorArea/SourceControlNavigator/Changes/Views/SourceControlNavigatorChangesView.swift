//
//  SourceControlNavigatorChangesView.swift
//  CodeEdit
//
//  Created by Nanashi Li on 2022/05/20.
//

import SwiftUI

struct SourceControlNavigatorChangesView: View {
    @EnvironmentObject var sourceControlManager: SourceControlManager

    var hasRemotes: Bool {
        !sourceControlManager.remotes.isEmpty
    }

    var hasUnsyncedCommits: Bool {
        sourceControlManager.numberOfUnsyncedCommits.ahead > 0
        || sourceControlManager.numberOfUnsyncedCommits.behind > 0
    }

    var hasCurrentBranch: Bool {
        (sourceControlManager.currentBranch != nil && sourceControlManager.currentBranch?.upstream == nil)
    }

    var hasChanges: Bool {
        !sourceControlManager.changedFiles.isEmpty
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if hasChanges || !hasRemotes || (!hasChanges && (hasUnsyncedCommits || hasCurrentBranch)) {
                VStack(spacing: 8) {
                    Divided {
                        if hasRemotes && (hasUnsyncedCommits || hasCurrentBranch) {
                            SourceControlNavigatorSyncView(sourceControlManager: sourceControlManager)
                        }
                        if hasChanges {
                            SourceControlNavigatorChangesCommitView()
                        }
                        if !hasRemotes {
                            SourceControlNavigatorNoRemotesView()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }
            if hasChanges {
                SourceControlNavigatorChangesList()
            } else {
                CEContentUnavailableView("No Changes")
            }
        }
        .frame(maxHeight: .infinity)
        // 以仓库路径为 key：切换仓库时重新拉取该仓库的改动与同步状态。
        .task(id: sourceControlManager.workspaceURL.path) {
            await sourceControlManager.refreshAllChangedFiles()
            await sourceControlManager.refreshNumberOfUnsyncedCommits()
            // 多根工作区下 WorkspaceView 的全局刷新只覆盖主仓库，这里补齐当前仓库。
            try? await sourceControlManager.refreshRemotes()
            try? await sourceControlManager.refreshStashEntries()
        }
    }
}
