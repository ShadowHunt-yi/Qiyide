//
//  NavigatorTab.swift
//  CodeEdit
//
//  Created by Wouter Hennen on 02/06/2023.
//

import SwiftUI
import CodeEditKit
import ExtensionFoundation

enum NavigatorTab: WorkspacePanelTab {
    case project
    case sourceControl
    case search
    case uiExtension(endpoint: AppExtensionIdentity, data: ResolvedSidebar.SidebarStore)

    var systemImage: String {
        switch self {
        case .project:
            return "folder"
        case .sourceControl:
            return "vault"
        case .search:
            return "magnifyingglass"
        case .uiExtension(_, let data):
            return data.icon ?? "e.square"
        }
    }

    var id: String {
        if case .uiExtension(let endpoint, let data) = self {
            return endpoint.bundleIdentifier + data.sceneID
        }
        return title
    }

    var title: String {
        switch self {
        case .project:
            return "Project"
        case .sourceControl:
            return "Source Control"
        case .search:
            return "Search"
        case .uiExtension(_, let data):
            return data.help ?? data.sceneID
        }
    }

    var body: some View {
        switch self {
        case .project:
            ProjectNavigatorView()
        case .sourceControl:
            SourceControlNavigatorView()
        case .search:
            FindNavigatorView()
        case let .uiExtension(endpoint, data):
            ExtensionSceneView(with: endpoint, sceneID: data.sceneID)
        }
    }

    @ViewBuilder
    func bottomView(workspace: WorkspaceDocument) -> some View {
        switch self {
        case .project:
            ProjectNavigatorToolbarBottom()
        case .sourceControl:
            // 聚合视图下底部的「放弃全部改动 / 储藏」只作用于单个仓库，
            // 为避免在跨仓库列表上误操作，此时隐藏底部工具栏。
            if let store = workspace.sourceControlWorkspace,
               !store.isShowingAllRepositories,
               let sourceControlManager = workspace.sourceControlManager {
                SourceControlNavigatorToolbarBottom()
                    .environmentObject(sourceControlManager)
            }
        case .search:
            FindNavigatorToolbarBottom()
        case .uiExtension:
            EmptyView()
        }
    }
}
