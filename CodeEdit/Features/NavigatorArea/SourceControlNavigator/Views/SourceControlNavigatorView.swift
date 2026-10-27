//
//  SourceControlNavigatorView.swift
//  CodeEdit
//
//  Created by Nanashi Li on 2022/05/20.
//

import SwiftUI

struct SourceControlNavigatorView: View {
    @EnvironmentObject private var workspace: WorkspaceDocument

    @AppSettings(\.sourceControl.general.fetchRefreshServerStatus)
    var fetchRefreshServerStatus

    var body: some View {
        if let store = workspace.sourceControlWorkspace,
           let sourceControlManager = workspace.sourceControlManager {
            VStack(spacing: 0) {
                // 多根工作区才需要仓库切换器；单根时保持原有界面不变。
                if store.repositories.count > 1 {
                    SourceControlRepositoryPicker(store: store)
                    Divider()
                }

                if store.isShowingAllRepositories {
                    SourceControlNavigatorAllChangesView(store: store)
                } else {
                    SourceControlNavigatorTabs()
                        .environmentObject(sourceControlManager)
                }
            }
            // 周期刷新挂在容器上而不是分页视图上：
            // 分页视图在切换仓库、显示/隐藏切换器时会被重建，把 `.task` 挂在它上面会让
            // 每次重建都重启一条 `git fetch`；而 `git fetch` 阻塞在管道读取上不响应取消，
            // 于是旧任务留下的进程会持续堆积（崩溃报告里可见两条并行的 fetch 线程）。
            .task(id: fetchRefreshServerStatus) {
                guard fetchRefreshServerStatus else { return }
                while !Task.isCancelled {
                    // 每轮重新读取当前仓库，切换仓库后自动跟随。
                    if let manager = workspace.sourceControlManager {
                        try? await manager.fetch()
                    }
                    // 与 VS Code 的 git.autofetch 默认值对齐（180 秒）。
                // 原先 10 秒一次等于常驻进程唤醒 + 网络开销。
                try? await Task.sleep(for: .seconds(180))
                }
            }
        }
    }
}

struct SourceControlNavigatorTabs: View {
    @EnvironmentObject var sourceControlManager: SourceControlManager
    @State private var selectedSection: Int = 0

    var body: some View {
        if sourceControlManager.isGitRepository {
            SegmentedControl(
                $selectedSection,
                options: [
                    NSLocalizedString("Changes", comment: ""),
                    NSLocalizedString("History", comment: ""),
                    NSLocalizedString("Repository", comment: "")
                ],
                prominent: true
            )
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            .padding(.horizontal, 8)
            Divider()
            if selectedSection == 0 {
                // 高频 Git 操作：获取 / 拉取 / 推送 / 储藏 / 放弃全部。
                SourceControlQuickActionsView()
                Divider()
                SourceControlNavigatorChangesView()
            }
            if selectedSection == 1 {
                SourceControlNavigatorHistoryView()
            }
            if selectedSection == 2 {
                SourceControlNavigatorRepositoryView()
            }
        } else {
            CEContentUnavailableView(
                "No Repository",
                 description: "This project is not a git repository.",
                 systemImage: "externaldrive.fill",
                 actions: {
                    Button("Initialize") {
                        Task {
                            try await sourceControlManager.initiate()
                        }
                    }
                }
            )
        }
    }
}
