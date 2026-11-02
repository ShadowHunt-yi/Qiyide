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
            // 主入口：领域、条目、导图、图谱、架构都在一个窗口里。
            Button("打开知识库…") {
                WikiWindowPresenter.show(workspace: windowController?.workspace)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            // 全屏建模保留独立窗口：导图在 1280 宽的三栏里只有 500 出头，
            // 人工锚定（拖拽、改名、合并）时大画布更好用。日常查看走上面那个。
            Button("全屏建模…") {
                DomainModelWindowPresenter.show(workspace: windowController?.workspace)
            }
            .keyboardShortcut("d", modifiers: [.command, .option])
            .disabled(windowController?.workspace?.fileURL == nil)

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
