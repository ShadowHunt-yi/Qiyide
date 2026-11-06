//
//  StructureFactsTests.swift
//  CodeEditTests
//
//  依赖事实与接口识别：import 怎么读、全限定名怎么对到文件、哪一行算「公开声明」。
//
//  这几块都偏保守——认错一条依赖或一处接口变化，待确认清单就不可信了。
//  所以测试里「不该认出来」的反例和正例一样多。
//

import Foundation
import Testing
@testable import CodeEdit

@Suite
struct StructureFactsTests {

    private let root = "app/src/main/java/"

    // MARK: import

    @Test
    func importsStopAtTheTypeDeclaration() {
        let source = """
        package com.x.order;

        import com.x.pay.PayService;
        import static com.x.util.Strings.join;
        import com.x.model.*;

        /** 文档里的 import com.x.fake.Nope; 不算 */
        public class OrderService {
            String text = "import com.x.fake.AlsoNope;";
        }
        """
        let lines = JavaSourceScanner.imports(in: source)
        #expect(lines.map(\.name) == ["com.x.pay.PayService", "com.x.util.Strings.join", "com.x.model"])
        #expect(lines.map(\.line) == [3, 4, 5])
        #expect(lines.map(\.isWildcard) == [false, false, true])
    }

    // MARK: 全限定名

    @Test
    func resolverMapsNamesToFiles() {
        let resolver = JavaTypeResolver(paths: [
            root + "com/x/pay/PayService.java",
            root + "com/x/util/Strings.java",
            root + "com/x/model/Order.java"
        ])
        #expect(JavaTypeResolver.typeName(forPath: root + "com/x/pay/PayService.java") == "com.x.pay.PayService")
        #expect(resolver.resolve("com.x.pay.PayService") == root + "com/x/pay/PayService.java")
        // 内部类、静态成员都落到外层类的文件上。
        #expect(resolver.resolve("com.x.pay.PayService.Result") == root + "com/x/pay/PayService.java")
        #expect(resolver.resolve("com.x.util.Strings.join") == root + "com/x/util/Strings.java")
        #expect(resolver.resolve("org.other.Thing") == nil)
        #expect(resolver.commonPrefix == "com.x")
        #expect(resolver.isInternal("com.x.gone.Missing"))
        #expect(!resolver.isInternal("org.other.Thing"))
    }

    @Test
    func wildcardResolvesPackageOrStaticMembers() {
        let resolver = JavaTypeResolver(paths: [root + "com/x/model/Order.java", root + "com/x/util/Strings.java"])
        let package = JavaSourceScanner.ImportLine(name: "com.x.model", line: 1, text: "", isWildcard: true)
        #expect(resolver.resolve(package) == root + "com/x/model/Order.java")
        // `import static com.x.util.Strings.*`：名字是类，不是包。
        let members = JavaSourceScanner.ImportLine(name: "com.x.util.Strings", line: 1, text: "", isWildcard: true)
        #expect(resolver.resolve(members) == root + "com/x/util/Strings.java")
    }

    @Test
    func referencesAreDeduplicatedAndDanglingIsReported() {
        let resolver = JavaTypeResolver(paths: [
            root + "com/x/order/OrderService.java",
            root + "com/x/pay/PayService.java"
        ])
        let source = """
        package com.x.order;
        import com.x.pay.PayService;
        import static com.x.pay.PayService.charge;
        import com.x.gone.Missing;
        import java.util.List;
        public class OrderService {}
        """
        let found = StructureFacts.references(
            in: source,
            from: root + "com/x/order/OrderService.java",
            resolver: resolver
        )
        // 普通导入和静态导入指向同一个文件，只记一次。
        #expect(found.resolved.map(\.to) == [root + "com/x/pay/PayService.java"])
        #expect(found.resolved.first?.line == 2)
        // 指向仓库自己的包却对不到文件的才算未解析；JDK 的不算。
        #expect(found.dangling.map(\.name) == ["com.x.gone.Missing"])
    }

    @Test
    func factsIndexBothDirections() {
        let facts = StructureFacts(references: [
            StructureReference(from: "b", to: "c", line: 2, text: ""),
            StructureReference(from: "a", to: "c", line: 1, text: "")
        ])
        #expect(facts.incoming(to: "c").map(\.from) == ["a", "b"])
        #expect(facts.outgoing(from: "a").map(\.to) == ["c"])
        #expect(facts.outgoing(from: "c").isEmpty)
    }

    // MARK: 公开声明

    @Test(arguments: [
        ("    public Result pay(Order order, int retries) {", "pay"),
        ("    protected <T> T convert(Class<T> type);", "convert"),
        ("    public OrderService(PayService pay) {", "OrderService"),
        ("public interface PayApi extends Base {", "PayApi"),
        ("    public static Map<String, List<Item>> group(List<Item> items) {", "group")
    ])
    func publicDeclarationsAreRecognized(line: String, name: String) {
        #expect(JavaSignature.parse(line, inInterface: false)?.name == name)
    }

    @Test(arguments: [
        "        return pay(order);",
        "        service.pay(order);",
        "        Result result = pay(order);",
        "        this(tenantId, null, null);",
        "    private Result pay(Order order) {",
        "    Result pay(Order order) {",
        "        if (ready(order)) {",
        "    // public Result pay(Order order)",
        "    @Transactional(readOnly = true)",
        "        new Thread(runner).start();"
    ])
    func statementsAndPrivateMembersAreNotDeclarations(line: String) {
        #expect(JavaSignature.parse(line, inInterface: false) == nil)
    }

    @Test
    func interfaceMethodsNeedNoModifier() {
        #expect(JavaSignature.parse("    Result pay(Order order);", inInterface: true)?.name == "pay")
        // 接口里的语句照样不算。
        #expect(JavaSignature.parse("        return fallback(order);", inInterface: true) == nil)
        #expect(JavaSignature.isInterface("package a;\n/** interface 说明 */\npublic interface PayApi {\n}"))
        #expect(!JavaSignature.isInterface("package a;\npublic class PayService {\n}"))
    }

    @Test
    func onlyChangedOrRemovedSignaturesCount() {
        func line(_ addition: Bool, _ number: Int, _ text: String) -> StructureGit.DiffLine {
            StructureGit.DiffLine(isAddition: addition, number: number, text: text)
        }
        // 签名变了：删一行、加一行，同名不同文。
        let changed = JavaSignature.changes(in: [
            line(false, 10, "    public Result pay(Order order) {"),
            line(true, 10, "    public Result pay(Order order, boolean dryRun) {")
        ], inInterface: false)
        #expect(changed.map(\.sign) == ["-", "+"])

        // 只是挪了位置：文本相同，不算。
        let moved = JavaSignature.changes(in: [
            line(false, 10, "    public Result pay(Order order) {"),
            line(true, 40, "    public Result pay(Order order) {")
        ], inInterface: false)
        #expect(moved.isEmpty)

        // 纯新增方法、只改方法体：都不算接口变化。
        let added = JavaSignature.changes(in: [
            line(true, 50, "    public void refund(Order order) {"),
            line(false, 12, "        return gateway.charge(order);"),
            line(true, 12, "        return gateway.charge(order, 3);")
        ], inInterface: false)
        #expect(added.isEmpty)

        // 方法被删掉。
        let removed = JavaSignature.changes(
            in: [line(false, 10, "    public Result pay(Order order) {")],
            inInterface: false
        )
        #expect(removed.map(\.sign) == ["-"])
    }
}
