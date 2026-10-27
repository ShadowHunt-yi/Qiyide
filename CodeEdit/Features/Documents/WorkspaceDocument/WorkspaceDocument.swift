//
//  WorkspaceDocument.swift
//  CodeEdit
//
//  Created by Pavel Kasila on 17.03.22.
//

import AppKit
import SwiftUI
import Combine
import Foundation
import LanguageServerProtocol

@objc(WorkspaceDocument)
final class WorkspaceDocument: NSDocument, ObservableObject, NSToolbarDelegate {
    @Published var sortFoldersOnTop: Bool = true
    /// A string used to filter the displayed files and folders in the project navigator area based on user input.
    @Published var navigatorFilter: String = ""
    /// 文件树「只显示最近打开过的文件」过滤开关（底部工具栏时钟按钮）。
    @Published var navigatorRecentsFilter: Bool = false
    /// Whether the workspace only shows files with changes.
    @Published var sourceControlFilter = false

    private var workspaceState: [String: Any] {
        get {
            let key = "workspaceState-\(self.fileURL?.absoluteString ?? "")"
            return UserDefaults.standard.object(forKey: key) as? [String: Any] ?? [:]
        }
        set {
            let key = "workspaceState-\(self.fileURL?.absoluteString ?? "")"
            UserDefaults.standard.set(newValue, forKey: key)
        }
    }

    var workspaceFileManager: CEWorkspaceFileManager?

    var editorManager: EditorManager? = EditorManager()
    var statusBarViewModel: StatusBarViewModel? = StatusBarViewModel()
    var utilityAreaModel: UtilityAreaViewModel? = UtilityAreaViewModel()
    var searchState: SearchState?
    var openQuicklyViewModel: OpenQuicklyViewModel?
    var commandsPaletteState: QuickActionsViewModel?
    var listenerModel: WorkspaceNotificationModel = .init()
    /// 多根工作区下的 Git 仓库集合。每个根目录对应一个独立的 ``SourceControlManager``。
    private(set) var sourceControlWorkspace: SourceControlWorkspace?

    /// 当前展示的仓库。
    ///
    /// 该属性保持为计算属性，使既有的 `workspace.sourceControlManager` 调用点无需改动，
    /// 同时在用户切换仓库时自动指向新的管理器。
    var sourceControlManager: SourceControlManager? {
        sourceControlWorkspace?.activeManager
    }

    var taskManager: TaskManager?
    var workspaceSettingsManager: CEWorkspaceSettings?
    var taskNotificationHandler: TaskNotificationHandler = TaskNotificationHandler()

    var undoRegistration: UndoManagerRegistration = UndoManagerRegistration()

    var notificationPanel = NotificationPanelViewModel()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        notificationPanel.workspace = self

        // Observe changes to notification panel
        notificationPanel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    deinit {
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    func getFromWorkspaceState(_ key: WorkspaceStateKey) -> Any? {
        return workspaceState[key.rawValue]
    }

    func addToWorkspaceState(key: WorkspaceStateKey, value: Any?) {
        if let value {
            workspaceState.updateValue(value, forKey: key.rawValue)
        } else {
            workspaceState.removeValue(forKey: key.rawValue)
        }
    }

    // MARK: NSDocument

    private let ignoredFilesAndDirectory = [
        ".DS_Store"
    ]

    override static var autosavesInPlace: Bool {
        false
    }

    override var isDocumentEdited: Bool {
        false
    }

    override func makeWindowControllers() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Note For anyone hoping to switch back to a Root-SwiftUI window:
        // See Commit 0200c87 for more details and to see what was previously here.
        // -----
        // Setting the "min size" like this is hacky, but SwiftUI overrides the contentRect and
        // any of the built-in window size functions & autosave stuff. So we have to set it like this.
        // SwiftUI also ignores this value, so it just manages to set the initial window size. *Hopefully* this
        // is fixed in the future.
        // ----
        let windowController = CodeEditWindowController(
            window: window,
            workspace: self
        )

        if let rectString = getFromWorkspaceState(.workspaceWindowSize) as? String {
            window.setFrame(NSRectFromString(rectString), display: true, animate: false)
        } else {
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: true, animate: false)
            window.center()
        }

        window.setAccessibilityIdentifier("workspace")
        window.setAccessibilityDocument(self.fileURL?.absoluteString)

        self.addWindowController(windowController)

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Set Up Workspace

