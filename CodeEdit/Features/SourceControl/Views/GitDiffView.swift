//
//  GitDiffView.swift
//  CodeEdit
//
//  改动文件的差异视图：以独立窗口展示某个文件相对 HEAD 的行级差异。
//

import AppKit
import SwiftUI

/// 差异窗口的持有者。`NSWindow` 出屏后即被释放，这里保强引用。
enum GitDiffWindowPresenter {
    private static var openWindows: [NSWindow] = []

    /// 打开（或聚焦）一个文件的差异窗口。
    static func show(file: GitChangedFile, manager: SourceControlManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = file.fileURL.lastPathComponent
        window.contentView = NSHostingView(
            rootView: GitDiffView(file: file).environmentObject(manager)
        )
        window.center()
        window.isReleasedWhenClosed = false
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

/// 单文件的行级差异视图（统一布局：旧行号 | 新行号 | 内容）。
struct GitDiffView: View {
    let file: GitChangedFile

    @EnvironmentObject private var manager: SourceControlManager
    @State private var rows: [GitClient.DiffRow] = []
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let errorText {
                errorView(errorText)
            } else if rows.isEmpty {
                CEContentUnavailableView(
                    NSLocalizedString("No textual changes", comment: ""),
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                diffList
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: file.id) {
            await load()
        }
    }

    // MARK: - 子视图

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileURL.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(displayPath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !rows.isEmpty {
                Text("+\(addedCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.green)
                Text("-\(removedCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var diffList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    diffRow(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffRow(_ row: GitClient.DiffRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(numberText(row.oldNumber))
                .frame(width: 44, alignment: .trailing)
            Text(numberText(row.newNumber))
                .frame(width: 44, alignment: .trailing)
            Text(marker(row.kind))
                .frame(width: 18)
                .foregroundColor(markerColor(row.kind))
            Text(row.text.isEmpty ? " " : row.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundColor(row.kind == .context ? .primary : markerColor(row.kind))
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(background(row.kind))
    }

    private func errorView(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(NSLocalizedString("Retry", comment: "")) {
                Task { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - 数据

    private func load() async {
        let key = file.id
        do {
            let result = try await manager.diff(for: file)
            // 只接受仍然对应当前文件的请求结果，避免快速切换时旧数据覆盖新数据。
            guard key == file.id else { return }
            rows = result
            errorText = nil
        } catch {
            guard key == file.id else { return }
            errorText = error.localizedDescription
        }
    }

    private var displayPath: String {
        let root = manager.workspaceURL.standardizedFileURL.path
        let path = file.fileURL.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1)) + "  ·  " + NSLocalizedString("vs HEAD", comment: "")
        }
        return path + "  ·  " + NSLocalizedString("vs HEAD", comment: "")
    }

    private var addedCount: Int {
        rows.filter { $0.kind == .added }.count
    }

    private var removedCount: Int {
        rows.filter { $0.kind == .removed }.count
    }

    // MARK: - 样式

    private func numberText(_ number: Int?) -> String {
        guard let number else { return "" }
        return String(number)
    }

    private func marker(_ kind: GitClient.DiffRow.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func background(_ kind: GitClient.DiffRow.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.13)
        case .removed: return Color.red.opacity(0.13)
        case .context: return .clear
        }
    }

    private func markerColor(_ kind: GitClient.DiffRow.Kind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .context: return .secondary
        }
    }
}
