//
//  SourceControlNavigatorAllChangesView.swift
//  CodeEdit
//
//  多仓库聚合的改动列表。
//

import SwiftUI

/// 把工作区内所有仓库的改动汇总到一个列表中，按仓库分区。
///
/// 该视图只用于**浏览**：点击仓库标题会切换到该仓库的完整视图（提交、暂存、历史）。
/// 暂存与提交仍然在单仓库视图中完成，避免同一个提交框同时对应多个仓库而产生歧义。
struct SourceControlNavigatorAllChangesView: View {
    @ObservedObject var store: SourceControlWorkspace
    @EnvironmentObject private var workspace: WorkspaceDocument

    var body: some View {
        VStack(spacing: 0) {
            if store.repositoriesWithChanges.isEmpty {
                CEContentUnavailableView("No Changes")
            } else {
                List {
                    ForEach(store.repositoriesWithChanges) { repository in
                        Section {
                            ForEach(repository.manager.changedFiles) { file in
                                HStack(spacing: 6) {
                                    GitChangedFileLabel(file: file)
                                        .environmentObject(repository.manager)
                                    Spacer(minLength: 4)
                                    Text(file.anyStatus().description)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                                .listRowSeparator(.hidden)
                                .padding(.vertical, -1)
                                .contextMenu {
                                    Button("View Diff") {
                                        GitDiffWindowPresenter.show(file: file, manager: repository.manager)
                                    }
                                    Button("Open in New Tab") {
                                        let ceFile = workspace.workspaceFileManager?.getFile(
                                            file.ceFileKey,
                                            createIfNotFound: true
                                        ) ?? CEWorkspaceFile(url: file.fileURL)
                                        workspace.editorManager?.openTab(item: ceFile, asTemporary: true)
                                    }
                                }
                            }
                        } header: {
                            repositoryHeader(repository)
                        }
                    }
                }
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
        .frame(maxHeight: .infinity)
        .task {
            // 汇总视图需要所有仓库的最新状态，逐个刷新。
            for repository in store.repositories {
                await repository.manager.refreshAllChangedFiles()
                await repository.manager.refreshCurrentBranch()
                // 每个仓库的远程信息独立刷新，避免次要仓库显示「无远程」。
                try? await repository.manager.refreshRemotes()
            }
        }
    }

    private func repositoryHeader(_ repository: SourceControlWorkspace.Repository) -> some View {
        Button {
            store.select(repository.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(repository.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let branch = repository.manager.currentBranch?.name, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(repository.manager.changedFiles.count)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Show this repository", comment: ""))
    }
}
