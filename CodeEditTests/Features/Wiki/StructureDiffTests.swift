//
//  StructureDiffTests.swift
//  CodeEditTests
//
//  分支结构增量：git 输出怎么解析、待确认怎么生成、结论怎么说。
//
//  后半部分用一个临时 git 仓库把验收标准逐条跑一遍：
//  只改方法体不该有待确认；新增跨域引用、改公开签名、新包、跨域移动各产生恰好一条；
//  模块内改名不能变成「删一个加一个」。
//

import Foundation
import Testing
@testable import CodeEdit

@Suite
struct StructureDiffParsingTests {

    @Test
    func nameStatusLines() {
        let text = [
            "M\tsrc/A.java",
            "A\tsrc/B.java",
            "D\tsrc/C.java",
            "R087\tsrc/Old.java\tsrc/New.java",
            "C75\tsrc/A.java\tsrc/Copy.java"
        ].joined(separator: "\n")
        let changes = StructureGit.parseNameStatus(text)
        #expect(changes.map(\.path) == ["src/A.java", "src/B.java", "src/C.java", "src/New.java", "src/Copy.java"])
        #expect(changes[3].status == .renamed)
        #expect(changes[3].oldPath == "src/Old.java")
        // 复制出来的新路径当新增，原文件不动。
        #expect(changes[4].status == .added)
    }

    @Test
    func unifiedDiffLineNumbers() {
        let text = """
        diff --git a/A.java b/A.java
        --- a/A.java
        +++ b/A.java
        @@ -10,2 +10,3 @@ class A {
        -    old one
        -    old two
        +    new one
        +    new two
        +    new three
        @@ -40 +41 @@
        -    before
        +    after
        """
        let lines = StructureGit.parseUnifiedDiff(text)
        #expect(lines.filter { !$0.isAddition }.map(\.number) == [10, 11, 40])
        #expect(lines.filter { $0.isAddition }.map(\.number) == [10, 11, 12, 41])
        // 文件头的 --- / +++ 不能被当成改动行。
        #expect(lines.count == 7)
    }

    @Test
    func batchOutputWithMissingObject() {
        let payload = "aaa blob 5\nhello\nHEAD:gone.java missing\nbbb blob 3\nabc\n"
        let result = StructureGit.parseBatch(Data(payload.utf8), paths: ["a.java", "gone.java", "c.java"])
        #expect(result == ["a.java": "hello", "c.java": "abc"])
    }

    @Test
    func askScopeFollowsTheBreadcrumb() {
        let ask = StructureAsk(
            id: "x",
            kind: .dependency,
            title: "",
            detail: "",
            anchors: [["order", "api", "v1"], ["pay", "core"]]
        )
        #expect(ask.isInside([]))
        #expect(ask.isInside(["order"]))
        #expect(ask.isInside(["order", "api", "v1"]))
        #expect(ask.isInside(["pay", "core"]))
        // 比锚点更深、或者别的域：不在范围内。
        #expect(!ask.isInside(["order", "api", "v1", "deep"]))
        #expect(!ask.isInside(["order", "web"]))
        #expect(!ask.isInside(["stock"]))
    }

    @Test
    func remedyTextListsOnlyViolations() {
        let asks = [
            StructureAsk(id: "a", kind: .dependency, title: "", detail: "", anchors: [], remedy: "移除引用"),
            StructureAsk(id: "b", kind: .interface, title: "", detail: "", anchors: [], remedy: "保持兼容"),
            StructureAsk(id: "c", kind: .map, title: "", detail: "", anchors: [])
        ]
        let text = StructureDecisionStore.remedyText(
            asks: asks,
            decisions: ["a": .violation, "b": .accepted, "c": .violation]
        )
        #expect(text.contains("1. 移除引用"))
        #expect(!text.contains("保持兼容"))
        #expect(StructureDecisionStore.remedyText(asks: asks, decisions: [:]).isEmpty)
    }
}

/// 在临时目录里建一个小仓库：两个业务域 `shop/order`、`shop/pay`，一个兜底域 `shop`。
@Suite(.serialized)
final class StructureDiffRepositoryTests {

