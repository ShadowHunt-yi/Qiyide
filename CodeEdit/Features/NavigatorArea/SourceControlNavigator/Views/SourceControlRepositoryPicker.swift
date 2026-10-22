//
//  SourceControlRepositoryPicker.swift
//  CodeEdit
//
//  多根工作区下的仓库切换器。
//

import SwiftUI

/// 显示在源代码管理面板顶部的仓库切换器。
///
/// 单根工作区时不显示（只有一个仓库，无需切换）；多根工作区时列出全部仓库，
/// 并显示整个工作区的改动文件总数。
struct SourceControlRepositoryPicker: View {
    @ObservedObject var store: SourceControlWorkspace

    /// 「全部仓库」聚合视图的选中标识。
    private static let allRepositoriesID = "__all_repositories__"

    private var title: String {
        if store.isShowingAllRepositories {
            return NSLocalizedString("All Repositories", comment: "")
        }
        return store.activeRepository?.displayName
            ?? NSLocalizedString("All Repositories", comment: "")
    }

    /// 供 `Picker` 使用的选择绑定，把「全部仓库」与具体仓库统一成字符串标识。
    private var selection: Binding<String> {
        Binding(
            get: {
                if store.isShowingAllRepositories {
                    return Self.allRepositoriesID
                }
                return store.activeRepositoryID ?? Self.allRepositoriesID
            },
            set: { newValue in
                if newValue == Self.allRepositoriesID {
                    store.showAllRepositories()
                } else {
                    store.select(newValue)
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker(selection: selection) {
                    Text(NSLocalizedString("All Repositories", comment: ""))
                        .tag(Self.allRepositoriesID)
                    ForEach(store.repositories) { repository in
                        Text(itemTitle(repository))
                            .tag(repository.id)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: 4)

            if store.totalChangedFiles > 0 {
                Text("\(store.totalChangedFiles)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundStyle(Color.accentColor)
                    .help(NSLocalizedString("Changed files in this workspace", comment: ""))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func itemTitle(_ repository: SourceControlWorkspace.Repository) -> String {
        var title = repository.displayName

        if let branch = repository.manager.currentBranch?.name, !branch.isEmpty {
            title += " · \(branch)"
        }

        let count = repository.manager.changedFiles.count
        if count > 0 {
            title += " (\(count))"
        }

        if !repository.manager.isGitRepository {
            title += " — " + NSLocalizedString("Not a Git repository", comment: "")
        }

        return title
    }
}
