//
//  WikiWindowVerification.swift
//  CodeEdit
//
//  把整个知识库窗口离屏渲染成 PNG。
//
//  为什么需要：合并之后「一个页面里放三个模块」是否真的好用，只能看图判断——
//  左栏域列表会不会太长、导图在 600pt 宽里还看不看得清、右栏空态是不是占了太多地方。
//  这些都是排版问题，读代码看不出来。
//
//  用法：
//    QIYIDE_VERIFY_WIKI=/path/to/repo build/QiyideDev.app/Contents/MacOS/QiyideDev
//  产物：/tmp/wiki-window.png
//

#if DEBUG
import AppKit
import Foundation
import SwiftUI

enum WikiWindowVerification {

    static func runIfRequested() {
        guard let rootPath = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_WIKI"] else {
            return
        }
        let root = URL(fileURLWithPath: rootPath)
        let output = ProcessInfo.processInfo.environment["QIYIDE_VERIFY_WIKI_OUT"]
            ?? "/tmp/wiki-window.png"

        print("[verify][wiki] 开始渲染 \(rootPath)")
        Task { @MainActor in
            render(root: root, to: output)
        }
    }

    /// 用真实的 `NSHostingView` 渲染，而不是 `ImageRenderer`。
    ///
    /// `ImageRenderer` 画不了带原生控件的界面：`Button`、`Picker`、`HSplitView`
    /// 会被整块替换成「禁止」占位符（实测整窗变成一个巨大的红色斜杠）。
    /// 挂到真实窗口上再 `cacheDisplay` 走的是 AppKit 的绘制路径，控件正常。
    ///
    /// 窗口放在屏幕外，避免验证时在用户眼前闪一下。
    @MainActor
    private static func render(root: URL, to path: String) {
        let size = NSSize(width: 1280, height: 760)
        // 先建一个 store 只为取「第一个域」：渲染时默认选中它，
        // 这样截出来的是「域详情」而不是空态——合并后最主要的新模块就是它。
        let model = DomainModelStore(root: root)
        let firstDomain = model.graph.domains.first?.id
        let hosting = NSHostingView(rootView: WikiWindowView(
            root: root,
            workspace: nil,
            autoLoad: true,
            initiallySelectedDomain: firstDomain
        ))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        // SwiftUI 首次布局要等一轮 runloop，太快截图会得到空白。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("[verify][wiki] 无法创建位图")
                exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("[verify][wiki] PNG 编码失败")
                exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("[verify][wiki] 已渲染：\(path)")
            } catch {
                print("[verify][wiki] 写盘失败：\(error.localizedDescription)")
            }
            window.orderOut(nil)
            exit(0)
        }
    }
}
#endif
