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
    /// 编辑代数。替代「全文哈希」当作「文本变没变」的判据。
    ///
    /// 原指纹是 `text.hashValue`。实测 12MB / 20 万行的文本，`hashValue` 要 **494ms**
    /// （`String.hashValue` 走 SipHash，必须遍历每一个字节），而这一步在
    /// `prepareRefresh` 里、在主线程、打开文件时就会跑一次——界面直接僵半秒。
    /// 代数由 `textViewDidChangeText` 递增，O(1)，同样能表达「文本变了」。
    ///
    /// 注意：`textStorage.string` 本身并不慢（实测 0.0ms，桥接而非复制），
    /// 所以省掉的只是哈希那 494ms。
    private var editGeneration: Int = 0

    /// 超过这么多字符就不装行级标注。
    ///
    /// 标注是「每行一个 `TextAttachment`」：20 万行的文件会产出 20 万个附件对象
    /// （实测逐行枚举本身 38ms，建 20 万个附件才是真正的灾难），
    /// 内存、排版、绘制全部按行数线性膨胀。
    /// 编辑器的本职是把文件显示出来，标注只是附加信息——大文件宁可不显示标注，
    /// 也不能失去响应。
    private static let maxAnnotatedCharacters = 200_000

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
        // 代数递增代替全文哈希：见 `editGeneration` 的说明。
        editGeneration &+= 1
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
                self.apply(blames, to: controller)
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
            // 记录关闭原因：这是「标注突然消失」最常见的原因（⌥⌘B 误触或设置项被关）。
            Self.logger.debug("blame 标注已关闭（设置项 showLineBlame = false）")
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

        // 大文件不装标注，也不进 git：这一步是打开大文件卡死的主因之一。
        guard let storage = controller.textView.textStorage else { return nil }
        guard storage.length <= Self.maxAnnotatedCharacters else {
            if !lastFingerprint.isEmpty {
                removeAllAnnotations(from: controller)
                lastFingerprint = ""
            }
            return nil
        }

        let branch = manager.currentBranch?.name ?? ""
        // 指纹只用 O(1) 的信息：编辑代数、长度、分支、路径。
        // 不再取 `textStorage.string`（全文复制）和 `text.hashValue`（全文哈希）。
        let fingerprint = "\(branch)|\(editGeneration)|\(storage.length)|\(fileURL.path)"
        guard fingerprint != lastFingerprint else { return nil }

        return RefreshRequest(manager: manager, fingerprint: fingerprint)
    }

    @MainActor
    private func removeAllAnnotationsFromCurrentController() {
        guard let controller else { return }
        removeAllAnnotations(from: controller)
    }

    // MARK: - 标注安装 / 卸载

    @MainActor
    private func apply(_ blames: [GitBlameLine], to controller: TextViewController) {
        removeAllAnnotations(from: controller)

        // 直接用 `mutableString` 桥接：`textStorage.string` 会复制整个文件，
        // 这里只是要按行枚举，不需要那份副本。
        guard let storage = controller.textView.textStorage else { return }
        let nsText = storage.mutableString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var lineRanges: [NSRange] = []
        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            lineRanges.append(lineRange)
        }

        let count = min(lineRanges.count, blames.count)
        var lastAnchor: Int?
        var installed = 0
        for index in 0..<count {
            let lineRange = lineRanges[index]
            guard lineRange.length > 0 else { continue }

            // 锚点是**换行符本身**，不是行内最后一个可见字符。
            //
            // `enumerateSubstrings(.byLines)` 返回的区间**不含**行终止符：
            // "abc\ndef" 会得到 {0,3} 与 {4,3}，换行符位于 location + length。
            // 原实现用 `length - 1` 定位，得到的是 "c"/"f"，随后「必须是换行符」
            // 的守卫对每一行都不成立，导致一条标注都装不上（日志表现为「已安装 0/N 行」）。
            var anchor = lineRange.location + lineRange.length
            // 末行没有换行符：跳过。附件会整段替换其覆盖的字符，
            // 没有换行符可占用时就会吃掉最后一个可见字符。
            guard anchor < nsText.length else { continue }
            var unit = nsText.character(at: anchor)
            // CRLF 以 LF 作为锚点，避免只覆盖 CR 留下孤立的 LF。
            if unit == 13, anchor + 1 < nsText.length, nsText.character(at: anchor + 1) == 10 {
                anchor += 1
                unit = 10
            }
            guard unit == 10 || unit == 13 else { continue }
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
            installed += 1
        }
        // 安装结果落日志：出现「有提交但看不到标注」时，可据此区分
        // 「没安装」（数据/开关问题）与「装了但没画出来」（排版问题）。
        Self.logger.debug("blame 标注已安装 \(installed)/\(count) 行")
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
