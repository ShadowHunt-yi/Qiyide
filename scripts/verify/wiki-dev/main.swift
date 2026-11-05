//
//  main.swift
//  scripts/verify/wiki-dev
//
//  知识库功能的独立可执行入口。
//
//  为什么需要：完整的 QiyideDev 要用 xcodebuild 打包，没有装 Xcode 的机器上打不出来。
//  而知识库（领域建模、结构地图、建档）只依赖系统框架，可以单独编成一个小程序，
//  跑的是与 App 完全相同的源码——验证入口、离屏渲染、真实窗口都能用。
//
//  行为与 `CodeEditApp.init` 里的顺序保持一致：设置了哪个 QIYIDE_VERIFY_* 就跑哪个入口；
//  设置 WIKI_DEV_OPEN=<仓库路径> 则直接打开知识库窗口，用于人工点验。
//

import AppKit

final class WikiDevDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = WikiDevDelegate()
application.delegate = delegate

let environment = ProcessInfo.processInfo.environment
let verifyKeys = environment.keys.filter { $0.hasPrefix("QIYIDE_VERIFY_") }

if let path = environment["WIKI_DEV_OPEN"] {
    application.setActivationPolicy(.regular)
    DispatchQueue.main.async {
        WikiWindowPresenter.show(workspace: WorkspaceDocument(fileURL: URL(fileURLWithPath: path)))
        NSApp.activate(ignoringOtherApps: true)
    }
} else if verifyKeys.isEmpty {
    print("用法：scripts/verify/wiki-dev/run.sh <domain|wiki|structure|open> <仓库路径> [输出路径]")
    exit(2)
} else {
    // 验证入口都是离屏的，不需要 Dock 图标。
    application.setActivationPolicy(.accessory)
    DomainVerification.runIfRequested()
    WikiWindowVerification.runIfRequested()
    WikiCurationVerification.runIfRequested()
    StructureVerification.runIfRequested()
}

application.run()
