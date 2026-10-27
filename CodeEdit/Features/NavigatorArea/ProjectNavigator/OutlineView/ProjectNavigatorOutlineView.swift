//
//  OutlineView.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 05.04.22.
//

import SwiftUI
import Combine

/// Wraps an ``OutlineViewController`` inside a `NSViewControllerRepresentable`
struct ProjectNavigatorOutlineView: NSViewControllerRepresentable {

    @EnvironmentObject var workspace: WorkspaceDocument
    @EnvironmentObject var editorManager: EditorManager

    @StateObject var prefs: Settings = .shared

    typealias NSViewControllerType = ProjectNavigatorViewController

    func makeNSViewController(context: Context) -> ProjectNavigatorViewController {
        let controller = ProjectNavigatorViewController()
        controller.workspace = workspace
        controller.iconColor = prefs.preferences.general.fileIconStyle
        controller.editor = editorManager.activeEditor
        workspace.workspaceFileManager?.addObserver(context.coordinator)

        context.coordinator.controller = controller

        return controller
    }

    func updateNSViewController(_ nsViewController: ProjectNavigatorViewController, context: Context) {
        nsViewController.iconColor = prefs.preferences.general.fileIconStyle
        nsViewController.rowHeight = prefs.preferences.general.projectNavigatorSize.rowHeight
        nsViewController.fileExtensionsVisibility = prefs.preferences.general.fileExtensionsVisibility
        nsViewController.shownFileExtensions = prefs.preferences.general.shownFileExtensions
        nsViewController.hiddenFileExtensions = prefs.preferences.general.hiddenFileExtensions
        /// if the window becomes active from background, it will restore the selection to outline view.
        // 仅在选中目标变化时更新：每次 SwiftUI 刷新都重跑 select/reveal 会做
        // 整链展开与行查找，大树下是导航器卡顿的来源之一。
        let selectionID = workspace.editorManager?.activeEditor.selectedTab?.file.id
        if context.coordinator.lastSelectionID != selectionID {
            context.coordinator.lastSelectionID = selectionID
            nsViewController.updateSelection(itemID: selectionID)
        }
        return
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    class Coordinator: NSObject, CEWorkspaceFileManagerObserver {
        init(_ workspace: WorkspaceDocument) {
            self.workspace = workspace
            super.init()

            workspace.listenerModel.$highlightedFileItem
                .sink(receiveValue: { [weak self] fileItem in
                    guard let fileItem else {
                        return
                    }
                    self?.controller?.reveal(fileItem)
                })
                .store(in: &cancellables)
            workspace.editorManager?.tabBarTabIdSubject
                .sink { [weak self] editorInstance in
                    self?.controller?.updateSelection(itemID: editorInstance?.file.id)
                }
                .store(in: &cancellables)
            workspace.$navigatorFilter
                .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    self?.controller?.handleFilterChange()
                }
                .store(in: &cancellables)
            Publishers.Merge3(
                workspace.$sourceControlFilter,
                workspace.$sortFoldersOnTop,
                workspace.$navigatorRecentsFilter
            )
                .throttle(for: 0.1, scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in
                    self?.controller?.handleFilterChange()
                }
                .store(in: &cancellables)
        }

        var cancellables: Set<AnyCancellable> = []
        /// 上次同步到树的选中目标，用于跳过重复的 updateSelection。
        var lastSelectionID: String?
        weak var workspace: WorkspaceDocument?
        weak var controller: ProjectNavigatorViewController?

        func fileManagerUpdated(updatedItems: Set<CEWorkspaceFile>) {
            guard let outlineView = controller?.outlineView else { return }
            let selectedRows = outlineView.selectedRowIndexes.compactMap({ outlineView.item(atRow: $0) })

            // If some text view inside the outline view is first responder right now, push the update off
            // until editing is finished using the `shouldReloadAfterDoneEditing` flag.
            if outlineView.window?.firstResponder !== outlineView
                && outlineView.window?.firstResponder is NSTextView
                && (outlineView.window?.firstResponder as? NSView)?.isDescendant(of: outlineView) == true {
                controller?.shouldReloadAfterDoneEditing = true
            } else {
                // 根节点集合发生变化（增删附加根目录）时必须整体刷新，逐项 reloadItem 不适用于顶层。
                let roots = Set(workspace?.workspaceFileManager?.rootItems ?? [])
                if updatedItems.isEmpty || !updatedItems.isDisjoint(with: roots) {
                    outlineView.reloadData()
                    controller?.expandRootItems()
                } else {
                    for item in updatedItems {
                        outlineView.reloadItem(item, reloadChildren: true)
                    }
                }
            }

            // 文件增删/改名后展示子项已失效（目录可能多出或减少条目）。
            controller?.invalidateDisplayChildrenCache()

            // Restore selected items where the files still exist.
            let selectedIndexes = selectedRows.compactMap({ outlineView.row(forItem: $0) }).filter({ $0 >= 0 })
            controller?.shouldSendSelectionUpdate = false
            outlineView.selectRowIndexes(IndexSet(selectedIndexes), byExtendingSelection: false)
            controller?.shouldSendSelectionUpdate = true

            // 增量插入/删除行后重新推导「无过滤结果」状态。
            // 不再挂在 viewDidLayout 上：那样每次布局都会读取 numberOfRows，
            // 与「全部展开」的大批量插入叠加会退化成 O(n²)。
            controller?.updateNoResultsState()
        }

        deinit {
            workspace?.workspaceFileManager?.removeObserver(self)
        }
    }
}
