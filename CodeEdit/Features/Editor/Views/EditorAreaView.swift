//
//  EditorAreaView.swift
//  CodeEdit
//
//  Created by Wouter Hennen on 16/02/2023.
//

import SwiftUI
import CodeEditTextView
import UniformTypeIdentifiers

struct EditorAreaView: View {
    @AppSettings(\.general.showEditorJumpBar)
    var showEditorJumpBar

    @AppSettings(\.navigation.navigationStyle)
    var navigationStyle

    @AppSettings(\.general.dimEditorsWithoutFocus)
    var dimEditorsWithoutFocus

    @ObservedObject var editor: Editor

    @FocusState.Binding var focus: Editor?

    @EnvironmentObject private var editorManager: EditorManager

    @State var codeFile: (() -> CodeFileDocument?)?

    /// 拖拽文件悬停在编辑区上时为 true，用于高亮提示。
    @State private var isDropTargeted = false

    @Environment(\.window.value)
    private var window: NSWindow?

    @Environment(\.isEditorLayoutAtEdge)
    private var isAtEdge

    init(editor: Editor, focus: FocusState<Editor?>.Binding) {
        self.editor = editor
        self._focus = focus
        if let file = editor.selectedTab?.file.fileDocument {
            self.codeFile = { [weak file] in file }
        }
    }

    var body: some View {
        var shouldShowTabBar: Bool {
            return navigationStyle == .openInTabs
            || editorManager.flattenedEditors.contains { editor in
                (editor.temporaryTab == nil && !editor.tabs.isEmpty)
                || (editor.temporaryTab != nil && editor.tabs.count > 1)
            }
        }

        var editorInsetAmount: Double {
            let tabBarHeight = shouldShowTabBar ? (EditorTabBarView.height) : 0
            let jumpBarHeight = showEditorJumpBar ? (EditorJumpBarView.height) : 0
            return tabBarHeight + jumpBarHeight
        }

        VStack {
            if let selected = editor.selectedTab {
                if let diffSource = selected.diffSource {
                    // 差异标签：VS Code 式并排对比，不走文件文档加载路径。
                    GitDiffTabView(source: diffSource)
                        .focusedObject(editor)
                        .transformEnvironment(\.edgeInsets) { insets in
                            insets.top += editorInsetAmount
                        }
                        .opacity(dimEditorsWithoutFocus && editor != editorManager.activeEditor ? 0.5 : 1)
                } else if let codeFile = codeFile?() {
                    // Markdown 开启预览时源码 | 预览分栏；其余情况只显示源码。
                    MarkdownEditorContainerView(editorInstance: selected, codeFile: codeFile)
                        .focusedObject(editor)
                        .transformEnvironment(\.edgeInsets) { insets in
                            insets.top += editorInsetAmount
                        }
                        .opacity(dimEditorsWithoutFocus && editor != editorManager.activeEditor ? 0.5 : 1)
                } else {
                    LoadingFileView(selected.file.name)
                        .onAppear {
                            if let file = selected.file.fileDocument {
                                self.codeFile = { [weak file] in file }
                            }
                        }
                        .onReceive(selected.file.fileDocumentPublisher) { latestValue in
                            self.codeFile = { [weak latestValue] in latestValue }
                        }
                }
            } else {
                CEContentUnavailableView("No Editor")
                    .padding(.top, editorInsetAmount)
                    .onTapGesture {
                        editorManager.activeEditor = editor
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 拖放统一挂在容器上：任何标签内容（文件、差异、空状态）都可接收拖入的文件。
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            _ = handleDrop(providers: providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.06))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.all)
        .safeAreaInset(edge: .top, spacing: 0) {
            GeometryReader { geometry in
                let topSafeArea = geometry.safeAreaInsets.top
                let fileBinding = Binding {
                    codeFile?()
                } set: { newFile in
                    codeFile = { [weak newFile] in newFile }
                }

                VStack(spacing: 0) {
                    if isAtEdge != .top, #available(macOS 26, *) {
                        Spacer().frame(height: 4)
                    }

                    if topSafeArea > 0 {
                        Rectangle()
                            .fill(.clear)
                            .frame(height: 1)
                            .background(.clear)
                    }
                    if shouldShowTabBar {
                        EditorTabBarView(hasTopInsets: topSafeArea > 0, codeFile: fileBinding)
                            .id("TabBarView" + editor.id.uuidString)
                            .environmentObject(editor)
                        if #unavailable(macOS 26) {
                            Divider()
                        }
                    }
                    if showEditorJumpBar {
                        EditorJumpBarView(
                            file: editor.selectedTab?.file,
                            shouldShowTabBar: shouldShowTabBar,
                            codeFile: fileBinding
                        ) { [weak editor] newFile in
                            if let file = editor?.selectedTab, let index = editor?.tabs.firstIndex(of: file) {
                                editor?.openTab(file: newFile, at: index)
                            }
                        }
                        .environmentObject(editor)
                        .padding(.top, shouldShowTabBar ? -1 : 0)
                        if #unavailable(macOS 26) {
                            Divider()
                        }
                    }
                    // On Tahoe we only show one divider
                    if #available(macOS 26, *), shouldShowTabBar || showEditorJumpBar {
                        Divider()
                    }
                }
                .environment(\.isActiveEditor, editor == editorManager.activeEditor)
                .if(.tahoe) {
                    // FB20047271: Glass toolbar effect ignores floating scroll view views.
                    // https://openradar.appspot.com/radar?id=EhAKBVJhZGFyEICAgKbGmesJ

                    // FB20191516: Can't disable backgrounded liquid glass tint
                    // https://openradar.appspot.com/radar?id=EhAKBVJhZGFyEICAgLqTk-4J
                    // Tracking Issue: #2191
                    // Add this to the top:
                    // ```
                    // @AppSettings(\.theme.useThemeBackground)
                    // var useThemeBackground
                    //
                    // private var backgroundColor: NSColor {
                    //     let fallback = NSColor.textBackgroundColor
                    //     return if useThemeBackground {
                    //         ThemeModel.shared.selectedTheme?.editor.background.nsColor ?? fallback
                    //     } else {
                    //         fallback
                    //     }
                    // }
                    // ```
                    // And use this:
                    // ```
                    // $0.background(
                    //    Rectangle().fill(.clear)
                    //        .glassEffect(.regular.tint(Color(backgroundColor))
                    //        .ignoresSafeArea(.all)
                    // )
                    // ```
                    // When we can figure out how to disable the 'not focused' glass effect.

                    $0.background(EffectView(.headerView).ignoresSafeArea(.all))
                } else: {
                    $0.background(EffectView(.headerView))
                }
            }
        }
        .focused($focus, equals: editor)
        // Fixing this is causing a malloc exception when a file is edited & closed. See #1886
//        .onReceive(NotificationCenter.default.publisher(for: TextView.textDidChangeNotification)) { _ in
//            if navigationStyle == .openInTabs {
//                editor.temporaryTab = nil
//            }
//        }
        .onChange(of: navigationStyle) { _, newValue in
            if newValue == .openInPlace && editor.tabs.count == 1 {
                editor.temporaryTab = editor.tabs[0]
            }
        }
        .onChange(of: editor.selectedTab) { _, newValue in
            if let file = newValue?.file.fileDocument {
                codeFile = { [weak file] in file }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    return
                }

                DispatchQueue.main.async {
                    let file = CEWorkspaceFile(url: url)
                    editorManager.activeEditor = editor
                    editor.openTab(file: file)
                }
            }
        }
        return true
    }
}