    private func initWorkspaceState(_ url: URL) throws {
        // Ensure the URL ends with a "/" to prevent certain URL(filePath:relativeTo) initializers from
        // placing the file one directory above our workspace. This quick fix appends a "/" if needed.
        var url = url
        if !url.absoluteString.hasSuffix("/") {
            url = URL(filePath: url.absoluteURL.path(percentEncoded: false) + "/")
        }

        self.fileURL = url
        self.displayName = url.lastPathComponent

        let sourceControlWorkspace = SourceControlWorkspace()
        self.sourceControlWorkspace = sourceControlWorkspace

        // 先读取工作区设置，其中的 `additionalRoots` 决定这是一个单根还是多根工作区。
        // 设置必须先于文件管理器创建，否则首帧无法显示附加根目录。
        let settingsManager = CEWorkspaceSettings(workspaceURL: url)
        self.workspaceSettingsManager = settingsManager

        let additionalRootUrls = settingsManager.settings.project.additionalRoots
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        self.workspaceFileManager = .init(
            rootUrls: [url] + additionalRootUrls,
            ignoredFilesAndFolders: Set(ignoredFilesAndDirectory),
            sourceControlManager: nil
        )

        // 为每个根目录建立独立的 Git 仓库，并把文件管理器接回各仓库。
        sourceControlWorkspace.sync(
            roots: workspaceFileManager?.rootUrls ?? [url],
            editorManager: editorManager!,
            fileManager: workspaceFileManager
        )
        workspaceFileManager?.sourceControlManager = sourceControlWorkspace.primaryManager
        workspaceFileManager?.sourceControlWorkspace = sourceControlWorkspace

        // 仓库集合的变化需要传递给窗口（切换仓库、改动数变化）。
        sourceControlWorkspace.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        self.searchState = .init(self)
        self.openQuicklyViewModel = .init(fileURLs: workspaceFileManager?.rootUrls ?? [url])
        self.commandsPaletteState = .init()
        if let workspaceSettingsManager {
            self.taskManager = TaskManager(
                workspaceSettings: workspaceSettingsManager.settings,
                workspaceURL: url
            )
        }
        self.taskNotificationHandler.workspaceURL = url

        workspaceFileManager?.addObserver(undoRegistration)
        editorManager?.restoreFromState(self)
        utilityAreaModel?.restoreFromState(self)
    }

    // MARK: - 多根工作区

    /// 将文件夹加入当前窗口的工作区，使其出现在项目导航器中，并与主根共享同一个窗口。
    ///
    /// 主根（`fileURL`）不参与该数组；附加根会持久化到 `.qiyide/settings.json`，
    /// 下次打开同一工作区时自动恢复。
    /// - Parameter urls: 要加入的文件夹，非目录或已存在的项会被忽略。
    func addRootFolders(_ urls: [URL]) {
        guard let workspaceFileManager, let settingsManager = workspaceSettingsManager else { return }

        var changed = false
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let standardized = url.standardizedFileURL
            workspaceFileManager.addRoot(standardized)

            if !settingsManager.settings.project.additionalRoots.contains(standardized.path) {
                settingsManager.settings.project.additionalRoots.append(standardized.path)
                changed = true
            }
        }

        // 无论设置是否有变化，都要让 Git 仓库集合跟上新的根目录列表。
        syncSourceControlWorkspace()

