//
//  SettingsNavigation.swift
//  CodeEdit
//
//  让「从别处打开设置」能直接落到指定页面。
//
//  设置窗口是自定义 Window 场景，⌘, 之外的入口（例如 AI 菜单里的「AI 叙述设置…」）
//  打开后会停在上次看的那一页。这里放一个一次性的跳转请求，
//  SettingsView 收到后切页并立刻消费掉，避免下次 ⌘, 又被拽到 AI 页。
//

import Combine
import Foundation

@MainActor
final class SettingsNavigation: ObservableObject {

    static let shared = SettingsNavigation()

    /// 待处理的跳转目标。置位后由设置窗口消费。
    @Published var requestedPage: SettingsPage.Name?

    private init() { }

    func request(_ page: SettingsPage.Name) {
        requestedPage = page
    }
}
