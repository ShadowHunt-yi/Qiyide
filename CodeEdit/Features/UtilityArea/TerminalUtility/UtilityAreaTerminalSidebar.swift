//
//  UtilityAreaTerminalSidebar.swift
//  CodeEdit
//
//  Created by Khan Winter on 8/19/24.
//

import OSLog
import SwiftUI

/// The view that displays the list of available terminals in the utility area.
/// See ``UtilityAreaTerminalView`` for use.
struct UtilityAreaTerminalSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceDocument
    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.qiyide",
        category: "Terminal"
    )

    /// 终端启动目录候选。
    ///
    /// 多根工作区下每个根目录是一个独立项目，终端必须能指定在哪个仓库启动；
    /// 单根工作区只有一个候选项，直接创建、不打扰用户（与 VS Code 行为一致）。
    /// 展示名优先复用源码管理面板的仓库名（重名时会带父目录前缀，与其保持一致）。
    private var repositoryRoots: [(id: String, name: String, url: URL)] {
        let roots = workspace.workspaceFileManager?.rootUrls ?? []
        if roots.isEmpty {
            guard let fileURL = workspace.fileURL else { return [] }
            return [(fileURL.standardizedFileURL.path, fileURL.lastPathComponent, fileURL)]
        }
        let store = workspace.sourceControlWorkspace
        return roots.map { url in
            let id = url.standardizedFileURL.path
            let name = store?.repositories.first(where: { $0.id == id })?.displayName
                ?? url.lastPathComponent
            return (id, name, url)
        }
    }

    /// 工作区是否有多个根目录（即多个可选仓库）。
    private var isMultiRoot: Bool { repositoryRoots.count > 1 }

    private func createTerminal(in url: URL, shell: Shell? = nil) {
        // 记录一次，便于无法现场复现时确认「是否走到选择分支、目标是谁」。
        logger.debug(
            "新建终端 target=\(url.path, privacy: .public) shell=\(shell?.rawValue ?? "default", privacy: .public)"
        )
        utilityAreaViewModel.addTerminal(shell: shell, rootURL: url)
    }

    /// 单根工作区（或自动补位）直接创建：使用第一个根目录。
    private func createTerminalAtPrimaryRoot(shell: Shell? = nil) {
        guard let first = repositoryRoots.first else { return }
        createTerminal(in: first.url, shell: shell)
    }

    /// 仓库列表按钮。多根工作区用它构成选择菜单。
    @ViewBuilder
    private func repositoryButtons(shell: Shell?) -> some View {
        ForEach(repositoryRoots, id: \.id) { root in
            Button(root.name) {
                createTerminal(in: root.url, shell: shell)
            }
        }
    }

    var body: some View {
        List(selection: $utilityAreaViewModel.selectedTerminals) {
            ForEach(utilityAreaViewModel.terminals, id: \.self.id) { terminal in
                UtilityAreaTerminalTab(
                    terminal: terminal,
                    removeTerminals: utilityAreaViewModel.removeTerminals,
                    isSelected: utilityAreaViewModel.selectedTerminals.contains(terminal.id),
                    selectedIDs: utilityAreaViewModel.selectedTerminals
                )
                .tag(terminal.id)
                .listRowSeparator(.hidden)
            }
            .onMove { [weak utilityAreaViewModel] (source, destination) in
                utilityAreaViewModel?.reorderTerminals(from: source, to: destination)
            }
        }
        .focusedObject(utilityAreaViewModel)
        .listStyle(.automatic)
        .accentColor(.secondary)
        // 面板出现即记录一次工作区结构：排查「为什么没有出现仓库选择」时，
        // 这条日志能直接区分「只有一个根」与「多个根但 UI 未生效」。
        .onAppear {
            logger.debug(
                "终端面板 roots=\(self.repositoryRoots.count, privacy: .public) multi=\(self.isMultiRoot, privacy: .public) names=\(self.repositoryRoots.map(\.name).joined(separator: "|"), privacy: .public)"
            )
        }
        .contextMenu {
            if isMultiRoot {
                // 多根工作区：菜单直接列出仓库，选中即在该仓库创建。
                Menu("New Terminal") {
                    repositoryButtons(shell: nil)
                }
                Menu("New Terminal With Profile") {
                    Menu("Default") {
                        repositoryButtons(shell: nil)
                    }
                    Divider()
                    ForEach(Shell.allCases, id: \.self) { shell in
                        Menu(shell.rawValue) {
                            repositoryButtons(shell: shell)
                        }
                    }
                }
            } else {
                Button("New Terminal") {
                    createTerminalAtPrimaryRoot()
                }
                Menu("New Terminal With Profile") {
                    Button("Default") {
                        createTerminalAtPrimaryRoot()
                    }
                    Divider()
                    ForEach(Shell.allCases, id: \.self) { shell in
                        Button(shell.rawValue) {
                            createTerminalAtPrimaryRoot(shell: shell)
                        }
                    }
                }
            }
        }
        .onChange(of: utilityAreaViewModel.terminals) { _, newValue in
            if newValue.isEmpty {
                // 自动补位（用户关掉了最后一个终端）不打扰用户，直接用第一个根目录。
                createTerminalAtPrimaryRoot()
            }
        }
        .paneToolbar {
            PaneToolbarSection {
                // 多根工作区把「+」做成下拉菜单：点击即列出仓库，选中后创建终端。
                // 这里刻意不用 confirmationDialog——模态弹窗在工具面板里可能不呈现，
                // 菜单由 AppKit 弹出，不存在这个风险。
                if isMultiRoot {
                    Menu {
                        repositoryButtons(shell: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(NSLocalizedString("New Terminal", comment: ""))
                } else {
                    Button {
                        createTerminalAtPrimaryRoot()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                Button {
                    utilityAreaViewModel.removeTerminals(utilityAreaViewModel.selectedTerminals)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(utilityAreaViewModel.terminals.count <= 1)
                .opacity(utilityAreaViewModel.terminals.count <= 1 ? 0.5 : 1)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminals")
        .accessibilityIdentifier("terminalsList")
    }
}

#if DEBUG
struct UtilityAreaTerminalSidebar_Previews: PreviewProvider {
    static var previews: some View {
        UtilityAreaTerminalSidebar()
    }
}
#endif
