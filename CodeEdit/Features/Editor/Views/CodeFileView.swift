//
//  CodeFileView.swift
//  CodeEditModules/CodeFile
//
//  Created by Marco Carnevali on 17/03/22.
//

import Foundation
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import Combine

/// CodeFileView is just a wrapper of the `CodeEditor` dependency
struct CodeFileView: View {
    @ObservedObject private var editorInstance: EditorInstance
    @ObservedObject private var codeFile: CodeFileDocument

    /// Any coordinators passed to the view.
    private var textViewCoordinators: [TextViewCoordinator]

    /// 高亮 provider 必须长期稳定。
    ///
    /// 这里踩过一个很隐蔽的坑：provider 原来是在 `init` 里组装成一个普通属性的，
    /// 而 `TreeSitterClient` 由 `@State` 的初始化表达式创建。SwiftUI 每次重建这个
    /// View 都会重新执行 init（实测打开一个文件就会重建 4 次），于是每次都产出一个
    /// 新的 client 实例。`Highlighter.setProviders` 是按 `ObjectIdentifier` 判断
    /// provider 是否变化的，实例一变就把整条高亮管线拆掉重建：解析树丢弃、查询重跑。
    /// 结果是高亮永远处在“刚开始算”的状态，看起来就是没有高亮、也没有语法解析能力。
    ///
    /// 现在 provider 全部由 `@State` 持有（跨重建复用同一实例），数组在 body 里现算
    /// （元素不变，`setProviders` 就能识别为“没有变化”）。
    @State private var treeSitterClient = TreeSitterClient()
    @State private var xmlHighlightProvider = XMLHighlightProvider()

    /// 当前文件该用哪些高亮 provider。
    ///
    /// 必须是 computed：数组每次求值都新建，但元素是 `@State` 里的同一批实例，
    /// `Highlighter.setProviders` 按对象身份比较后会发现「没有变化」，不会重建管线。
    private var resolvedHighlightProviders: [any HighlightProviding] {
        if codeFile.getLanguage().tsName == "XML" {
            return [xmlHighlightProvider]
        }
        return [codeFile.languageServerObjects.highlightProvider, treeSitterClient]
    }

    @AppSettings(\.textEditing.defaultTabWidth)
    var defaultTabWidth
    @AppSettings(\.textEditing.indentOption)
    var indentOption
    @AppSettings(\.textEditing.lineHeightMultiple)
    var lineHeightMultiple
    @AppSettings(\.textEditing.wrapLinesToEditorWidth)
    var wrapLinesToEditorWidth
    @AppSettings(\.textEditing.overscroll)
    var overscroll
    @AppSettings(\.textEditing.font)
    var settingsFont
    @AppSettings(\.theme.useThemeBackground)
    var useThemeBackground
    @AppSettings(\.theme.matchAppearance)
    var matchAppearance
    @AppSettings(\.textEditing.letterSpacing)
    var letterSpacing
    @AppSettings(\.textEditing.bracketEmphasis)
    var bracketEmphasis
    @AppSettings(\.textEditing.useSystemCursor)
    var useSystemCursor
    @AppSettings(\.textEditing.showGutter)
    var showGutter
    @AppSettings(\.textEditing.showMinimap)
    var showMinimap
    @AppSettings(\.textEditing.showFoldingRibbon)
    var showFoldingRibbon
    @AppSettings(\.textEditing.reformatAtColumn)
    var reformatAtColumn
    @AppSettings(\.textEditing.showReformattingGuide)
    var showReformattingGuide
    @AppSettings(\.textEditing.invisibleCharacters)
    var invisibleCharactersConfiguration
    @AppSettings(\.textEditing.warningCharacters)
    var warningCharacters

    @Environment(\.colorScheme)
    private var colorScheme

    @EnvironmentObject var undoRegistration: UndoManagerRegistration

    @ObservedObject private var themeModel: ThemeModel = .shared

    private var cancellables = Set<AnyCancellable>()

    private let isEditable: Bool

    init(
        editorInstance: EditorInstance,
        codeFile: CodeFileDocument,
        textViewCoordinators: [TextViewCoordinator] = [],
        isEditable: Bool = true
    ) {
        self._editorInstance = .init(wrappedValue: editorInstance)
        self._codeFile = .init(wrappedValue: codeFile)

        self.textViewCoordinators = textViewCoordinators
            + [editorInstance.rangeTranslator]
            + [codeFile.contentCoordinator]
            + [codeFile.languageServerObjects.textCoordinator]
        // 行级 blame 标注：协调器由 codeFile 强持有（TextViewController 侧是弱引用）。
        if codeFile.gitBlameCoordinator == nil {
            codeFile.gitBlameCoordinator = GitBlameCoordinator(
                fileURL: editorInstance.file.url,
                codeFile: codeFile
            )
        }
        if let blameCoordinator = codeFile.gitBlameCoordinator {
            self.textViewCoordinators.append(blameCoordinator)
        }
        self.isEditable = isEditable

        if let openOptions = codeFile.openOptions {
            codeFile.openOptions = nil
            editorInstance.cursorPositions = openOptions.cursorPositions
        }

        // XML 族走词法高亮（精确区分标签/属性/注释/CDATA），其余语言走 tree-sitter + LSP 语义 token。
        // 语言名与 CodeEditLanguages 中的 tsName 保持一致（XML / markdown）。
        // 数组本身在 body 里现算（见 `resolvedHighlightProviders`），这里不再组装。

        codeFile
            .contentCoordinator
            .textUpdatePublisher
            .sink { [weak codeFile] _ in
                codeFile?.updateChangeCount(.changeDone)
            }
            .store(in: &cancellables)
    }

