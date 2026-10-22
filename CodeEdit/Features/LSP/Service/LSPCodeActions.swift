//
//  LSPCodeActions.swift
//  CodeEdit
//
//  把「当前编辑器 + 光标位置」桥接到 LSP 能力层：
//  悬停信息、跳转定义、查找引用、重命名符号、格式化文档。
//
//  设计约束：能力层（LanguageServer+X.swift）早已实现但没有 UI 调用点，
//  本文件只做上下文解析、结果呈现与编辑应用，不复制协议逻辑。
//

import AppKit
import SwiftUI
import LanguageServerProtocol

@MainActor
enum LSPCodeActions {

    // MARK: - 上下文解析

    struct CursorContext {
        let tab: EditorInstance
        let url: URL
        let position: Position
    }

    /// 从活动编辑器解析当前文件与光标对应的 LSP 位置。
    static func currentContext(_ workspace: WorkspaceDocument?) -> CursorContext? {
        guard let editor = workspace?.editorManager?.activeEditor,
              let tab = editor.selectedTab,
              let cursor = tab.cursorPositions.first else {
            return nil
        }
        let url = tab.file.url
        // 编辑器的行列是 1-indexed，LSP 是 0-indexed。
        let line = max(cursor.start.line - 1, 0)
        let character = max(cursor.start.column - 1, 0)
        return CursorContext(
            tab: tab,
            url: url,
            position: Position(line: line, character: character)
        )
    }

    private static func client(for url: URL) -> LSPService.LanguageServerType? {
        ServiceContainer.resolve(.singleton, LSPService.self)?.languageClient(forDocument: url)
    }

    // MARK: - 悬停信息

    static func showHover(_ workspace: WorkspaceDocument?) async {
        guard let context = currentContext(workspace) else {
            return notifyMissingContext("Hover Info")
        }
        guard let client = client(for: context.url) else {
            return notifyNoServer("Hover Info")
        }
        do {
            let hover = try await client.requestHover(for: context.url.lspURI, context.position)
            let text = Self.hoverText(hover)
            NotificationManager.shared.post(
                iconSymbol: "text.bubble",
                title: context.tab.file.name,
                description: text.isEmpty
                    ? NSLocalizedString("No information at this position.", comment: "")
                    : String(text.prefix(600)),
                actionButtonTitle: "",
                action: {}
            )
        } catch {
            notifyError("Hover Info", error)
        }
    }

    // MARK: - 跳转定义

    static func goToDefinition(_ workspace: WorkspaceDocument?) async {
        guard let context = currentContext(workspace) else {
            return notifyMissingContext("Go to Definition")
        }
        guard let client = client(for: context.url) else {
            return notifyNoServer("Go to Definition")
        }
        do {
            let response = try await client.requestGoToDefinition(
                for: context.url.lspURI,
                position: context.position
            )
            let locations = Self.locations(from: response)
            guard let first = locations.first else {
                return notify(
                    NSLocalizedString("Go to Definition", comment: ""),
                    NSLocalizedString("No definition found.", comment: "")
                )
            }
            open(location: first, workspace: workspace)
        } catch {
            notifyError("Go to Definition", error)
        }
    }

    // MARK: - 查找引用

