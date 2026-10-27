//
//  OutlineViewController.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 07.04.22.
//

import AppKit
import WelcomeWindow
import SwiftUI
import OSLog

/// A `NSViewController` that handles the **ProjectNavigatorView** in the **NavigatorArea**.
///
/// Adds a ``outlineView`` inside a ``scrollView`` which shows the folder structure of the
/// currently open project.
final class ProjectNavigatorViewController: NSViewController {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "",
        category: "ProjectNavigatorViewController"
    )

    var scrollView: NSScrollView!
    var outlineView: NSOutlineView!
    var noResultsLabel: NSTextField!

    /// Gets the folder structure
    ///
    /// 多根工作区下返回所有根目录节点；单根时数组只有一个元素，行为与原先一致。
    var content: [CEWorkspaceFile] {
        workspace?.workspaceFileManager?.rootItems ?? []
    }

    /// 展开全部根目录节点，用于根集合变化后（新增/移除附加目录）刷新视图。
    func expandRootItems() {
        guard let outlineView else { return }
        for item in content {
            outlineView.expandItem(item)
        }
    }

    var filteredContentChildren: [CEWorkspaceFile: [CEWorkspaceFile]] = [:]
    /// 紧凑目录链显示项的缓存，以链终点路径为键。
    /// NSOutlineView 的展开状态绑定条目身份，缓存保证多次数据源调用返回同一实例。
    var compactItemCache: [String: ProjectNavigatorCompactItem] = [:]
    /// 路径 → 承载该文件的紧凑条目，供选中/揭示 O(1) 反查（原来是遍历整个缓存）。
    var compactItemByMemberPath: [String: ProjectNavigatorCompactItem] = [:]
    /// 每层「展示子项」的缓存（排序 + 紧凑链）。
    ///
    /// NSOutlineView 取 k 个子项时会调用 k 次 `child(index:)`，若每次都重建整层，
    /// 单层成本就是 O(k² log k)——大目录（上千项）会明显卡顿。缓存按数据「代」失效。
    var displayChildrenCache: [String: [Any]] = [:]
    var expandedItems: Set<CEWorkspaceFile> = []
    /// 「无过滤结果」状态重算的递归保护（设置 isHidden 会触发布局，布局里又会重算）。
    private var isUpdatingNoResultsState = false

    weak var workspace: WorkspaceDocument?
    weak var editor: Editor?

    var iconColor: SettingsData.FileIconStyle = .color {
        willSet {
            if newValue != iconColor {
                outlineView?.reloadData()
            }
        }
    }

    var fileExtensionsVisibility: SettingsData.FileExtensionsVisibility = .showAll
    var shownFileExtensions: SettingsData.FileExtensions = .default
    var hiddenFileExtensions: SettingsData.FileExtensions = .default

    var rowHeight: Double = 22 {
        willSet {
            if newValue != rowHeight {
                outlineView.rowHeight = newValue
                outlineView.reloadData()
            }
        }
    }

    /// This helps determine whether or not to send an `openTab` when the selection changes.
    /// Used b/c the state may update when the selection changes, but we don't necessarily want
    /// to open the file a second time.
    var shouldSendSelectionUpdate: Bool = true

    var shouldReloadAfterDoneEditing: Bool = false

    var filterIsEmpty: Bool {
        workspace?.navigatorFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    /// Setup the ``scrollView`` and ``outlineView``
    override func loadView() {
        self.scrollView = NSScrollView()
        self.scrollView.hasVerticalScroller = true
        self.view = scrollView

        self.outlineView = ProjectNavigatorNSOutlineView()
        configureOutlineView()

        scrollView.documentView = outlineView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        if #available(macOS 26, *) {
            scrollView.clipsToBounds = false
            scrollView.contentView.clipsToBounds = false
        } else {
            scrollView.contentView.contentInsets = .init(top: 10, left: 0, bottom: 0, right: 0)
        }
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        outlineView.expandItem(outlineView.item(atRow: 0))

        // 一键折叠/展开的外部入口（底部工具栏按钮、Navigate 菜单）通过通知触发，
        // 不依赖响应链，任意焦点状态下都生效。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(collapseAllFolders(_:)),
            name: .projectNavigatorCollapseAll,
            object: nil
        )

        /// Get autosave expanded items.
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? CEWorkspaceFile {
                if outlineView.isItemExpanded(item) {
                    expandedItems.insert(item)
                }
            }
        }

        /// "No Filter Results" label.
        /// 挂在 scrollView（可视区容器）而不是 outlineView（文档视图）上：
        /// 后者的高度等于整棵树的内容高度，居中后会压在某一行上（且随内容滚动）。
        noResultsLabel = NSTextField(labelWithString: NSLocalizedString("No Filter Results", comment: ""))
        noResultsLabel.isHidden = true
        noResultsLabel.font = NSFont.systemFont(ofSize: 16)
        noResultsLabel.textColor = NSColor.secondaryLabelColor
        scrollView.addSubview(noResultsLabel)
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            noResultsLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            noResultsLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func configureOutlineView() {
        if #available(macOS 26, *) {
            self.outlineView.style = .inset
            self.outlineView.clipsToBounds = false
        }
        self.outlineView.dataSource = self
        self.outlineView.delegate = self
        self.outlineView.autosaveExpandedItems = true
        self.outlineView.autosaveName = workspace?.workspaceFileManager?.folderUrl.path ?? ""
        self.outlineView.headerView = nil
        self.outlineView.menu = ProjectNavigatorMenu(self)
        self.outlineView.menu?.delegate = self
        self.outlineView.doubleAction = #selector(onItemDoubleClicked)
        self.outlineView.allowsMultipleSelection = true

        self.outlineView.setAccessibilityIdentifier("ProjectNavigator")
        self.outlineView.setAccessibilityLabel("Project Navigator")

        let column = NSTableColumn(identifier: .init(rawValue: "Cell"))
        column.title = "Cell"
        outlineView.addTableColumn(column)

        outlineView.setDraggingSourceOperationMask(.move, forLocal: false)
        outlineView.registerForDraggedTypes([.fileURL])
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        outlineView?.removeFromSuperview()
        scrollView?.removeFromSuperview()
        noResultsLabel?.removeFromSuperview()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    /// Forces to reveal the selected file through the command regardless of the auto reveal setting
    @objc
    func revealFile(_ sender: Any) {
        updateSelection(itemID: workspace?.editorManager?.activeEditor.selectedTab?.file.id, forcesReveal: true)
    }

    /// Updates the selection of the ``outlineView`` whenever it changes.
    ///
    /// Most importantly when the `id` changes from an external view.
    /// - Parameter itemID: The id of the file or folder.
    /// - Parameter forcesReveal: The boolean to indicates whether or not it should force to reveal the selected file.
    func updateSelection(itemID: String?, forcesReveal: Bool = false) {
        guard let itemID else {
            outlineView.deselectRow(outlineView.selectedRow)
            return
        }
        self.select(by: .codeEditor(itemID), forcesReveal: forcesReveal)
    }

    /// Expand or collapse the folder on double click
    @objc
    private func onItemDoubleClicked() {
        /// If there are multiples items selected, don't do anything, just like in Xcode.
        guard outlineView.selectedRowIndexes.count == 1 else { return }

        let rawItem = outlineView.item(atRow: outlineView.clickedRow)

        // 紧凑目录链：文件链双击打开文件；目录链展开/收起。
        if let compact = rawItem as? ProjectNavigatorCompactItem {
            if compact.isFile {
                if Settings[\.navigation].navigationStyle == .openInTabs {
                    workspace?.editorManager?.activeEditor.openTab(file: compact.terminal, asTemporary: false)
                }
            } else if outlineView.isItemExpanded(compact) {
                outlineView.collapseItem(compact)
            } else {
                outlineView.expandItem(compact)
            }
            return
        }

        guard let item = rawItem as? CEWorkspaceFile else { return }

        if item.isFolder {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
        } else if Settings[\.navigation].navigationStyle == .openInTabs {
            workspace?.editorManager?.activeEditor.openTab(file: item, asTemporary: false)
        }
    }

    /// Get the appropriate color for the items icon depending on the users preferences.
    /// - Parameter item: The `FileItem` to get the color for
    /// - Returns: A `NSColor` for the given `FileItem`.
    private func color(for item: CEWorkspaceFile) -> NSColor {
        if !item.isFolder && iconColor == .color {
            return NSColor(item.iconColor)
        } else {
            return .secondaryLabelColor
        }
    }

    // MARK: - 一键折叠 / 展开（类 VS Code）

    /// 一键收起所有目录（含紧凑目录链）。
    ///
    /// 与手动逐个收起等价：所有节点回到收起态，`expandedItems` 缓存同步清空，
    /// 之后手动展开单个节点不受影响。
    @objc func collapseAllFolders(_ sender: Any?) {
        let started = CFAbsoluteTimeGetCurrent()
        defer {
            PerformanceRecorder.shared.record(
                startedAt: started,
                category: .treeExpand,
                meta: ["op": "collapse", "rows": "\(outlineView.numberOfRows)"]
            )
        }
        // 关闭插入/删除动画：大量行同时变化时逐行动画会长时间占用主线程。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outlineView.beginUpdates()
            for item in content where outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item, collapseChildren: true)
            }
            outlineView.endUpdates()
        }
        expandedItems.removeAll()
        updateNoResultsState()
        outlineView.needsDisplay = true
    }

    /// 一键展开所有目录（含紧凑目录链）。
    ///
    /// 深层级一次性全部展开；大目录树下用 beginUpdates 批量更新避免逐项重绘。
    func handleFilterChange() {
        rebuildRecentsFilterPaths()
        filteredContentChildren.removeAll()
        invalidateDisplayChildrenCache()
        invalidateCompactItems()
        outlineView.reloadData()

        guard let workspace else { return }

        /// If the filter is empty, show all items and restore the expanded state.
        // 「最近文件」过滤同样需要展开匹配路径，否则结果藏在折叠目录里会被误判为无结果。
        if workspace.sourceControlFilter || workspace.navigatorRecentsFilter || !filterIsEmpty {
            outlineView.autosaveExpandedItems = false
            /// Expand all items for search.
            outlineView.expandItem(outlineView.item(atRow: 0), expandChildren: true)
        } else {
            restoreExpandedState()
            outlineView.autosaveExpandedItems = true
        }

        updateNoResultsState()
    }

    /// 清空「展示子项」缓存。文件增删、重载都会调用；
    /// 不动紧凑条目缓存——否则每次文件变动都会换掉条目身份，已展开的链条目会被折叠。
    func invalidateDisplayChildrenCache() {
        displayChildrenCache.removeAll()
    }

    /// 清空紧凑目录链条目缓存（过滤变化、结构性文件操作时使用）。
    func invalidateCompactItems() {
        compactItemCache.removeAll()
        compactItemByMemberPath.removeAll()
    }

    /// 当前是否有任何过滤维度生效（搜索文本、源代码管理、最近文件）。
    private var isFiltering: Bool {
        guard let workspace else { return false }
        return !filterIsEmpty || workspace.sourceControlFilter || workspace.navigatorRecentsFilter
    }

    /// 统一刷新「无过滤结果」提示与树的可见性。
    ///
    /// 关键不变式：**标签与树互斥**。此前的实现只切换标签的 `isHidden`，
    /// 一旦行数在「未走 reloadData 的路径」上变化（文件监听的 `reloadItem`、
    /// 展开/折叠），标签就不会重新推导，于是残留并压住文件行（截图现象）。
    /// 现在改为：过滤中且树上除根行外无内容 → 显示提示并隐藏整棵树；
    /// 其余情况一律恢复树、隐藏提示。两条分支互斥，任何状态下都不可能同时可见。
    func updateNoResultsState() {
        guard !isUpdatingNoResultsState else { return }

        guard let noResultsLabel, let outlineView else { return }

        // 未过滤是绝大多数情况：直接返回，避免触碰 `numberOfRows`。
        // `numberOfRows` 会强制 outline view 计算行数，若在布局/插入过程中频繁调用，
        // 「全部展开」这类插入上万行的操作会退化成 O(n²)（表现为界面卡死）。
        guard isFiltering else {
            if !noResultsLabel.isHidden { noResultsLabel.isHidden = true }
            if outlineView.isHidden { outlineView.isHidden = false }
            return
        }

        isUpdatingNoResultsState = true
        defer { isUpdatingNoResultsState = false }

        // numberOfRows 含根行；仅根行可见即等价于「没有任何匹配结果」。
        let isEmpty = outlineView.numberOfRows <= 1
        if noResultsLabel.isHidden == isEmpty {
            noResultsLabel.isHidden = !isEmpty
        }
        if outlineView.isHidden != isEmpty {
            outlineView.isHidden = isEmpty
        }
    }

    /// 最近文件过滤用的路径集合：最近打开过的文件 + 其全部祖先目录。
    /// 由 ``handleFilterChange`` 重建；逐项匹配走 O(1) 集合查找，不递归扫盘。
    private var recentsFilterPaths: Set<String> = []

    /// 重建最近文件路径集合（仅在「只显示最近」开启时）。
    private func rebuildRecentsFilterPaths() {
        guard workspace?.navigatorRecentsFilter == true else {
            recentsFilterPaths = []
            return
        }
        var paths: Set<String> = []
        for url in RecentsStore.recentFileURLs() {
            var path = url.standardizedFileURL.path
            while path.count > 1 {
                paths.insert(path)
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path { break }
                path = parent
            }
        }
        recentsFilterPaths = paths
    }

    /// Checks if the given filter matches the name of the item or any of its children.
    ///
    /// 维度之间是「与」关系：名字（或源代码管理状态）命中 + 最近文件集合命中。
    /// 最近过滤不展开匹配目录的全部子项（``saveAllContentChildren``），否则集合过滤失去意义。
    func fileSearchMatches(_ filter: String, for item: CEWorkspaceFile, sourceControlFilter: Bool) -> Bool {
        let recentsOnly = workspace?.navigatorRecentsFilter == true
        guard !filterIsEmpty || sourceControlFilter || recentsOnly else {
            return true
        }
        if recentsOnly && !recentsFilterPaths.contains(item.url.path) {
            return false
        }

        let selfMatch: Bool
        if sourceControlFilter {
            selfMatch = item.gitStatus != nil && item.gitStatus != GitStatus.none &&
                (filterIsEmpty || item.name.localizedCaseInsensitiveContains(filter))
        } else if filterIsEmpty {
            selfMatch = true
        } else {
            selfMatch = item.name.localizedCaseInsensitiveContains(filter)
        }

        if selfMatch {
            if !recentsOnly {
                saveAllContentChildren(for: item)
            }
            return true
        }

        if let children = workspace?.workspaceFileManager?.childrenOfFile(item) {
            return children.contains { fileSearchMatches(filter, for: $0, sourceControlFilter: sourceControlFilter) }
        }

        return false
    }

    /// Saves all children of a given folder item to the filtered content cache.
    /// This is specially useful when the name of a folder matches the search.
    /// Just like in Xcode, this shows all the content of the folder.
    private func saveAllContentChildren(for item: CEWorkspaceFile) {
        guard item.isFolder, filteredContentChildren[item] == nil else { return }

        if let children = workspace?.workspaceFileManager?.childrenOfFile(item) {
            filteredContentChildren[item] = children
            for child in children.filter({ $0.isFolder }) {
                saveAllContentChildren(for: child)
            }
        }
    }

    /// Restores the expanded state of items when finish searching.
    private func restoreExpandedState() {
        let copy = expandedItems
        outlineView.collapseItem(outlineView.item(atRow: 0), collapseChildren: true)

        for item in copy {
            expandParentsRecursively(of: item)
            outlineView.expandItem(item)
        }

        expandedItems = copy
    }

    /// Recursively expands all parent items of a given item in the outline view.
    /// The order of the items may get lost in the `expandedItems` set.
    /// This means that a children item might be expanded before its parent, causing it not to really expand.
    private func expandParentsRecursively(of item: CEWorkspaceFile) {
        if let parent = item.parent {
            expandParentsRecursively(of: parent)
            outlineView.expandItem(parent)
        }
    }
}

extension Notification.Name {
    /// 一键收起项目导航器的所有目录。
    static let projectNavigatorCollapseAll = Notification.Name("ProjectNavigatorCollapseAll")
}
