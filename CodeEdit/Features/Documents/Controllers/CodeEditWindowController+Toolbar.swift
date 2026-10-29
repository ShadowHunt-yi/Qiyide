//
//  CodeEditWindowController+Toolbar.swift
//  CodeEdit
//
//  Created by Daniel Zhu on 5/10/24.
//

import AppKit
import SwiftUI
import Combine

extension CodeEditWindowController {
    internal func setupToolbar() {
        let toolbar = NSToolbar(identifier: UUID().uuidString)
        toolbar.delegate = self
        toolbar.showsBaselineSeparator = false
        self.window?.titleVisibility = toolbarCollapsed ? .visible : .hidden
        if #available(macOS 26, *) {
            self.window?.toolbarStyle = .automatic
            toolbar.centeredItemIdentifiers = [.activityViewer, .notificationItem]
            toolbar.displayMode = .iconOnly
            self.window?.titlebarAppearsTransparent = true
        } else {
            self.window?.toolbarStyle = .unifiedCompact
            toolbar.displayMode = .labelOnly
        }
        self.window?.titlebarSeparatorStyle = .automatic
        self.window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [
            .toggleFirstSidebarItem,
            .flexibleSpace,
        ]

        if #available(macOS 26, *) {
            items += [.taskSidebarItem]
        } else {
            items += [
                .stopTaskSidebarItem,
                .startTaskSidebarItem,
            ]
        }

        items += [
            .sidebarTrackingSeparator,
            .branchPicker,
            .flexibleSpace,
        ]

        if #available(macOS 26, *) {
            items += [
                .activityViewer,
                .space,
                .notificationItem,
            ]
        } else {
            items += [
                .activityViewer,
                .notificationItem,
                .flexibleSpace,
            ]
        }

        items += [
            .flexibleSpace,
            .itemListTrackingSeparator,
            .flexibleSpace,
            .aiReviewItem,
            .toggleLastSidebarItem
        ]

        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [
            .toggleFirstSidebarItem,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .itemListTrackingSeparator,
            .toggleLastSidebarItem,
            .branchPicker,
            .activityViewer,
            .notificationItem,
            .aiReviewItem,
        ]

        if #available(macOS 26, *) {
            items += [
                .taskSidebarItem
            ]
        } else {
            items += [
                .startTaskSidebarItem,
                .stopTaskSidebarItem
            ]
        }

        return items
    }

    func toggleToolbar() {
        toolbarCollapsed.toggle()
        workspace?.addToWorkspaceState(key: .toolbarCollapsed, value: toolbarCollapsed)
        updateToolbarVisibility()
    }

    func updateToolbarVisibility() {
        if toolbarCollapsed {
            window?.titleVisibility = .visible
            window?.title = workspace?.workspaceFileManager?.folderUrl.lastPathComponent ?? "Empty"
            window?.toolbar = nil
        } else {
            window?.titleVisibility = .hidden
            setupToolbar()
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .itemListTrackingSeparator:
            guard let splitViewController else { return nil }

            return NSTrackingSeparatorToolbarItem(
                identifier: .itemListTrackingSeparator,
                splitView: splitViewController.splitView,
                dividerIndex: 1
            )
        case .toggleFirstSidebarItem:
            let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier.toggleFirstSidebarItem)
            toolbarItem.paletteLabel = " Navigator Sidebar"
            toolbarItem.toolTip = "Hide or show the Navigator"
            toolbarItem.isBordered = true
            toolbarItem.target = self
            toolbarItem.action = #selector(self.objcToggleFirstPanel)
            toolbarItem.image = NSImage(
                systemSymbolName: "sidebar.leading",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(scale: .large))

            return toolbarItem
        case .toggleLastSidebarItem:
            let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier.toggleLastSidebarItem)
            toolbarItem.paletteLabel = "Inspector Sidebar"
            toolbarItem.toolTip = "Hide or show the Inspectors"
            toolbarItem.isBordered = true
            toolbarItem.target = self
            toolbarItem.action = #selector(self.objcToggleLastPanel)
            toolbarItem.image = NSImage(
                systemSymbolName: "sidebar.trailing",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(.init(scale: .large))

            return toolbarItem
        case .stopTaskSidebarItem:
            return stopTaskSidebarItem()
        case .startTaskSidebarItem:
            return startTaskSidebarItem()
        case .branchPicker:
            guard let store = workspace?.sourceControlWorkspace else { return nil }
            let toolbarItem = NSToolbarItem(itemIdentifier: .branchPicker)
            let view = toolbarHostingView(
                ToolbarBranchPicker(
                    workspaceFileManager: workspace?.workspaceFileManager,
                    store: store
                ),
                minWidth: 120
            )
            toolbarItem.view = view
            toolbarItem.isBordered = false
            return toolbarItem
        case .activityViewer:
            return activityViewerItem()
        case .notificationItem:
            return notificationItem()
        case .aiReviewItem:
            return aiReviewItem()
        case .taskSidebarItem:
            guard #available(macOS 26, *) else {
                fatalError("Unified task sidebar item used on pre-tahoe platform.")
            }
            guard let workspace,
                    let stop = StopTaskToolbarItem(workspace: workspace) else {
                return nil
            }
            let start = StartTaskToolbarItem(workspace: workspace)

            let group = NSToolbarItemGroup(itemIdentifier: .taskSidebarItem)
            group.isBordered = true
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
            group.subitems = [stop, start]

            return group
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }

    private func stopTaskSidebarItem() -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier.stopTaskSidebarItem)

        guard let taskManager = workspace?.taskManager else { return nil }

        let view = toolbarHostingView(
            StopTaskToolbarButton(taskManager: taskManager),
            minWidth: 38
        )
        toolbarItem.view = view

        return toolbarItem
    }

    private func startTaskSidebarItem() -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier.startTaskSidebarItem)

        guard let taskManager = workspace?.taskManager else { return nil }
        guard let workspace = workspace else { return nil }

        let view = toolbarHostingView(
            StartTaskToolbarButton(taskManager: taskManager)
                .environmentObject(workspace),
            minWidth: 28
        )
        toolbarItem.view = view

        return toolbarItem
    }

    /// 工具栏里的 AI 入口。菜单之外的第二条路径——菜单藏得深，按钮不会。
    private func aiReviewItem() -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: .aiReviewItem)
        toolbarItem.paletteLabel = "AI 改动审查"
        toolbarItem.toolTip = "AI 改动审查（⌥⌘R）"
        toolbarItem.isBordered = true
        toolbarItem.target = self
        toolbarItem.action = #selector(openAIReview(_:))
        toolbarItem.image = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "AI 改动审查"
        )?.withSymbolConfiguration(.init(scale: .large))
        toolbarItem.visibilityPriority = .user
        return toolbarItem
    }

    @objc
    func openAIReview(_ sender: Any?) {
        AIReviewWindowPresenter.show(workspace: workspace)
    }

    private func notificationItem() -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: .notificationItem)
        guard let workspace = workspace else { return nil }
        let view = toolbarHostingView(
            NotificationToolbarItem().environmentObject(workspace),
            minWidth: 1
        )
        toolbarItem.view = view
        return toolbarItem
    }

    private func activityViewerItem() -> NSToolbarItem? {
        let toolbarItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier.activityViewer)
        toolbarItem.visibilityPriority = .user
        guard let workspaceSettingsManager = workspace?.workspaceSettingsManager,
              let taskNotificationHandler = workspace?.taskNotificationHandler,
              let taskManager = workspace?.taskManager
        else { return nil }

        let view = toolbarHostingView(
            ActivityViewer(
                workspaceFileManager: workspace?.workspaceFileManager,
                workspaceSettingsManager: workspaceSettingsManager,
                taskNotificationHandler: taskNotificationHandler,
                taskManager: taskManager
            )
        )

        // 650 只是「够宽时」的期望值，压低优先级让工具栏收回时能压缩；
        // 200 是可用性下限。宽度只在还没有内容时生效，不参与高度测量。
        let weakWidth = view.widthAnchor.constraint(equalToConstant: 650)
        weakWidth.priority = .defaultLow
        let strongWidth = view.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        strongWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            weakWidth,
            strongWidth
        ])

        toolbarItem.view = view
        return toolbarItem
    }

    /// 工具栏里的 SwiftUI 视图统一入口。
    ///
    /// 两件事必须做，缺一件 AppKit 就会在每次启动时刷
    /// "view was automatically measured but had an ambiguous height or width
    /// ... frame size had a zero height or width"：
    /// 1. 打开 `sizingOptions` 并拿到内容的理想尺寸，高度和宽度都别有歧义；
    /// 2. 交给 `NSToolbarItem` 之前先塞一个非零 frame——AppKit 做第一次
    ///    自动测量时读的是 view 当前的 frame，0×0 的视图量出来就是「歧义尺寸」。
    ///
    /// 高度不写死成 22：活动栏这类内容本身就比标准行高高（实测 36pt），
    /// 压到 22 会把内容裁掉。这里按内容真实尺寸走，只有量不出来时才兜底。
    ///
    /// `translatesAutoresizingMaskIntoConstraints = false` 也是必需的：
    /// 否则自动转换出来的约束会和下面手动加的宽度约束打架。
    private func toolbarHostingView<Content: View>(
        _ content: Content,
        minWidth: CGFloat = 0
    ) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        view.translatesAutoresizingMaskIntoConstraints = false
        if minWidth > 0 {
            let widthConstraint = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
            widthConstraint.priority = .defaultHigh
            widthConstraint.isActive = true
        }
        let ideal = view.intrinsicContentSize
        let resolvedHeight: CGFloat = (ideal.height > 0 && ideal.height.isFinite) ? ideal.height : 22
        let resolvedWidth: CGFloat = (ideal.width > 0 && ideal.width.isFinite) ? ideal.width : 1
        view.frame = NSRect(
            x: 0,
            y: 0,
            width: max(resolvedWidth, minWidth, 1),
            height: resolvedHeight
        )
        return view
    }
}
