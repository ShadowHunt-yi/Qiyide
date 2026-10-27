//
//  NavigateCommands.swift
//  CodeEdit
//
//  Created by Wouter Hennen on 13/03/2023.
//

import SwiftUI

struct NavigateCommands: Commands {

    @UpdatingWindowController var windowController: CodeEditWindowController?
    private var editor: Editor? {
        windowController?.workspace?.editorManager?.activeEditor
    }

    var body: some Commands {
        CommandMenu("Navigate") {
            Group {
                Button("Reveal in Project Navigator") {
                    NSApp.sendAction(#selector(ProjectNavigatorViewController.revealFile(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("j", modifiers: [.shift, .command])

                Button("Reveal Changes in Navigator") {

                }
                .keyboardShortcut("m", modifiers: [.shift, .command])
                .disabled(true)

                Button("Open in Next Editor") {

                }
                .keyboardShortcut(",", modifiers: [.option, .command])
                .disabled(true)

                Button("Open in...") {

                }
                .disabled(true)

                Divider()

            }
            // 代码导航：把早已实现的 LSP 能力接到菜单上。
            // 语言服务器需要在 设置 → 开发者 中配置二进制路径后才会运行。
            Group {
                Button("Hover Info") {
                    Task { await LSPCodeActions.showHover(windowController?.workspace) }
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button("Go to Definition") {
                    Task { await LSPCodeActions.goToDefinition(windowController?.workspace) }
                }
                .keyboardShortcut("d", modifiers: [.command, .option])

                Button("Find References") {
                    Task { await LSPCodeActions.findReferences(windowController?.workspace) }
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Button("Rename Symbol") {
                    Task { await LSPCodeActions.renameSymbol(windowController?.workspace) }
                }
                .keyboardShortcut("r", modifiers: [.command, .control])

                Button("Format Document") {
                    Task { await LSPCodeActions.formatDocument(windowController?.workspace) }
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Divider()
            }
            Group {
                Button("Show Previous Tab") {
                    editor?.selectPreviousTab()
                }
                .keyboardShortcut("{", modifiers: [.command])
                .disabled(editor?.tabs.count ?? 0 <= 1)  // Disable if there's one or no tabs

                Button("Show Next Tab") {
                    editor?.selectNextTab()
                }
                .keyboardShortcut("}", modifiers: [.command])
                .disabled(editor?.tabs.count ?? 0 <= 1)  // Disable if there's one or no tabs
            }
            Group {
                Divider()

                Button("Go Forward") {
                    editor?.goForwardInHistory()
                }
                .disabled(!(editor?.canGoForwardInHistory ?? false))

                Button("Go Back") {
                    editor?.goBackInHistory()
                }
                .disabled(!(editor?.canGoBackInHistory ?? false))
            }
            .disabled(editor == nil)
            // 文件树一键折叠/展开（VS Code 的 Collapse/Expand Folders in Explorer）。
            // 与编辑器无关，不随 editor 禁用。
            Group {
                Divider()

                Button("Collapse All Folders") {
                    NotificationCenter.default.post(name: .projectNavigatorCollapseAll, object: nil)
                }
                .keyboardShortcut("9", modifiers: [.command, .option])
            }
            // git blame 行级标注
            Group {
                Divider()

                Button("Show Line History") {
                    GitBlameCoordinator.showHistoryForCurrentLine(workspace: windowController?.workspace)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Toggle("Show Line Blame Annotations", isOn: Binding(
                    get: { Settings.shared.preferences.sourceControl.general.showLineBlame },
                    set: { newValue in
                        Settings.shared.preferences.sourceControl.general.showLineBlame = newValue
                        NotificationCenter.default.post(name: .gitBlameSettingsDidChange, object: nil)
                    }
                ))
                .keyboardShortcut("b", modifiers: [.command, .option])
            }
        }
    }
}
