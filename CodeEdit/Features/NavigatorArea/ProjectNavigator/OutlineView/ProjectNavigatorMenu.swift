//
//  OutlineMenu.swift
//  CodeEdit
//
//  Created by Lukas Pistrol on 07.04.22.
//

import SwiftUI
import UniformTypeIdentifiers

/// A subclass of `NSMenu` implementing the contextual menu for the project navigator
final class ProjectNavigatorMenu: NSMenu {

    /// The item to show the contextual menu for
    var item: CEWorkspaceFile?

    /// The workspace, for opening the item
    var workspace: WorkspaceDocument?

    /// The  `ProjectNavigatorViewController` is being called from.
    /// By sending it, we can access it's variables and functions.
    var sender: ProjectNavigatorViewController

    init(_ sender: ProjectNavigatorViewController) {
        self.sender = sender
        super.init(title: NSLocalizedString("Options", comment: ""))
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Creates a `NSMenuItem` depending on the given arguments
    /// - Parameters:
    ///   - title: The title of the menu item
    ///   - action: A `Selector` or `nil` of the action to perform.
    ///   - key: A `keyEquivalent` of the menu item. Defaults to an empty `String`
    /// - Returns: A `NSMenuItem` which has the target `self`
    private func menuItem(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        // 原生 NSMenuItem 不参与 SwiftUI 的 LocalizedStringKey 查找，必须显式本地化。
        let mItem = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: key)
        mItem.target = self

        return mItem
    }

    /// 创建标题已本地化的 `NSMenuItem`（用于需要格式化的标题，避免二次查找）。
    private func localizedItem(_ title: String, action: Selector?) -> NSMenuItem {
        let mItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mItem.target = self
        return mItem
    }