    private let root: URL
    private let source = "app/src/main/java/com/x"

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "structure-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        write("shop/order/api/OrderApi.java", """
        package com.x.shop.order.api;

        public interface OrderApi {
            String create(String sku);
        }
        """)
        write("shop/order/core/OrderService.java", """
        package com.x.shop.order.core;

        import com.x.shop.order.api.OrderApi;

        public class OrderService implements OrderApi {
            public String create(String sku) {
                return sku;
            }
        }
        """)
        write("shop/pay/core/PayService.java", """
        package com.x.shop.pay.core;

        import com.x.shop.order.api.OrderApi;

        public class PayService {
            public boolean pay(OrderApi orders) {
                return orders != null;
            }
        }
        """)
        write("shop/pay/model/Receipt.java", "package com.x.shop.pay.model;\n\npublic class Receipt {\n}\n")
        write("shop/stock/StockService.java", "package com.x.shop.stock;\n\npublic class StockService {\n}\n")
        // 另一个顶层包：否则公共前缀会把 `shop` 也吃掉，业务路径就不从它开始了。
        write("util/Strings.java", "package com.x.util;\n\npublic class Strings {\n}\n")

        git("init", "-q", "-b", "main")
        commit("init")
        git("checkout", "-q", "-b", "feature")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 夹具

    private func write(_ path: String, _ text: String) {
        let url = root.appending(path: "\(source)/\(path)")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOf: root.appending(path: "\(source)/\(path)"), encoding: .utf8)) ?? ""
    }

    @discardableResult
    private func git(_ arguments: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // 身份和钩子都显式给定：测试不能依赖（也不该触发）这台机器上的全局 git 配置。
        process.arguments = [
            "-C", root.path,
            "-c", "user.name=test", "-c", "user.email=test@example.com",
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"
        ] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func commit(_ message: String) {
        git("add", "-A")
        git("commit", "-q", "-m", message)
    }

    private func graph() -> MindGraph {
        var system = MindNode(id: "system", title: "repo", kind: .system)
        var nodes: [MindNode] = []
        for (id, title, key) in [
            ("domain:shop/order", "订单", "shop/order"),
            ("domain:shop/pay", "支付", "shop/pay"),
            ("domain:leftover:shop", "商城", "shop")
        ] {
            var node = MindNode(id: id, title: title, kind: .domain)
            node.parentID = "system"
            node.packages = [key]
            system.childIDs.append(id)
            nodes.append(node)
        }
        return MindGraph(nodes: nodes + [system], rootID: "system")
    }

    private func diff(
        includeWorkingTree: Bool = true,
        scope: Set<String> = []
    ) throws -> (StructureDiff, StructureIndex) {
        let index = StructureIndex.build(packages: DomainAnalyzer.scanPackages(root: root), graph: graph())
        let options = StructureDiffBuilder.Options(target: "main", includeWorkingTree: includeWorkingTree, scope: scope)
        let result = try StructureDiffBuilder.build(root: root, index: index, options: options).get()
        return (result, index)
    }

    // MARK: 验收标准

    @Test
    func bodyOnlyChangeAsksNothing() throws {
        write("shop/order/core/OrderService.java", read("shop/order/core/OrderService.java")
            .replacingOccurrences(of: "return sku;", with: "return sku.trim();"))
        commit("body")

        let (diff, index) = try diff()
        #expect(diff.asks.isEmpty)
        #expect(diff.changes.map(\.kind) == [.modified])
        #expect(diff.innerChanges.count == 1)
        #expect(diff.edges.isEmpty)
        #expect(diff.commitCount == 1)
        let verdict = StructureVerdict.make(diff: diff, index: index, path: [])
        #expect(verdict.headline == "这个分支没有改变结构。")
        #expect(verdict.openCount == 0)
    }

    @Test
    func newCrossDomainImportIsOneAsk() throws {
        // 订单原来不依赖支付。
        write("shop/order/core/OrderService.java", read("shop/order/core/OrderService.java")
            .replacingOccurrences(
                of: "import com.x.shop.order.api.OrderApi;",
                with: "import com.x.shop.order.api.OrderApi;\nimport com.x.shop.pay.model.Receipt;"
            ))
        commit("dependency")

        let (diff, index) = try diff()
        #expect(diff.asks.map(\.id) == ["dep:add:domain:shop/order->domain:shop/pay"])
        let ask = try #require(diff.asks.first)
        #expect(ask.kind == .dependency)
        #expect(ask.evidence.first?.line == 4)
        #expect(ask.evidence.first?.sign == "+")
        #expect(diff.edges.first?.changesDomainPair == true)
        // 面包屑走进订单域能看到它，走进无关的模块看不到。
        #expect(diff.asks(inside: ["domain:shop/order"]).count == 1)
        #expect(diff.asks(inside: ["domain:shop/order", "module:shop/order/api"]).isEmpty)
        #expect(diff.changes.first?.tags == [.dependency])
        #expect(StructureVerdict.make(diff: diff, index: index, path: []).openCount == 1)
    }

    @Test
    func removedCrossDomainImportIsOneAsk() throws {
        write("shop/pay/core/PayService.java", """
        package com.x.shop.pay.core;

