//
//  UtilityAreaTerminalSidebar.swift
//  CodeEdit
//
//  Created by Khan Winter on 8/19/24.
//

import SwiftUI

/// The view that displays the list of available terminals in the utility area.
/// See ``UtilityAreaTerminalView`` for use.
struct UtilityAreaTerminalSidebar: View {
    @EnvironmentObject private var workspace: WorkspaceDocument
    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    /// 正在等待用户选择启动目录时，待创建终端使用的 shell。
    @State private var pendingShell: Shell?
    /// 是否正在显示「选择仓库」提示。
    @State private var isPickingRepository = false

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

    /// 用户主动新建终端：多根时需要先选仓库，单根直接创建。
    /// - Parameter shell: 指定 shell；`nil` 表示使用默认 shell。
    private func createTerminal(shell: Shell? = nil) {
        let roots = repositoryRoots
        guard roots.count > 1 else {
            utilityAreaViewModel.addTerminal(shell: shell, rootURL: roots.first?.url ?? workspace.fileURL)
            return
        }
        pendingShell = shell
        isPickingRepository = true
    }

    /// 自动补位（最后一个终端被关闭时）：不弹选择器，直接用第一个根目录。
    private func createFallbackTerminal() {
        utilityAreaViewModel.addTerminal(rootURL: repositoryRoots.first?.url ?? workspace.fileURL)
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
        .contextMenu {
            Button("New Terminal") {
                createTerminal()
            }
            Menu("New Terminal With Profile") {
                Button("Default") {
                    createTerminal()
                }
                Divider()
                ForEach(Shell.allCases, id: \.self) { shell in
                    Button(shell.rawValue) {
                        createTerminal(shell: shell)
                    }
                }
            }
        }
        .onChange(of: utilityAreaViewModel.terminals) { _, newValue in
            if newValue.isEmpty {
                createFallbackTerminal()
            }
        }
        // 多根工作区：新建终端前选择目标仓库。
        .confirmationDialog(
            NSLocalizedString("New Terminal", comment: ""),
            isPresented: $isPickingRepository,
            titleVisibility: .visible
        ) {
            ForEach(repositoryRoots, id: \.id) { root in
                Button(root.name) {
                    utilityAreaViewModel.addTerminal(shell: pendingShell, rootURL: root.url)
                    pendingShell = nil
                }
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {
                pendingShell = nil
            }
        } message: {
            Text(NSLocalizedString("Choose the workspace folder the new terminal starts in.", comment: ""))
        }
        .paneToolbar {
            PaneToolbarSection {
                Button {
                    createTerminal()
                } label: {
                    Image(systemName: "plus")
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
