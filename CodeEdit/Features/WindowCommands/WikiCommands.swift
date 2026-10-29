//
//  WikiCommands.swift
//  CodeEdit
//
//  菜单栏「知识库」：图谱入口与新建条目。
//
//  入口必须显眼——知识库如果藏在某个侧栏页签里，三天后就不会有人再点开。
//

import AppKit
import SwiftUI

struct WikiCommands: Commands {

    @UpdatingWindowController var windowController: CodeEditWindowController?

    var body: some Commands {
        CommandMenu("知识库") {
            Button("领域建模…") {
                DomainModelWindowPresenter.show(workspace: windowController?.workspace)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(windowController?.workspace?.fileURL == nil)

            Button("打开知识图谱…") {
                WikiWindowPresenter.show(workspace: windowController?.workspace)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            Menu("新建条目") {
                ForEach(WikiEntryType.allCases) { type in
                    Button(type.title) { createEntry(type: type) }
                }
            }
            .disabled(windowController?.workspace?.fileURL == nil)

            Divider()

            Button("在 Finder 中显示 .qiyide/wiki") {
                revealDirectory()
            }
            .disabled(windowController?.workspace?.fileURL == nil)
        }
    }

    private func createEntry(type: WikiEntryType) {
        guard let root = windowController?.workspace?.fileURL else { return }
        let store = WikiStore(root: root)
        _ = try? store.create(type: type)
        WikiWindowPresenter.show(workspace: windowController?.workspace)
    }

    private func revealDirectory() {
        guard let root = windowController?.workspace?.fileURL else { return }
        let directory = root.appending(path: ".qiyide/wiki", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }
}
