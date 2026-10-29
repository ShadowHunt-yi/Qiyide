//
//  NotificationToolbarItem.swift
//  CodeEdit
//
//  Created by Austin Condiff on 2/10/24.
//

import SwiftUI

struct NotificationToolbarItem: View {
    @EnvironmentObject private var workspace: WorkspaceDocument
    @ObservedObject private var notificationManager = NotificationManager.shared
    @Environment(\.controlActiveState)
    private var controlActiveState

    var body: some View {
        let visibleNotifications = workspace.notificationPanel.visibleNotifications

        if notificationManager.unreadCount > 0 || !visibleNotifications.isEmpty {
            Button {
                workspace.notificationPanel.toggleNotificationsVisibility()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bell.badge.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(controlActiveState == .inactive ? .secondary : Color.accentColor, .primary)
                    Text("\(notificationManager.unreadCount)")
                        .monospacedDigit()
                }
            }
        } else {
            // 没有通知时必须给一个确定尺寸的空视图。
            // 之前这里是隐式 EmptyView，宿主视图量出来是 0×0，
            // AppKit 在自动测量工具栏项时就报 "ambiguous height or width"。
            Color.clear
                .frame(width: 0, height: 22)
                .accessibilityHidden(true)
        }
    }
}
