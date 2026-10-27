//
//  MarkdownPreviewView.swift
//  CodeEdit
//
//  Markdown 实时预览：WKWebView 渲染 + 与源码双向滚动同步。
//
//  同步机制：
//  - 源码 → 预览：监听编辑器滚动（scrollPosition）与光标（cursorPositions），
//    换算出顶部可见行，滚到预览中 `data-line <= 行号` 的最后一个块。
//  - 预览 → 源码：页面滚动经 JS 上报顶部块的 data-line，反向设置
//    editorInstance.scrollPosition（编辑器侧会应用外部滚动状态）。
//

import AppKit
import SwiftUI
import WebKit
import Combine

struct MarkdownPreviewView: NSViewRepresentable {
    @ObservedObject var editorInstance: EditorInstance
    @ObservedObject var codeFile: CodeFileDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(editorInstance: editorInstance, codeFile: codeFile)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "previewScroll")
        // 注入滚动上报脚本：页面滚动时把顶部块的 data-line 与滚动比例发回 Swift。
        let scrollScript = WKUserScript(
            source: """
            (function() {
                function report() {
                    var topLine = 0;
                    document.querySelectorAll('[data-line]').forEach(function(el) {
                        if (el.offsetTop <= window.scrollY + 12) {
                            topLine = parseInt(el.dataset.line) || 0;
                        }
                    });
                    var max = document.documentElement.scrollHeight - window.innerHeight;
                    var fraction = max > 0 ? window.scrollY / max : 0;
                    if (window.webkit && window.webkit.messageHandlers.previewScroll) {
                        window.webkit.messageHandlers.previewScroll.postMessage({
                            topLine: topLine, fraction: fraction
                        });
                    }
                }
                window.addEventListener('scroll', report, { passive: true });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(scrollScript)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.reload(force: true)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.editorInstance = editorInstance
        context.coordinator.codeFile = codeFile
        context.coordinator.reload()
        context.coordinator.syncFromEditorIfStale()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "previewScroll")
    }

    // MARK: - 协调器

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var editorInstance: EditorInstance
        var codeFile: CodeFileDocument

        /// 上次渲染的文本，变化才重载，避免滚动位置被不断重置。
        private var lastRendered: String = ""
        /// 回声抑制：记录我们主动写入的滚动点，反馈回来时忽略。
        private var lastPushedPoint: CGPoint?
        /// 重载 HTML 后要恢复的滚动比例。
        private var pendingRestoreFraction: Double?
        private var cancellables: Set<AnyCancellable> = []
        /// 当前进行中的渲染任务（文本连续变化时取消上一个，避免堆积）。
        private var renderTask: Task<Void, Never>?

        init(editorInstance: EditorInstance, codeFile: CodeFileDocument) {
            self.editorInstance = editorInstance
            self.codeFile = codeFile
            super.init()
            subscribe()
        }

        private func subscribe() {
            // 文本改动 → 重渲染（防抖）。
            // 350ms：预览需要整篇重排 + 重新执行 mermaid（脚本 3MB），
            // 250ms 在连续输入时几乎每两次按键就重载一次。
            codeFile.contentCoordinator.textUpdatePublisher
                .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.reload()
                }
                .store(in: &cancellables)

            // 源码滚动 → 预览跟随。
            editorInstance.$scrollPosition
                .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
                .sink { [weak self] point in
                    guard let self, let point else { return }
                    // 回声：就是我们自己写进去的滚动点。
                    if let pushed = self.lastPushedPoint, abs(pushed.y - point.y) < 1.0 {
                        self.lastPushedPoint = nil
                        return
                    }
                    let line = Self.estimatedLine(for: point.y, lineHeight: self.lineHeight)
                    self.scrollPreview(toLine: line)
                }
                .store(in: &cancellables)

            // 光标移动（含跳转）→ 预览跟随到光标所在块。
            editorInstance.$cursorPositions
                .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
                .sink { [weak self] positions in
                    guard let self, let first = positions.first else { return }
                    self.scrollPreview(toLine: max(first.start.line - 1, 0))
                }
                .store(in: &cancellables)
        }

        /// 编辑器一行的像素高度，用于行号 ↔ 滚动点换算。
        private var lineHeight: CGFloat {
            let font = Settings[\.textEditing].font.current
            return font.lineHeight * Settings[\.textEditing].lineHeightMultiple
        }

        private static func estimatedLine(for offsetY: CGFloat, lineHeight: CGFloat) -> Int {
            guard lineHeight > 0 else { return 0 }
            return max(Int(offsetY / lineHeight), 0)
        }

        /// 文本变化时重新加载 HTML；无变化时跳过。
        func reload(force: Bool = false) {
            guard let webView else { return }
            let text = codeFile.content?.string ?? ""
            guard force || text != lastRendered else { return }
            lastRendered = text
            // 重载前记住当前滚动比例，加载完成后恢复。
            pendingRestoreFraction = currentPreviewFraction()
            // baseURL 指向应用资源目录：预览里的相对脚本（mermaid.min.js）从包内加载，离线可用。
            let baseURL = Bundle.main.resourceURL

            renderTask?.cancel()
            // Markdown → HTML 是纯计算：放后台，避免大文档在输入时占用主线程。
            renderTask = Task { [weak self] in
                let started = CFAbsoluteTimeGetCurrent()
                let html = await Task.detached(priority: .userInitiated) {
                    MarkdownPreviewHTML.render(text)
                }.value
                PerformanceRecorder.shared.record(
                    startedAt: started,
                    category: .markdownRender,
                    meta: ["chars": "\(text.count)"]
                )
                guard !Task.isCancelled else { return }
                self?.webView?.loadHTMLString(html, baseURL: baseURL)
            }
        }

        /// 预览当前滚动比例（0…1）。
        /// macOS 的 WKWebView 没有 `scrollView`（iOS API），走 enclosingScrollView。
        private func currentPreviewFraction() -> Double? {
            guard let scrollView = webView?.enclosingScrollView,
                  let documentView = scrollView.documentView else { return nil }
            let visible = scrollView.contentView.bounds.height
            let content = documentView.frame.height
            guard content > visible, visible > 0 else { return nil }
            let offsetY = scrollView.contentView.bounds.origin.y
            return Double(offsetY / (content - visible))
        }

        /// 滚动预览到指定源码行。
        func scrollPreview(toLine line: Int) {
            let js = """
            (function() {
                var els = document.querySelectorAll('[data-line]');
                var target = null;
                els.forEach(function(el) {
                    if (parseInt(el.dataset.line) <= \(line)) { target = el; }
                });
                if (target) { window.scrollTo(0, Math.max(0, target.offsetTop - 8)); }
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// 更新 NSView 时如果编辑器状态比我们记录的新，允许一次源码→预览同步。
        func syncFromEditorIfStale() {}

        // MARK: WKNavigationDelegate

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // HTML 重载完成后恢复滚动比例（编辑中保持阅读位置）。
            Task { @MainActor in
                guard let fraction = self.pendingRestoreFraction else { return }
                self.pendingRestoreFraction = nil
                let js = """
                (function() {
                    var max = document.documentElement.scrollHeight - window.innerHeight;
                    if (max > 0) { window.scrollTo(0, max * \(fraction)); }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // MARK: WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            let body = message.body as? [String: Any]
            let topLine = body?["topLine"] as? Int ?? 0
            Task { @MainActor in
                self.applyPreviewScroll(topLine: topLine)
            }
        }

        /// 预览滚动 → 设置源码滚动点（编辑器会应用该值）。
        private func applyPreviewScroll(topLine: Int) {
            let y = CGFloat(topLine) * lineHeight
            let point = CGPoint(x: 0, y: y)
            guard editorInstance.scrollPosition?.y != point.y else { return }
            lastPushedPoint = point
            editorInstance.scrollPosition = point
        }
    }
}

// MARK: - 预览容器

/// Markdown 标签页的容器：开启预览时源码 | 预览分栏（可拖动分隔条），否则只显示源码。
struct MarkdownEditorContainerView: View {
    @ObservedObject var editorInstance: EditorInstance
    @ObservedObject var codeFile: CodeFileDocument

    private var isMarkdown: Bool {
        codeFile.getLanguage().tsName == "markdown"
    }

    var body: some View {
        if isMarkdown, editorInstance.showMarkdownPreview {
            HSplitView {
                EditorAreaFileView(editorInstance: editorInstance, codeFile: codeFile)
                    .frame(minWidth: 260)
                MarkdownPreviewView(editorInstance: editorInstance, codeFile: codeFile)
                    .frame(minWidth: 280)
            }
        } else {
            EditorAreaFileView(editorInstance: editorInstance, codeFile: codeFile)
        }
    }
}
