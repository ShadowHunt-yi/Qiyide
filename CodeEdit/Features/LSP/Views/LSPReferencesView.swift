//
//  LSPReferencesView.swift
//  CodeEdit
//
//  「查找引用」结果窗口：按文件分组列出引用位置，点击打开对应文件。
//

import AppKit
import SwiftUI

/// 一条引用结果。
struct LSPReferenceRow: Identifiable {
    let id = UUID()
    let url: URL
    /// 1-indexed 行号。
    let line: Int
    /// 1-indexed 列号。
    let character: Int
    let text: String
}

/// 引用结果窗口的持有者，出屏后窗口需要强引用保活。
enum LSPReferencesWindowPresenter {
    private static var openWindows: [NSWindow] = []

    static func show(
        title: String,
        rows: [LSPReferenceRow],
        total: Int,
        workspace: WorkspaceDocument?
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            format: NSLocalizedString("References (%d)", comment: ""),
            total
        ) + " · " + title
        window.contentView = NSHostingView(
            rootView: LSPReferencesView(rows: rows, workspace: workspace)
        )
        window.center()
        window.isReleasedWhenClosed = false
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

struct LSPReferencesView: View {
    let rows: [LSPReferenceRow]
    let workspace: WorkspaceDocument?

    /// 按文件路径分组，保持文件名排序稳定。
    private var grouped: [(path: String, rows: [LSPReferenceRow])] {
        Dictionary(grouping: rows, by: { $0.url.path })
            .sorted { $0.key < $1.key }
            .map { (path: $0.key, rows: $0.value) }
    }

    var body: some View {
        List {
            ForEach(grouped, id: \.path) { group in
                Section {
                    ForEach(group.rows) { row in
                        referenceRow(row)
                    }
                } header: {
                    Text(group.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 640, minHeight: 380)
    }

    private func referenceRow(_ row: LSPReferenceRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(":\(row.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
            Text(row.text.trimmingCharacters(in: .whitespaces))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            open(row)
        }
        .help(String(format: NSLocalizedString("Open at line %d", comment: ""), row.line))
    }

    private func open(_ row: LSPReferenceRow) {
        let file = workspace?.workspaceFileManager?.getFile(
            row.url.path,
            createIfNotFound: true
        ) ?? CEWorkspaceFile(url: row.url)
        workspace?.editorManager?.openTab(item: file, asTemporary: true)
    }
}
