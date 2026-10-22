//
//  SourceControlQuickActionsView.swift
//  CodeEdit
//
//  「更改」页签下方的高频 Git 操作条。
//

import SwiftUI

/// 源代码管理面板「更改」页签下方的一排快捷按钮。
///
/// 只放**不需要额外输入**就能发起的操作；需要选择远端、分支或填写信息的，
/// 复用既有的弹窗（`pushSheetIsPresented` 等），避免在面板里重复实现一套表单。
struct SourceControlQuickActionsView: View {
    @EnvironmentObject private var sourceControlManager: SourceControlManager

    /// 获取操作进行中，用于禁用按钮并显示进度。
    @State private var isFetching: Bool = false

    private var hasRemotes: Bool {
        !sourceControlManager.remotes.isEmpty
    }

    private var hasChanges: Bool {
        !sourceControlManager.changedFiles.isEmpty
    }

    private var canPush: Bool {
        hasRemotes && sourceControlManager.currentBranch != nil
    }

    /// 可合并进当前分支的本地分支（排除当前分支）。
    private var mergeableBranches: [GitBranch] {
        sourceControlManager.orderedLocalBranches.filter {
            $0 != sourceControlManager.currentBranch
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            quickButton(
                systemImage: "arrow.triangle.2.circlepath",
                help: "Fetch Changes",
                enabled: !isFetching
            ) {
                fetch()
            }

            quickButton(
                systemImage: "arrow.down.to.line",
                help: "Pull",
                enabled: hasRemotes
            ) {
                sourceControlManager.pullSheetIsPresented = true
            }

            quickButton(
                systemImage: "arrow.up.to.line",
                help: "Push",
                enabled: canPush
            ) {
                sourceControlManager.pushSheetIsPresented = true
            }

            quickMenu(
                systemImage: "arrow.triangle.merge",
                help: "Merge into Current Branch...",
                enabled: !mergeableBranches.isEmpty
            ) {
                ForEach(mergeableBranches, id: \.id) { branch in
                    Button(branch.name) {
                        merge(branch)
                    }
                }
            }

            Divider()
                .frame(height: 12)
                .padding(.horizontal, 3)

            quickButton(
                systemImage: "archivebox",
                help: "Stash Changes...",
                enabled: hasChanges
            ) {
                if hasChanges {
                    sourceControlManager.stashSheetIsPresented = true
                } else {
                    sourceControlManager.noChangesToStashAlertIsPresented = true
                }
            }

            quickButton(
                systemImage: "trash",
                help: "Discard All Changes...",
                enabled: hasChanges
            ) {
                if hasChanges {
                    sourceControlManager.discardAllAlertIsPresented = true
                } else {
                    sourceControlManager.noChangesToDiscardAlertIsPresented = true
                }
            }

            Spacer(minLength: 0)

            if isFetching {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private func quickButton(
        systemImage: String,
        help: LocalizedStringKey,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }

    /// 与 ``quickButton`` 同款外观的下拉按钮：点击展开候选分支。
    private func quickMenu<Content: View>(
        systemImage: String,
        help: LocalizedStringKey,
        enabled: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
        .help(help)
    }

    private func merge(_ branch: GitBranch) {
        Task {
            do {
                try await sourceControlManager.merge(branch: branch)
            } catch {
                await sourceControlManager.handleMergeFailure(error)
            }
        }
    }

    private func fetch() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            try? await sourceControlManager.fetch()
            await MainActor.run {
                isFetching = false
            }
        }
    }
}