        public class PayService {
            public boolean pay(Object orders) {
                return orders != null;
            }
        }
        """)
        commit("decouple")

        let (diff, _) = try diff()
        let dependency = diff.asks.filter { $0.kind == .dependency }
        #expect(dependency.map(\.id) == ["dep:del:domain:shop/pay->domain:shop/order"])
        #expect(dependency.first?.evidence.first?.sign == "-")
    }

    @Test
    func publicSignatureChangeIsOneAsk() throws {
        // OrderApi 被支付域引用；改它的方法签名。
        write("shop/order/api/OrderApi.java", read("shop/order/api/OrderApi.java")
            .replacingOccurrences(of: "String create(String sku);", with: "String create(String sku, int count);"))
        commit("signature")

        let (diff, _) = try diff()
        #expect(diff.asks.map(\.id) == ["api:\(source)/shop/order/api/OrderApi.java"])
        let ask = try #require(diff.asks.first)
        #expect(ask.evidence.map(\.sign) == ["-", "+"])
        #expect(ask.detail.contains("「支付」"))
    }

    @Test
    func newPackageInCatchAllDomainIsOneAsk() throws {
        write("shop/gift/GiftService.java", """
        package com.x.shop.gift;

        import com.x.shop.order.api.OrderApi;

        public class GiftService {
        }
        """)
        commit("new package")

        let (diff, _) = try diff()
        // 新包自己带来的依赖并进「待归属」这一条里，不另问。
        #expect(diff.asks.map(\.id) == ["map:new:module:shop/gift"])
        #expect(diff.newModules == ["module:shop/gift"])
        #expect(diff.asks.first?.adoption?.domainID == "domain:shop/order")
        #expect(diff.asks.first?.adoption?.moduleKey == "shop/gift")
    }

    @Test
    func newSubpackageInsideADomainAsksNothing() throws {
        // 业务域下面新加子包：归属由路径决定，没有歧义。
        write("shop/order/audit/OrderAudit.java", "package com.x.shop.order.audit;\n\npublic class OrderAudit {\n}\n")
        commit("subpackage")

        let (diff, _) = try diff()
        #expect(diff.asks.isEmpty)
        #expect(diff.newModules == ["module:shop/order/audit"])
    }

    @Test
    func crossDomainMoveIsOneAsk() throws {
        git("mv", "\(source)/shop/pay/model/Receipt.java", "\(source)/shop/order/core/Receipt.java")
        write("shop/order/core/Receipt.java", "package com.x.shop.order.core;\n\npublic class Receipt {\n}\n")
        commit("move")

        let (diff, _) = try diff()
        #expect(diff.asks.map(\.id) == ["map:move:module:shop/pay/model->module:shop/order/core"])
        // 两边各记一笔，并且互相指着对方。
        #expect(Set(diff.changes.map(\.kind)) == [.added, .deleted])
        #expect(diff.changes.allSatisfy { $0.counterpart != nil })
        // 支付的 model 模块被搬空了：地图上要补一行「已删除」。
        #expect(diff.removedModules(domain: "domain:shop/pay").map(\.id) == ["module:shop/pay/model"])
    }

    @Test
    func moveThatGitMissesIsPairedByFileName() throws {
        // 不用 git mv，而且内容几乎全换了：git 的相似度判断认不出这是同一个文件。
        git("rm", "-q", "\(source)/shop/pay/model/Receipt.java")
        write("shop/order/core/Receipt.java", """
        package com.x.shop.order.core;

