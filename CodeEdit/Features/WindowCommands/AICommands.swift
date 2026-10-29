//
//  AICommands.swift
//  CodeEdit
//
//  菜单栏「AI」菜单。
//
//  之前 AI 改动审查只挂在 View 菜单里、且是英文名，实际很难被发现。
//  这里单独开一个顶级菜单，把两个入口都摆出来。
//

import SwiftUI

struct AICommands: Commands {
    @UpdatingWindowController var windowController: CodeEditWindowController?

    @Environment(\.openWindow)
    private var openWindow

    @AppSettings(\.sourceControl.general.sourceControlIsEnabled)
    private var sourceControlIsEnabled

    var body: some Commands {
        CommandMenu("AI") {
            Button("AI 改动审查…") {
                AIReviewWindowPresenter.show(workspace: windowController?.workspace)
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(!sourceControlIsEnabled)

            // 设置窗口是自定义 Window 场景，必须走 openWindow；
            // showSettingsWindow: 在这个应用里没有响应者。
            Button("AI 叙述设置…") {
                SettingsNavigation.shared.request(.ai)
                openWindow(sceneID: .settings)
            }

            Divider()

            // 不写入敏感信息，只给一个「能不能用」的判断依据。
            Text(AINarrativeMenuStatus.text)
        }
    }
}

/// 菜单里的状态文案。
///
/// 菜单项在 SwiftUI 里不方便做富交互，这里只读配置，不发起任何请求。
@MainActor
enum AINarrativeMenuStatus {
    static var text: String {
        let config = AINarrativeStore.shared.configuration
        guard config.isEnabled else { return "AI 叙述：未开启" }
        switch config.mode {
        case .ccSwitchProxy:
            return "AI 叙述：cc-switch · \(config.ccSwitchModel)"
        case .manual:
            return "AI 叙述：\(config.provider.rawValue) · \(config.model)"
        }
    }
}
