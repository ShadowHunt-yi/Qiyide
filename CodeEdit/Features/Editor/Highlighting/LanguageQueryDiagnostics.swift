//
//  LanguageQueryDiagnostics.swift
//  CodeEdit
//
//  语言高亮自检：把每个语言的 tree-sitter 查询真编译一遍，把失败原因打出来。
//
//  为什么需要它：
//  高亮查询（`*.scm`）是从各语言仓库/nvim-treesitter 搬来的，和预编译进
//  `CodeLanguages_Container` 的解析器版本并不一定同步。一旦某个节点名对不上，
//  tree-sitter 会拒绝编译整份查询，而 `TreeSitterModel.query(for:)` 把错误吞成
//  `nil` —— 表现为「这个语言没有任何高亮、也没有任何报错」。
//
//  只在 Debug 下跑一次，输出到 stderr（用终端直接启动即可看到）。
//

import Foundation
import CodeEditLanguages

enum LanguageQueryDiagnostics {

    private static var hasRun = false

    /// 启动时执行一次。结果只是一行日志，失败的语言会逐个列出原因。
    static func runOnce() {
        #if DEBUG
        guard !hasRun else { return }
        hasRun = true

        // 编译查询要跑 tree-sitter 的 C 代码，放到后台，别拖慢启动。
        DispatchQueue.global(qos: .utility).async {
            var failures: [(String, String)] = []
            for language in CodeLanguage.allLanguages where language.id != .plainText {
                if let reason = TreeSitterModel.shared.validateQuery(for: language.id) {
                    failures.append((language.id.rawValue, reason))
                }
            }

            if failures.isEmpty {
                NSLog("[Qiyide][lang] 全部 %d 个语言的查询编译通过", CodeLanguage.allLanguages.count)
                return
            }
            let detail = failures.map { "  \($0.0) → \($0.1)" }.joined(separator: "\n")
            NSLog("[Qiyide][lang] %d 个语言查询编译失败：\n%@", failures.count, detail)
        }
        #endif
    }
}