        guard changed else { return }
        // `additionalRoots` 位于引用类型内部，`$settings` 不会自动收到通知，这里显式落盘。
        try? settingsManager.savePreferences()
        // 让「快速打开」覆盖到新加入的根目录。
        self.openQuicklyViewModel = .init(fileURLs: workspaceFileManager.rootUrls)
    }

    /// 从当前工作区移除一个附加根目录（不删除磁盘内容）。
    func removeRootFolder(_ url: URL) {
        guard let workspaceFileManager, let settingsManager = workspaceSettingsManager else { return }
        let standardized = url.standardizedFileURL

        // 主根不允许移除，否则窗口将失去所属项目。
        guard standardized.path != self.fileURL?.standardizedFileURL.path else { return }

        workspaceFileManager.removeRoot(standardized)
        syncSourceControlWorkspace()
        settingsManager.settings.project.additionalRoots.removeAll { $0 == standardized.path }
        try? settingsManager.savePreferences()
        self.openQuicklyViewModel = .init(fileURLs: workspaceFileManager.rootUrls)
    }

    /// 让 Git 仓库集合与当前根目录列表保持一致。
    private func syncSourceControlWorkspace() {
        guard let workspaceFileManager, let editorManager, let sourceControlWorkspace else { return }
        sourceControlWorkspace.sync(
            roots: workspaceFileManager.rootUrls,
            editorManager: editorManager,
            fileManager: workspaceFileManager
        )
        workspaceFileManager.sourceControlWorkspace = sourceControlWorkspace
    }

    override func read(from url: URL, ofType typeName: String) throws {
        try initWorkspaceState(url)
    }

    override func write(to url: URL, ofType typeName: String) throws {}

    // MARK: Close Workspace

    override func close() {
        super.close()
        editorManager?.saveRestorationState(self)
        utilityAreaModel?.saveRestorationState(self)

        cancellables.forEach({ $0.cancel() })
        cancellables.removeAll()
        statusBarViewModel = nil
        utilityAreaModel = nil
        searchState = nil
        editorManager = nil
        openQuicklyViewModel = nil
        commandsPaletteState = nil
        sourceControlWorkspace?.clear()
        sourceControlWorkspace = nil
        workspaceFileManager?.cleanUp()
        workspaceFileManager = nil
        workspaceSettingsManager?.cleanUp()
        workspaceSettingsManager = nil
        taskManager = nil
    }

    /// Determines the windows should be closed.
    ///
    /// This method iterates all edited documents If there are any edited documents.
    ///
    /// A panel giving the user the choice of canceling, discarding changes, or saving is presented while iteration.
    ///
    /// If the user chooses cancel on the panel, iteration is broken.
    ///
    /// In the last step, `shouldCloseSelector` is called with true if all documents are clean, otherwise false
    ///
    /// - Parameters:
    ///   - windowController: The windowController may be closed.
    ///   - delegate: The object which is a target of `shouldCloseSelector`.
    ///   - shouldClose: The callback which receives result of this method.
    ///   - contextInfo: The additional info which is not used in this method.
    override func shouldCloseWindowController(
        _ windowController: NSWindowController,
        delegate: Any?,
        shouldClose shouldCloseSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let object = (delegate as? NSObject),
              let shouldCloseSelector = shouldCloseSelector,
              let contextInfo = contextInfo
        else {
            super.shouldCloseWindowController(
                windowController,
                delegate: delegate,
                shouldClose: shouldCloseSelector,
                contextInfo: contextInfo
            )
            return
        }
        // Save unsaved changes before closing
        let editedCodeFiles = editorManager?.editorLayout
            .gatherOpenFiles()
            .compactMap(\.fileDocument)
            .filter(\.isDocumentEdited) ?? []

        for editedCodeFile in editedCodeFiles {
            let shouldClose = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            shouldClose.initialize(to: true)
            defer {
                _ = shouldClose.move()
                shouldClose.deallocate()
            }
            // Present a panel giving the user the choice of canceling, discarding changes, or saving.
            editedCodeFile.canClose(
                withDelegate: self,
                shouldClose: #selector(document(_:shouldClose:contextInfo:)),
                contextInfo: shouldClose
            )
            // pointee becomes false when user select cancel
            guard shouldClose.pointee else {
                break
            }
        }
        // Invoke shouldCloseSelector at delegate
        let implementation = object.method(for: shouldCloseSelector)
        let function = unsafeBitCast(
            implementation,
            to: (@convention(c)(Any, Selector, Any, Bool, UnsafeMutableRawPointer?) -> Void).self
        )
        let areAllOpenedCodeFilesClean = editorManager?.editorLayout.gatherOpenFiles()
            .compactMap(\.fileDocument)
            .allSatisfy { !$0.isDocumentEdited } ?? false
        function(object, shouldCloseSelector, self, areAllOpenedCodeFilesClean, contextInfo)
    }

    // MARK: NSDocument delegate

    /// Receives result of `canClose` and then, set `shouldClose` to `contextInfo`'s `pointee`.
    ///
    /// - Parameters:
    ///   - document: The document may be closed.
    ///   - shouldClose: The result of user selection.
    ///      `shouldClose` becomes false if the user selects cancel, otherwise true.
    ///   - contextInfo: The additional info which will be set `shouldClose`.
    ///       `contextInfo` must be `UnsafeMutablePointer<Bool>`.
    @objc
    func document(
        _ document: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer
    ) {
        let opaquePtr = OpaquePointer(contextInfo)
        let mutablePointer = UnsafeMutablePointer<Bool>(opaquePtr)
        mutablePointer.pointee = shouldClose
    }
}
