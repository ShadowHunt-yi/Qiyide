//
//  ProjectNavigatorNSOutlineView.swift
//  CodeEdit
//
//  Created by Khan Winter on 6/10/25.
//

import AppKit

final class ProjectNavigatorNSOutlineView: NSOutlineView, NSMenuItemValidation {
    /// 任何重载都同步「无过滤结果」提示：行数变化后标签状态必须重新推导，
    /// 否则过滤结果恢复后提示会残留并压住文件行。
    override func reloadData() {
        // 整表重载意味着数据换代：先清展示缓存，再取行。
        (delegate as? ProjectNavigatorViewController)?.invalidateDisplayChildrenCache()
        let started = CFAbsoluteTimeGetCurrent()
        super.reloadData()
        PerformanceRecorder.shared.record(
            startedAt: started,
            category: .treeReload,
            meta: ["rows": "\(numberOfRows)"]
        )
        (delegate as? ProjectNavigatorViewController)?.updateNoResultsState()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.window === window && window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        if event.charactersIgnoringModifiers == "v"
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            guard let menu = menu as? ProjectNavigatorMenu else {
                return super.performKeyEquivalent(with: event)
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            for fileItem in selectedRowIndexes.compactMap({ ProjectNavigatorCompactItem.fileItem(from: item(atRow: $0)) }) {
                menu.item = fileItem
                menu.newFileFromClipboard()
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(ProjectNavigatorMenu.newFileFromClipboard) {
            return !selectedRowIndexes.isEmpty
        }
        return false
    }
}
