//
//  GitBlameCoordinator.swift
//  CodeEdit
//
//  行级 git blame 标注的驱动器：计算 blame 并把标注附件装进行尾。
//
//  刷新时机：文本编辑（防抖 0.6s）、分支切换、提交后改动列表变化、全局开关切换。
//  性能：git blame 异步执行，文本指纹+分支指纹未变时直接跳过；
//  附件安装走 TextAttachmentManager 的批量区域失效。
//

import AppKit
import Combine
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import OSLog

extension Notification.Name {
    /// 行级 blame 标注开关变化（设置页 / 菜单触发）。
    static let gitBlameSettingsDidChange = Notification.Name("GitBlameSettingsDidChange")
}

final class GitBlameCoordinator: TextViewCoordinator, GitBlameAnnotationDelegate {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.qiyide",
        category: "GitBlame"
    )
    private weak var controller: TextViewController?
    private weak var codeFile: CodeFileDocument?

    private let fileURL: URL
    private var refreshTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var settingsObserver: NSObjectProtocol?

    /// 当前安装的标注不再按偏移记录：编辑后内核会平移附件位置，旧偏移会失效。
    /// 卸载统一走 `removeAttachments(ofType:)`。
    /// 文本 + 分支指纹，未变化时跳过重算。
    private var lastFingerprint: String = ""
    /// 真实故障只提示一次，避免每次编辑都弹横幅。
    private var hasNotifiedFailure: Bool = false
    /// 工作区仓库管理器可能晚于编辑器就绪，只重试一次。
    private var didRetryForMissingManager: Bool = false

    init(fileURL: URL, codeFile: CodeFileDocument) {
        self.fileURL = fileURL
        self.codeFile = codeFile
    }

    // MARK: - TextViewCoordinator

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .gitBlameSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(immediate: true)
        }

        observeSourceControl()
        scheduleRefresh(immediate: true)
    }

    func controllerDidAppear(controller: TextViewController) {}

    func controllerDidDisappear(controller: TextViewController) {}

    func textViewDidChangeText(controller: TextViewController) {
        scheduleRefresh()
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {}

    func destroy() {
        refreshTask?.cancel()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        cancellables.removeAll()
        if let controller {
            removeAllAnnotations(from: controller)
        }
        controller = nil
    }

    // MARK: - 源代码管理联动

    private func observeSourceControl() {
        guard let workspace = codeFile?.findWorkspace() else { return }
        workspace.sourceControlManager?.objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                // 提交/拉取/分支切换都会改变 blame（分支名变化强制重算）。
                self?.scheduleRefresh(immediate: true)
            }
            .store(in: &cancellables)
    }

    // MARK: - 刷新

    /// 一次刷新所需的主线程快照。
    private struct RefreshRequest {
        let manager: SourceControlManager
        let text: String
        let fingerprint: String
    }

    private func scheduleRefresh(immediate: Bool = false) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(600))
            }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func refresh() async {
        // 1) 主线程读取编辑器状态：`textStorage` 只能在主线程访问。
        guard let request = await prepareRefresh() else { return }

        // 2) git 在后台线程执行：ShellClient 内部是同步阻塞调用，放主线程会卡住 UI。
        do {
            let started = PerformanceRecorder.shared.begin()
            let blames = try await request.manager.blameLines(for: fileURL)
            PerformanceRecorder.shared.record(
                startedAt: started,
                category: .gitBlame,
                meta: ["lines": "\(blames.count)"]
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let controller = self.controller else { return }
                self.apply(blames, to: controller, text: request.text)
                self.lastFingerprint = request.fingerprint
                self.hasNotifiedFailure = false
            }
        } catch let reason as GitBlameUnavailable {
            // 预期情况（仓库无提交、文件未跟踪、文件已删除、非 UTF-8、不在仓库内）：静默降级。
            Self.logger.debug(
                "blame 不可用[\(reason.localizedDescription, privacy: .public)]: \(self.fileURL.path, privacy: .public)"
            )
            await MainActor.run {
                self.removeAllAnnotationsFromCurrentController()
                self.lastFingerprint = request.fingerprint
            }
        } catch {
            // 真实故障（git 不可用、权限、仓库损坏）：卸载标注并提示，同一文件只提示一次。
            Self.logger.error(
                "blame 失败: \(self.fileURL.path, privacy: .public) — \(String(describing: error), privacy: .public)"
            )
            await MainActor.run {
                self.removeAllAnnotationsFromCurrentController()
                self.lastFingerprint = request.fingerprint
                guard !self.hasNotifiedFailure else { return }
                self.hasNotifiedFailure = true
                NotificationManager.shared.post(
                    iconSymbol: "exclamationmark.triangle",
                    title: NSLocalizedString("Git blame unavailable", comment: ""),
                    description: "\(self.fileURL.lastPathComponent)：\(error.localizedDescription)",
                    actionButtonTitle: "",
                    action: {}
                )
            }
        }
    }

    /// 在主线程收集一次刷新所需的上下文；返回 nil 表示无需刷新（关闭、无仓库、指纹未变）。
    @MainActor
    private func prepareRefresh() -> RefreshRequest? {
        guard let controller else { return nil }

        guard Settings.shared.preferences.sourceControl.general.showLineBlame else {
            removeAllAnnotations(from: controller)
            lastFingerprint = ""
            return nil
        }
        guard let workspace = codeFile?.findWorkspace(),
              let manager = workspace.sourceControlManager else {
            // 没有源代码管理上下文：安静地不显示。
            removeAllAnnotations(from: controller)
            // 启动时仓库可能还在校验（异步），延迟重试一次，避免标注永久缺失。
            if !didRetryForMissingManager, codeFile?.findWorkspace() != nil {
                didRetryForMissingManager = true
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    await self?.refresh()
                }
            }
            return nil
        }
        // 注意：不能用 `manager.isGitRepository` 做门槛。多根工作区里工作区根目录
        // 可能不是仓库（或是个没有提交的空仓库），而文件本身位于某个嵌套仓库内；
        // 仓库归属由 `blameLines` 按文件目录解析，不可用原因走 GitBlameUnavailable。

        let text = controller.textView.textStorage.string
        let branch = manager.currentBranch?.name ?? ""
        let fingerprint = "\(branch)|\(text.hashValue)|\(fileURL.path)"
        guard fingerprint != lastFingerprint else { return nil }

        return RefreshRequest(manager: manager, text: text, fingerprint: fingerprint)
    }

    @MainActor
    private func removeAllAnnotationsFromCurrentController() {
        guard let controller else { return }
        removeAllAnnotations(from: controller)
    }

    // MARK: - 标注安装 / 卸载

    @MainActor
    private func apply(_ blames: [GitBlameLine], to controller: TextViewController, text: String) {
        removeAllAnnotations(from: controller)

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var lineRanges: [NSRange] = []
        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lineRanges.append(lineRange)
        }

        let count = min(lineRanges.count, blames.count)
        var lastAnchor: Int?
        for index in 0..<count {
            let lineRange = lineRanges[index]
            guard lineRange.length > 0 else { continue }
            // 锚点必须是换行符：末行没有换行时，行尾最后一个可见字符不能被附件覆盖
            // （附件区间会整段交给附件绘制，原字符不再绘制）。
            let anchor = lineRange.location + lineRange.length - 1
            guard anchor < nsText.length else { continue }
            let lastUnit = nsText.character(at: anchor)
            guard lastUnit == 10 || lastUnit == 13 else { continue }
            // 同一位置只允许一个附件（重叠附件会被排版忽略，纯属浪费）。
            guard lastAnchor != anchor else { continue }
            lastAnchor = anchor

            let annotation = GitBlameAnnotation(
                blame: blames[index],
                line: index + 1,
                delegate: self
            )
            // 覆盖换行符（长度 1）：类型器把该区间交给附件绘制，行断行不受影响。
            controller.textView.layoutManager.attachments.add(
                annotation,
                for: NSRange(location: anchor, length: 1)
            )
        }
    }

    /// 按类型卸载标注。不能按安装时的偏移逐个移除：编辑后内核会平移附件位置。
    /// - Note: 必须在主线程调用。
    private func removeAllAnnotations(from controller: TextViewController) {
        controller.textView.layoutManager.attachments
            .removeAttachments(ofType: GitBlameAnnotation.self)
    }

    // MARK: - GitBlameAnnotationDelegate

    func annotationClicked(_ annotation: GitBlameAnnotation) {
        GitBlameHistoryPresenter.show(
            file: fileURL,
            line: annotation.line,
            blame: annotation.blame,
            codeFile: codeFile
        )
    }

    /// 菜单入口：查看当前光标所在行的变更历史。
    static func showHistoryForCurrentLine(workspace: WorkspaceDocument?) {
        guard let tab = workspace?.editorManager?.activeEditor.selectedTab,
              let cursor = tab.cursorPositions.first else {
            NotificationManager.shared.post(
                iconSymbol: "info.circle",
                title: NSLocalizedString("Line History", comment: ""),
                description: NSLocalizedString("Place the cursor on a line first.", comment: ""),
                actionButtonTitle: "",
                action: {}
            )
            return
        }
        let line = max(cursor.start.line, 1)
        GitBlameHistoryPresenter.show(
            file: tab.file.url,
            line: line,
            blame: nil,
            codeFile: tab.file.fileDocument
        )
    }
}
