//
//  CodeEditApp.swift
//  CodeEdit
//
//  Created by Wouter Hennen on 11/03/2023.
//

import SwiftUI
import WelcomeWindow
import AboutWindow

@main
struct CodeEditApp: App {
    @NSApplicationDelegateAdaptor var appdelegate: AppDelegate
    @ObservedObject var settings = Settings.shared

    let updater: SoftwareUpdater = SoftwareUpdater()

    init() {
        // Register singleton services before anything else
        ServiceContainer.register(
            LSPService()
        )

        _ = CodeEditDocumentController.shared
        NSMenuItem.swizzle()
        NSSplitViewItem.swizzle()

        // Debug 下把每个语言的 tree-sitter 查询编译一遍，失败原因打到 stderr。
        LanguageQueryDiagnostics.runOnce()

        #if DEBUG
        // 无界面验证领域建模链路；未设置 QIYIDE_VERIFY_DOMAIN 时直接返回。
        DomainVerification.runIfRequested()
        #endif
    }

    var body: some Scene {
        Group {
            WelcomeWindow(
                subtitleView: { WelcomeSubtitleView() },
                actions: { dismissWindow in
                    NewFileButton(dismissWindow: dismissWindow)
                    GitCloneButton(dismissWindow: dismissWindow)
                    OpenFileOrFolderButton(dismissWindow: dismissWindow)
                },
                onDrop: { url, dismissWindow in
                    Task {
                        await CodeEditDocumentController.shared.openDocument(at: url, onCompletion: { dismissWindow() })
                    }
                }
            )

            ExtensionManagerWindow()

            AboutWindow(
                subtitleView: { AboutSubtitleView() },
                actions: {
                    AboutButton(title: "Contributors", destination: {
                        ContributorsView()
                    })
                    AboutButton(title: "Acknowledgements", destination: {
                        AcknowledgementsView()
                    })
                },
                footer: { AboutFooterView() }
            )

            SettingsWindow()
                .commands {
                    CodeEditCommands()
                }
        }
        .environment(\.settings, settings.preferences) // Add settings to each window environment
    }
}
