//
//  DomainAnalyzer+Modules.swift
//  CodeEdit
//
//  域下面的模块：把叶子包汇总成「域的第一级子包」。
//
//  为什么重写这一段：旧实现有三个缺口，合起来的效果是「域下面是空的」——
//  1. 只有评分达标的域才挂模块。按一级包聚合出来的兜底域（基准仓库里的「搭子」，
//     七百多个类、三十多个包）一个模块节点都没有；
//  2. 同一个三级包只取遇到的第一个叶子，其余更深的子包被跳过，
//     `suggest/contract` 这种下面有十个子包的模块，类数只算到其中一个；
//  3. 直接放在域根目录下的类（`service/portrait/*.java` 有五十多个）不属于任何模块。
//
//  这里的规则只有一条：模块 = 域的包路径下的第一级子包，连同它下面所有更深的子包。
//  域根目录直属的类归入「域根」模块。这样每个类都恰好落在一个模块里，
//  模块的类数加起来等于域的类数——结构地图靠这条守恒才敢说自己是准的。
//

import Foundation

/// 一次目录扫描得到的包。只有路径，不读文件内容。
struct ScannedPackage: Sendable, Hashable {
    /// 去掉公共包前缀后的业务路径段，如 `["agent", "customerservice", "biz"]`。
    var parts: [String]
    /// 「源码根 + 公共前缀」的仓库相对路径。
    var sourceRoot: String
    /// 仓库相对路径的文件列表。
    var files: [String]
}

extension DomainAnalyzer {

    /// 域根模块的标识后缀。`module:service/portrait/_root`。
    ///
    /// 用下划线开头是因为 Java 包名不允许这样起，不会和真实子包撞名。
    static let rootModuleSuffix = "/_root"
    static let rootModuleTitle = "（域根）"

    static func isRootModule(_ id: String) -> Bool {
        id.hasSuffix(rootModuleSuffix)
    }

    /// 一个域下面的全部模块节点，按类数降序。
    ///
    /// - Parameters:
    ///   - domainParts: 域的包路径段。达标域是两段（`agent/customerservice`），兜底域是一段（`agent`）。
    ///   - leaves: 归这个域的叶子包。调用方负责先把别的域认领走的叶子排除掉。
    static func moduleNodes(domainID: String, domainParts: [String], leaves: [Leaf]) -> [MindNode] {
        struct Bucket {
            var classes = 0
            var files = 0
        }
        let depth = domainParts.count
        var buckets: [String: Bucket] = [:]
        var rootBucket = Bucket()

        for leaf in leaves {
            guard leaf.parts.count >= depth, Array(leaf.parts.prefix(depth)) == domainParts else { continue }
            if leaf.parts.count == depth {
                rootBucket.classes += leaf.classes.count
                rootBucket.files += leaf.files.count
            } else {
                var bucket = buckets[leaf.parts[depth]] ?? Bucket()
                bucket.classes += leaf.classes.count
                bucket.files += leaf.files.count
                buckets[leaf.parts[depth]] = bucket
            }
        }

        let domainKey = domainParts.joined(separator: "/")
        var result: [MindNode] = buckets.map { segment, bucket in
            let key = domainKey + "/" + segment
            var node = MindNode(id: "module:" + key, title: segment, kind: .module)
            node.parentID = domainID
            node.packages = [key]
            node.classCount = bucket.classes
            node.fileCount = bucket.files
            return node
        }
        if rootBucket.classes > 0 {
            var node = MindNode(
                id: "module:" + domainKey + rootModuleSuffix,
                title: rootModuleTitle,
                kind: .module
            )
            node.parentID = domainID
            node.packages = [domainKey]
            node.classCount = rootBucket.classes
            node.fileCount = rootBucket.files
            result.append(node)
        }
        // 类数相同按名字排，保证同一份代码两次识别出来的顺序一样。
        return result.sorted {
            $0.classCount != $1.classCount ? $0.classCount > $1.classCount : $0.title < $1.title
        }
    }

    /// 只扫目录的包清单。结构地图用它把每个文件落到模块上。
    ///
    /// 比 `analyze` 轻得多：不读文件内容、不跑 git，四千个文件也只要几十毫秒，
    /// 所以结构地图每次打开都可以重扫一遍，不必担心模型过期后文件对不上。
    static func scanPackages(root: URL) -> [ScannedPackage] {
        let modules = scanModules(javaRoots: findJavaRoots(root))
        return makeLeaves(modules: modules, root: root)
            .map { ScannedPackage(parts: $0.parts, sourceRoot: $0.sourceRoot, files: $0.repoPaths.sorted()) }
            .sorted { lhs, rhs in
                // 目录遍历的顺序不保证稳定，这里排一次，后面的结果才能逐项比对。
                if lhs.sourceRoot != rhs.sourceRoot { return lhs.sourceRoot < rhs.sourceRoot }
                return lhs.parts.lexicographicallyPrecedes(rhs.parts)
            }
    }
}