    /// Configures the menu based on the current selection in the outline view.
    /// - Menu items get added depending on the amount of selected items.
    private func setupMenu() { // swiftlint:disable:this function_body_length
        guard let item else { return }
        let showInFinder = menuItem("Show in Finder", action: #selector(showInFinder))

        let openInTab = menuItem("Open in Tab", action: #selector(openInTab))
        let openInNewWindow = menuItem("Open in New Window", action: nil)
        let openExternalEditor = menuItem("Open with External Editor", action: #selector(openWithExternalEditor))
        let openAs = menuItem("Open As", action: nil)

        let copyPath = menuItem("Copy Path", action: #selector(copyPath))
        let copyRelativePath = menuItem("Copy Relative Path", action: #selector(copyRelativePath))

        let showFileInspector = menuItem("Show File Inspector", action: nil)

        let newFile = menuItem("New File...", action: #selector(newFile))
        let newFileFromClipboard = menuItem(
            "New File from Clipboard",
            action: #selector(newFileFromClipboard),
            key: "v"
        )
        newFileFromClipboard.keyEquivalentModifierMask = [.command]
        let newFolder = menuItem("New Folder", action: #selector(newFolder))

        let rename = menuItem("Rename", action: #selector(renameFile))

        // 任意一个根目录都不允许被移入废纸篓或立即删除，否则会把整个项目从工作区移除。
        // 多根工作区下必须用「是否属于根集合」判断，而不是只比较主根。
        let isRootItem = workspace?.workspaceFileManager?.rootItems.contains(item) ?? false

        let trash = menuItem("Move to Trash", action: isRootItem ? nil : #selector(trash))

        // trash has to be the previous menu item for delete.isAlternate to work correctly
        let delete = menuItem("Delete Immediately...", action: isRootItem ? nil : #selector(delete))
        delete.keyEquivalentModifierMask = .option
        delete.isAlternate = true

        let duplicate = localizedItem(
            String(
                format: NSLocalizedString("Duplicate %@", comment: ""),
                NSLocalizedString(item.isFolder ? "Folder" : "File", comment: "")
            ),
            action: #selector(duplicate)
        )

        let sortByName = menuItem("Sort by Name", action: nil)
        sortByName.isEnabled = item.isFolder

        let sortByType = menuItem("Sort by Type", action: nil)
        sortByType.isEnabled = item.isFolder

        let sourceControl = menuItem("Source Control", action: nil)

        items = [
            showInFinder,
            NSMenuItem.separator(),
            openInTab,
            openInNewWindow,
            openExternalEditor,
            openAs,
            NSMenuItem.separator(),
            copyPath,
            copyRelativePath,
            NSMenuItem.separator(),
            showFileInspector,
            NSMenuItem.separator(),
            newFile,
            newFileFromClipboard,
            newFolder
        ]

        if canCreateFolderFromSelection() {
            items.append(menuItem("New Folder from Selection", action: #selector(newFolderFromSelection)))
        }
        items.append(NSMenuItem.separator())
        if selectedItems().count == 1 {
            items.append(rename)
        }

        items.append(
            contentsOf: [
                trash,
                delete,
                duplicate,
                NSMenuItem.separator(),
                sortByName,
                sortByType,
                NSMenuItem.separator(),
                sourceControl,
            ]
        )

        // 附加根目录可以移出工作区；主根不提供该操作，否则窗口会失去所属项目。
        if let manager = workspace?.workspaceFileManager,
           manager.rootItems.contains(item),
           item.url.standardizedFileURL.path != manager.folderUrl.standardizedFileURL.path {
            items.append(NSMenuItem.separator())
            items.append(menuItem("Remove Folder from Workspace", action: #selector(removeRootFromWorkspace)))
        }

        setSubmenu(openAsMenu(item: item), for: openAs)
        setSubmenu(sourceControlMenu(item: item), for: sourceControl)
    }

    /// Submenu for **Open As** menu item.
    private func openAsMenu(item: CEWorkspaceFile) -> NSMenu {
        let openAsMenu = NSMenu(title: NSLocalizedString("Open As", comment: ""))
        func getMenusItems() -> ([NSMenuItem], [NSMenuItem]) {
            // Use UTType to distinguish between bundle file and user-browsable directory
            // The isDirectory property is not accurate on this.
            guard let type = item.contentType else { return ([.none()], []) }
            if type.conforms(to: .folder) {
                return ([.none()], [])
            }
            var primaryItems = [NSMenuItem]()
            if type.conforms(to: .sourceCode) {
                primaryItems.append(.sourceCode())
            }
            if type.conforms(to: .propertyList) {
                primaryItems.append(.propertyList())
            }
            if type.conforms(to: UTType(filenameExtension: "xcassets")!) {
                primaryItems.append(NSMenuItem(title: NSLocalizedString("Asset Catalog Document", comment: ""), action: nil, keyEquivalent: ""))
            }
            if type.conforms(to: UTType(filenameExtension: "xib")!) {
                primaryItems.append(NSMenuItem(title: NSLocalizedString("Interface Builder XIB Document", comment: ""), action: nil, keyEquivalent: ""))
            }
            if type.conforms(to: UTType(filenameExtension: "xcodeproj")!) {
                primaryItems.append(NSMenuItem(title: NSLocalizedString("Xcode Project", comment: ""), action: nil, keyEquivalent: ""))
            }
            var secondaryItems = [NSMenuItem]()
            if type.conforms(to: .text) {
                secondaryItems.append(.asciiPropertyList())
                secondaryItems.append(.hex())
            }

            // FIXME: Update the quickLook condition
            if type.conforms(to: .data) {
                secondaryItems.append(.quickLook())
            }

            return (primaryItems, secondaryItems)
        }
        let (primaryItems, secondaryItems) = getMenusItems()
        for item in primaryItems {
            openAsMenu.addItem(item)
        }
        if !secondaryItems.isEmpty {
            openAsMenu.addItem(.separator())
        }
        for item in secondaryItems {
            openAsMenu.addItem(item)
        }
        return openAsMenu
    }

    /// Submenu for **Source Control** menu item.
    private func sourceControlMenu(item: CEWorkspaceFile) -> NSMenu {
        let sourceControlMenu = NSMenu(title: NSLocalizedString("Source Control", comment: ""))
        sourceControlMenu.addItem(
            withTitle: String(
                format: NSLocalizedString("Commit \"%@\"...", comment: ""),
                String(describing: item.fileName())
            ),
            action: nil,
            keyEquivalent: ""
        )
        sourceControlMenu.addItem(.separator())
        sourceControlMenu.addItem(withTitle: NSLocalizedString("Discard Changes...", comment: ""), action: nil, keyEquivalent: "")
        sourceControlMenu.addItem(.separator())
        sourceControlMenu.addItem(withTitle: NSLocalizedString("Add Selected Files", comment: ""), action: nil, keyEquivalent: "")
        sourceControlMenu.addItem(withTitle: NSLocalizedString("Mark Selected Files as Resolved", comment: ""), action: nil, keyEquivalent: "")

        return sourceControlMenu
    }

    /// Updates the menu for the selected item and hides it if no item is provided.
    override func update() {
        removeAllItems()
        setupMenu()
    }
}

extension NSMenuItem {
    fileprivate static func none() -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString("<None>", comment: ""), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    fileprivate static func sourceCode() -> NSMenuItem {
        NSMenuItem(title: NSLocalizedString("Source Code", comment: ""), action: nil, keyEquivalent: "")
    }

    fileprivate static func propertyList() -> NSMenuItem {
        NSMenuItem(title: NSLocalizedString("Property List", comment: ""), action: nil, keyEquivalent: "")
    }

    fileprivate static func asciiPropertyList() -> NSMenuItem {
        NSMenuItem(title: NSLocalizedString("ASCII Property List", comment: ""), action: nil, keyEquivalent: "")
    }

    fileprivate static func hex() -> NSMenuItem {
        NSMenuItem(title: NSLocalizedString("Hex", comment: ""), action: nil, keyEquivalent: "")
    }

    fileprivate static func quickLook() -> NSMenuItem {
        NSMenuItem(title: NSLocalizedString("Quick Look", comment: ""), action: nil, keyEquivalent: "")
    }
}
