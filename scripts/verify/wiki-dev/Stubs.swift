//
//  Stubs.swift
//  scripts/verify/wiki-dev
//
//  知识库功能在 App 里只碰到这几个外部类型。这里给出最小替身，
//  让 `CodeEdit/Features/Wiki` 与 `CodeEdit/Features/AIReview` 能脱离 Xcode 工程单独编译。
//
//  替身只满足「编译通过 + 行为可观察」：打开文件之类的动作打一行日志，不做真事。
//  如果知识库代码新增了对 App 其他类型的依赖，这里会编译失败——这正是想要的提醒。
//

import Foundation

final class CEWorkspaceFile {
    let url: URL
    init(url: URL) { self.url = url }
}

final class StubEditorTab {
    let file: CEWorkspaceFile
    init(file: CEWorkspaceFile) { self.file = file }
}

final class StubEditor {
    var selectedTab: StubEditorTab?

    func openTab(file: CEWorkspaceFile, asTemporary: Bool) {
        selectedTab = StubEditorTab(file: file)
        print("[wiki-dev] 打开文件：\(file.url.path)")
    }
}

final class StubEditorManager {
    var activeEditor = StubEditor()
}

final class WorkspaceDocument {
    var fileURL: URL?
    var editorManager: StubEditorManager? = StubEditorManager()

    init(fileURL: URL?) { self.fileURL = fileURL }
}

final class NotificationManager {
    static let shared = NotificationManager()

    func post(
        iconSymbol: String,
        title: String,
        description: String,
        actionButtonTitle: String,
        action: @escaping () -> Void
    ) {
        print("[wiki-dev] 通知：\(title) — \(description)")
    }
}

// 架构任务的配置入口只验证路由，不打开真实设置窗口或读取凭据。
@MainActor
final class SettingsNavigation {
    enum Page { case ai }
    static let shared = SettingsNavigation()
    func request(_ page: Page) { print("[wiki-dev] 打开 AI 设置") }
}
