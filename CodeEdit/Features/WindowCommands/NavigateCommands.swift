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
        }
    }
}
