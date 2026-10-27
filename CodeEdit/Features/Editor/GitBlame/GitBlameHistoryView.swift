//
//  GitBlameHistoryView.swift
//  CodeEdit
//
//  行历史面板：某一行的完整变更历史 + 对应提交详情（新增/修改/删除都在 diff 里）。
//

import AppKit
import SwiftUI

/// 行历史窗口的持有者（NSWindow 出屏后需要强引用保活）。
enum GitBlameHistoryPresenter {
    private static var openWindows: [NSWindow] = []

    static func show(file: URL, line: Int, blame: GitBlameLine?, codeFile: CodeFileDocument?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(file.lastPathComponent):\(line)"
        window.contentView = NSHostingView(
            rootView: GitBlameHistoryView(file: file, line: line, blame: blame, codeFile: codeFile)
        )
        window.center()
        window.isReleasedWhenClosed = false
        openWindows.removeAll { !$0.isVisible }
        openWindows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}

struct GitBlameHistoryView: View {
    let file: URL
    let line: Int
    let blame: GitBlameLine?
    let codeFile: CodeFileDocument?

    @State private var entries: [GitLineHistoryEntry] = []
    @State private var phase: Phase = .loading
    @State private var selectedID: GitLineHistoryEntry.ID?
    @State private var commitDetail: String = ""
    @State private var detailLoading = false

    enum Phase: Equatable {
        case loading
        case ready
        case empty
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 380)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: line) {
            await load()
        }
    }

    // MARK: - 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: NSLocalizedString("Line %d history", comment: ""), line))
                .font(.system(size: 13, weight: .medium))
            if let blame {
                Text(blame.annotationText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if blame?.isNotCommitted == true {
                Text(NSLocalizedString("This line has uncommitted changes; history shows committed revisions only.", comment: ""))
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            CEContentUnavailableView(
                NSLocalizedString("No committed history for this line", comment: ""),
                systemImage: "clock.arrow.circlepath"
            )
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundColor(.orange)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button(NSLocalizedString("Retry", comment: "")) {
                    Task { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        case .ready:
            VSplitView {
                entryList
                    .frame(minHeight: 120)
                detailPane
                    .frame(minHeight: 140)
            }
        }
    }

    private var selectedEntry: GitLineHistoryEntry? {
        entries.first { $0.id == selectedID }
    }

    private var entryList: some View {
        List(entries, selection: $selectedID) { entry in
            entryRow(entry)
                .tag(entry.id)
        }
        .listStyle(.inset)
    }

    private func entryRow(_ entry: GitLineHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.commitHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.accentColor)
                Text(entry.summary)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(entry.date)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text(entry.author)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(NSLocalizedString("Change", comment: ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let selectedEntry, detailLoading {
                    ProgressView().scaleEffect(0.6)
                } else if let selectedEntry {
                    Button(NSLocalizedString("Full Commit", comment: "")) {
                        Task { await loadCommitDetail(selectedEntry) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                Text(detailText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private var detailText: String {
        if !commitDetail.isEmpty {
            return commitDetail
        }
        return selectedEntry?.diff
            ?? NSLocalizedString("Select a commit to view its change.", comment: "")
    }

    // MARK: - 数据

    private func load() async {
        phase = .loading
        guard let workspace = codeFile?.findWorkspace(),
              let manager = workspace.sourceControlManager,
              manager.isGitRepository else {
            phase = .failed(NSLocalizedString("Not a git repository.", comment: ""))
            return
        }
        do {
            let result = try await manager.lineHistory(for: file, startLine: line, endLine: line)
            entries = result
            selectedID = result.first?.id
            commitDetail = ""
            phase = result.isEmpty ? .empty : .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadCommitDetail(_ entry: GitLineHistoryEntry) async {
        guard let workspace = codeFile?.findWorkspace(),
              let manager = workspace.sourceControlManager else { return }
        detailLoading = true
        defer { detailLoading = false }
        do {
            commitDetail = try await manager.commitDetail(hash: entry.commitHash)
        } catch {
            commitDetail = error.localizedDescription
        }
    }
}