        /** 挪过来之后重写了。 */
        public final class Receipt {
            private final String id;

            public Receipt(String id) {
                this.id = id;
            }
        }
        """)
        commit("rewrite while moving")

        let (diff, _) = try diff()
        #expect(diff.asks.map(\.id) == ["map:move:module:shop/pay/model->module:shop/order/core"])
    }

    @Test
    func renameInsideAModuleIsAModification() throws {
        git("mv", "\(source)/shop/order/core/OrderService.java", "\(source)/shop/order/core/OrderHandler.java")
        write("shop/order/core/OrderHandler.java", read("shop/order/core/OrderHandler.java")
            .replacingOccurrences(of: "class OrderService", with: "class OrderHandler"))
        commit("rename")

        let (diff, _) = try diff()
        // 不是「删一个加一个」。
        #expect(diff.changes.map(\.kind) == [.modified])
        #expect(diff.changes.first?.counterpart?.hasSuffix("OrderService.java") == true)
        #expect(diff.asks.isEmpty)
    }

    @Test
    func deletedButStillImportedIsFlagged() throws {
        git("rm", "-q", "\(source)/shop/order/api/OrderApi.java")
        commit("delete")

        let (diff, _) = try diff()
        let ask = try #require(diff.asks.first { $0.id.hasPrefix("api:gone:") })
        // 订单自己的 OrderService 和支付的 PayService 都还在 import 它。
        #expect(ask.evidence.count == 2)
    }

    @Test
    func workingTreeIsOptional() throws {
        write(
            "shop/stock/StockService.java",
            "package com.x.shop.stock;\n\npublic class StockService {\n    // wip\n}\n"
        )
        write("shop/stock/Fresh.java", "package com.x.shop.stock;\n\npublic class Fresh {\n}\n")

        let (withTree, _) = try diff(includeWorkingTree: true)
        #expect(Set(withTree.changes.map(\.fileName)) == ["StockService.java", "Fresh.java"])
        #expect(withTree.changes.allSatisfy { $0.isUncommitted })

        let (committedOnly, _) = try diff(includeWorkingTree: false)
        #expect(committedOnly.changes.isEmpty)
    }

    @Test
    func declaredScopeFlagsOutsideChanges() throws {
        write(
            "shop/pay/model/Receipt.java",
            "package com.x.shop.pay.model;\n\npublic class Receipt {\n    // touched\n}\n"
        )
        write("shop/order/core/OrderService.java", read("shop/order/core/OrderService.java")
            .replacingOccurrences(of: "return sku;", with: "return sku.trim();"))
        commit("two domains")

        let (diff, _) = try diff(scope: ["domain:shop/order"])
        #expect(diff.asks.map(\.id) == ["scope"])
        #expect(diff.asks.first?.title == "越出声明范围：支付")
        // 没声明范围就不查。
        #expect(try self.diff().0.asks.isEmpty)
    }

    @Test
    func noCommonTargetFailsGracefully() throws {
        let index = StructureIndex.build(packages: DomainAnalyzer.scanPackages(root: root), graph: graph())
        let result = StructureDiffBuilder.build(
            root: root,
            index: index,
            options: StructureDiffBuilder.Options(target: "no-such-branch")
        )
        #expect(throws: StructureDiffBuilder.Failure.self) { try result.get() }
    }
}