    static func findReferences(_ workspace: WorkspaceDocument?) async {
        guard let context = currentContext(workspace) else {
            return notifyMissingContext("Find References")
        }
        guard let client = client(for: context.url) else {
            return notifyNoServer("Find References")
        }
        do {
            let response = try await client.requestFindReferences(
                for: context.url.lspURI,
                context.position,
                true
            )
            let locations = response ?? []
            guard !locations.isEmpty else {
                return notify(
                    NSLocalizedString("Find References", comment: ""),
                    NSLocalizedString("No references found.", comment: "")
                )
            }
            let rows = locations.prefix(500).map { location -> LSPReferenceRow in
                let fileURL = Self.fileURL(from: location.uri)
                    ?? URL(fileURLWithPath: location.uri)
                var lineText = ""
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines)
                    if location.range.start.line < lines.count {
                        lineText = lines[location.range.start.line]
                    }
                }
                return LSPReferenceRow(
                    url: fileURL,
                    line: location.range.start.line + 1,
                    character: location.range.start.character + 1,
                    text: lineText
                )
            }
            LSPReferencesWindowPresenter.show(
                title: context.tab.file.name,
                rows: rows,
                total: locations.count,
                workspace: workspace
            )
        } catch {
            notifyError("Find References", error)
        }
    }

    // MARK: - 重命名符号

    static func renameSymbol(_ workspace: WorkspaceDocument?) async {
        guard let context = currentContext(workspace),
              let codeFile = context.tab.file.fileDocument,
              let text = codeFile.content?.string else {
            return notifyMissingContext("Rename Symbol")
        }
        guard let client = client(for: context.url) else {
            return notifyNoServer("Rename Symbol")
        }

        let oldName = word(at: context.position, in: text)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Symbol", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString("Rename '%@' across the workspace.", comment: ""),
            oldName.isEmpty ? "…" : oldName
        )
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = oldName
        alert.accessoryView = input
        alert.addButton(withTitle: NSLocalizedString("Rename", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn,
              !input.stringValue.isEmpty else {
            return
        }

        do {
            let response = try await client.requestRename(
                for: context.url.lspURI,
                position: context.position,
                newName: input.stringValue
            )
            // RenameResponse 是 Optional<WorkspaceEdit>：nil 表示服务器没有给出修改方案。
            guard let edit = response else {
                return notify(
                    NSLocalizedString("Rename Symbol", comment: ""),
                    NSLocalizedString("The server returned no changes.", comment: "")
                )
            }
            let count = try applyWorkspaceEdit(edit, workspace: workspace)
            NotificationManager.shared.post(
                iconSymbol: "checkmark.circle",
                title: NSLocalizedString("Rename Symbol", comment: ""),
                description: String(format: NSLocalizedString("Applied %d edits.", comment: ""), count),
                actionButtonTitle: "",
                action: {}
            )
        } catch {
            notifyError("Rename Symbol", error)
        }
    }

    // MARK: - 格式化文档

    static func formatDocument(_ workspace: WorkspaceDocument?) async {
        guard let context = currentContext(workspace) else {
            return notifyMissingContext("Format Document")
        }
        guard let client = client(for: context.url) else {
            return notifyNoServer("Format Document")
        }
        do {
            let result = try await client.requestFormatting(
                for: context.url.lspURI,
                withFormat: FormattingOptions(tabSize: 4, insertSpaces: true)
            )
            let edits = result ?? []
            guard !edits.isEmpty else {
                return notify(
                    NSLocalizedString("Format Document", comment: ""),
                    NSLocalizedString("Nothing to format.", comment: "")
                )
            }
            guard let storage = context.tab.file.fileDocument?.content else {
                return notifyError(
                    "Format Document",
                    LSPActionError.documentNotAvailable
                )
            }
            Self.apply(edits, to: storage)
            NotificationManager.shared.post(
                iconSymbol: "checkmark.circle",
                title: NSLocalizedString("Format Document", comment: ""),
                description: String(format: NSLocalizedString("Applied %d edits.", comment: ""), edits.count),
                actionButtonTitle: "",
                action: {}
            )
        } catch {
            notifyError("Format Document", error)
        }
    }

    // MARK: - 工作区编辑应用

    enum LSPActionError: LocalizedError {
        case documentNotAvailable

        var errorDescription: String? {
            switch self {
            case .documentNotAvailable:
                return NSLocalizedString("The document is not available for editing.", comment: "")
            }
        }
    }

    /// 把 `WorkspaceEdit` 应用到工作区：打开中的文档改内存文本，未打开的写磁盘。
    static func applyWorkspaceEdit(_ edit: WorkspaceEdit, workspace: WorkspaceDocument?) throws -> Int {
        var editsByURL: [URL: [TextEdit]] = [:]
        for (uri, edits) in edit.changes ?? [:] {
            if let url = fileURL(from: uri) {
                editsByURL[url, default: []].append(contentsOf: edits)
            }
        }
        for change in edit.documentChanges ?? [] {
            if case .textDocumentEdit(let documentEdit) = change,
               let url = fileURL(from: documentEdit.textDocument.uri) {
                editsByURL[url, default: []].append(contentsOf: documentEdit.edits)
            }
        }
        guard !editsByURL.isEmpty else { return 0 }

        var applied = 0
        for (url, edits) in editsByURL {
            if let storage = openDocument(for: url)?.content {
                Self.apply(edits, to: storage)
            } else {
                var text = try String(contentsOf: url, encoding: .utf8)
                text = Self.apply(edits, toText: text)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            applied += edits.count
        }
        return applied
    }

    // MARK: - 文本工具

    /// 把 `TextEdit` 数组应用到文本存储（打开中的文档）。
    static func apply(_ edits: [TextEdit], to storage: NSTextStorage) {
        storage.beginEditing()
        for edit in sortedDescending(edits) {
            let nsText = storage.string as NSString
            let start = offset(of: edit.range.start, in: nsText)
            let end = offset(of: edit.range.end, in: nsText)
            let length = max(end - start, 0)
            storage.replaceCharacters(
                in: NSRange(location: start, length: length),
                with: edit.newText
            )
        }
        storage.endEditing()
    }

    /// 把 `TextEdit` 数组应用到纯文本（磁盘文件），返回新文本。
    static func apply(_ edits: [TextEdit], toText text: String) -> String {
        let mutable = NSMutableString(string: text)
        for edit in sortedDescending(edits) {
            let nsText = mutable as NSString
            let start = offset(of: edit.range.start, in: nsText)
            let end = offset(of: edit.range.end, in: nsText)
            mutable.replaceCharacters(
                in: NSRange(location: start, length: max(end - start, 0)),
                with: edit.newText
            )
        }
        return mutable as String
    }

    /// 从后往前应用编辑，前面的修改不会使后面的偏移失效。
    private static func sortedDescending(_ edits: [TextEdit]) -> [TextEdit] {
        edits.sorted { lhs, rhs in
            if lhs.range.start.line != rhs.range.start.line {
                return lhs.range.start.line > rhs.range.start.line
            }
            return lhs.range.start.character > rhs.range.start.character
        }
    }

    /// LSP 位置（0-based 行 + UTF-16 列）转字符串内 UTF-16 偏移。
    static func offset(of position: Position, in nsText: NSString) -> Int {
        let targetLine = max(position.line, 0)
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        var currentLine = 0
        var location = 0
        while currentLine < targetLine {
            if location >= nsText.length { return nsText.length }
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            if lineEnd >= nsText.length { return nsText.length }
            location = lineEnd
            currentLine += 1
        }
        let lineLength = max(nsText.length - location, 0)
        return min(location + max(position.character, 0), location + lineLength)
    }

    /// 光标处的标识符，用于重命名输入框预填。
    static func word(at position: Position, in text: String) -> String {
        let nsText = text as NSString
        let offset = Self.offset(of: position, in: nsText)
        guard offset < nsText.length else { return "" }
        let identifier = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
        )
        func isIdentifierChar(_ char: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(char) else { return false }
            return identifier.contains(scalar)
        }
        var start = offset
        while start > 0, isIdentifierChar(nsText.character(at: start - 1)) {
            start -= 1
        }
        var end = offset
        while end < nsText.length, isIdentifierChar(nsText.character(at: end)) {
            end += 1
        }
        guard end > start else { return "" }
        return nsText.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - 响应类型转换

    private static func locations(from response: DefinitionResponse) -> [Location] {
        guard let response else { return [] }
        switch response {
        case .optionA(let location):
            return [location]
        case .optionB(let locations):
            return locations
        case .optionC(let links):
            return links.map {
                Location(uri: $0.targetUri, range: $0.targetSelectionRange)
            }
        }
    }

    private static func hoverText(_ hover: HoverResponse) -> String {
        guard let hover else { return "" }
        func marked(_ value: MarkedString) -> String {
            switch value {
            case .optionA(let string): return string
            case .optionB(let pair): return pair.value
            }
        }
        switch hover.contents {
        case .optionA(let value):
            return marked(value)
        case .optionB(let values):
            return values.map(marked).joined(separator: "\n\n")
        case .optionC(let markup):
            return markup.value
        }
    }

    /// LSP URI 转本地文件 URL。
    static func fileURL(from uri: String) -> URL? {
        if let url = URL(string: uri), url.isFileURL {
            return url.standardizedFileURL
        }
        return URL(fileURLWithPath: uri)
    }

    private static func open(location: Location, workspace: WorkspaceDocument?) {
        let target = fileURL(from: location.uri) ?? URL(fileURLWithPath: location.uri)
        let file = workspace?.workspaceFileManager?.getFile(target.path, createIfNotFound: true)
            ?? CEWorkspaceFile(url: target)
        workspace?.editorManager?.openTab(item: file, asTemporary: true)
    }

    private static func openDocument(for url: URL) -> CodeFileDocument? {
        CodeEditDocumentController.shared.documents
            .compactMap { $0 as? CodeFileDocument }
            .first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: - 提示

    private static func notify(_ title: String, _ description: String) {
        NotificationManager.shared.post(
            iconSymbol: "info.circle",
            title: title,
            description: description,
            actionButtonTitle: "",
            action: {}
        )
    }

    private static func notifyError(_ title: String, _ error: Error) {
        NotificationManager.shared.post(
            iconSymbol: "exclamationmark.triangle.fill",
            title: title,
            description: error.localizedDescription,
            actionButtonTitle: "",
            action: {}
        )
    }

    private static func notifyMissingContext(_ title: String) {
        notify(
            title,
            NSLocalizedString("Place the cursor on a symbol first.", comment: "")
        )
    }

    private static func notifyNoServer(_ title: String) {
        notify(
            title,
            NSLocalizedString(
                "No language server is running for this file. Configure one in Settings → Developer.",
                comment: ""
            )
        )
    }
}