    private var currentTheme: Theme {
        themeModel.selectedTheme ?? themeModel.themes.first!
    }

    @State private var font: NSFont = Settings[\.textEditing].font.current

    @Environment(\.edgeInsets)
    private var edgeInsets

    var body: some View {
        SourceEditor(
            codeFile.content ?? NSTextStorage(),
            language: codeFile.getLanguage(),
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: currentTheme.editor.editorTheme,
                    useThemeBackground: useThemeBackground,
                    font: font,
                    lineHeightMultiple: lineHeightMultiple,
                    letterSpacing: letterSpacing,
                    wrapLines: wrapLinesToEditorWidth,
                    useSystemCursor: useSystemCursor,
                    tabWidth: defaultTabWidth,
                    bracketPairEmphasis: getBracketPairEmphasis()
                ),
                behavior: .init(
                    isEditable: isEditable,
                    indentOption: indentOption.textViewOption(),
                    reformatAtColumn: reformatAtColumn
                ),
                layout: .init(
                    editorOverscroll: overscroll.overscrollPercentage,
                    contentInsets: edgeInsets.nsEdgeInsets,
                    additionalTextInsets: NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
                ),
                peripherals: .init(
                    showGutter: showGutter,
                    showMinimap: showMinimap,
                    showReformattingGuide: showReformattingGuide,
                    showFoldingRibbon: showFoldingRibbon,
                    invisibleCharactersConfiguration: invisibleCharactersConfiguration.textViewOption(),
                    warningCharacters: Set(warningCharacters.characters.keys)
                )
            ),
            state: Binding(
                get: {
                    SourceEditorState(
                        cursorPositions: editorInstance.cursorPositions,
                        scrollPosition: editorInstance.scrollPosition,
                        findText: editorInstance.findText,
                        replaceText: editorInstance.replaceText
                    )
                },
                set: { newState in
                    editorInstance.cursorPositions = newState.cursorPositions ?? []
                    editorInstance.scrollPosition = newState.scrollPosition
                    editorInstance.findText = newState.findText
                    editorInstance.findTextSubject.send(newState.findText)
                    editorInstance.replaceText = newState.replaceText
                    editorInstance.replaceTextSubject.send(newState.replaceText)
                }
            ),
            highlightProviders: resolvedHighlightProviders,
            undoManager: undoRegistration.manager(forFile: editorInstance.file),
            coordinators: textViewCoordinators
        )
        // This view needs to refresh when the codefile changes. The file URL is too stable.
        .id(ObjectIdentifier(codeFile))
        .background {
            if colorScheme == .dark {
                EffectView(.underPageBackground)
            } else {
                EffectView(.contentBackground)
            }
        }
        .colorScheme(currentTheme.appearance == .dark ? .dark : .light)
        // minHeight zero fixes a bug where the app would freeze if the contents of the file are empty.
        .frame(minHeight: .zero, maxHeight: .infinity)
        .onChange(of: settingsFont) { _, newFontSetting in
            font = newFontSetting.current
        }
    }

    /// Determines the style of bracket emphasis based on the `bracketEmphasis` setting and the current theme.
    /// - Returns: The emphasis style to use for bracket pair emphasis.
    private func getBracketPairEmphasis() -> BracketPairEmphasis? {
        let color = if Settings[\.textEditing].bracketEmphasis.useCustomColor {
            Settings[\.textEditing].bracketEmphasis.color.nsColor
        } else {
            currentTheme.editor.text.nsColor.withAlphaComponent(0.8)
        }

        switch Settings[\.textEditing].bracketEmphasis.highlightType {
        case .disabled:
            return nil
        case .flash:
            return .flash
        case .bordered:
            return .bordered(color: color)
        case .underline:
            return .underline(color: color)
        }
    }
}

// This extension is kept here because it should not be used elsewhere in the app and may cause confusion
// due to the similar type name from the CETV module.
private extension SettingsData.TextEditingSettings.IndentOption {
    func textViewOption() -> IndentOption {
        switch self.indentType {
        case .spaces:
            return IndentOption.spaces(count: spaceCount)
        case .tab:
            return IndentOption.tab
        }
    }
}

private extension SettingsData.TextEditingSettings.InvisibleCharactersConfig {
    func textViewOption() -> InvisibleCharactersConfiguration {
        guard self.enabled else { return .empty }
        var config = InvisibleCharactersConfiguration(
            showSpaces: self.showSpaces,
            showTabs: self.showTabs,
            showLineEndings: self.showLineEndings
        )

        config.spaceReplacement = self.spaceReplacement
        config.tabReplacement = self.tabReplacement
        config.carriageReturnReplacement = self.carriageReturnReplacement
        config.lineFeedReplacement = self.lineFeedReplacement
        config.paragraphSeparatorReplacement = self.paragraphSeparatorReplacement
        config.lineSeparatorReplacement = self.lineSeparatorReplacement

        return config
    }
}
