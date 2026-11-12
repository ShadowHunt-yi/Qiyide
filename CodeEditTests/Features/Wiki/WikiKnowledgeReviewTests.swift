import Foundation
import Testing
@testable import CodeEdit

private final class KnowledgeFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "qiyide-knowledge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func entry(_ id: String = "rule", type: WikiEntryType = .rule, sources: [String] = []) -> WikiEntry {
        .init(id: id, title: id, type: type, tags: [], sources: sources, relations: [],
              body: "仅返回当前用户的数据", updatedAt: Date(),
              fileURL: root.appending(path: ".qiyide/wiki/\(id).md"))
    }
    func confirmed(_ entry: WikiEntry) -> WikiEntry {
        var result = entry
        result.status = .confirmed
        result.confirmation = WikiKnowledgeReview.confirmation(for: result, root: root)
        return result
    }
    func state(_ entry: WikiEntry) -> WikiKnowledgeState {
        WikiKnowledgeReview.evaluate(entries: [entry], root: root).assessment(for: entry).state
    }
}

@Suite struct WikiKnowledgeReviewTests {
    @Test func missingOrInvalidStatusDoesNotBecomeConfirmed() throws {
        let f = try KnowledgeFixture()
        for header in ["", "status: something", "generated: model", "status: CONFIRM"] {
            let text = "---\n\(header)\n---\n正文"
            #expect(WikiEntry.parse(text: text, fileURL: f.entry().fileURL).isDraft)
        }
    }

    @Test func legacyConfirmedRemainsReadableButIsNotEvidence() throws {
        let f = try KnowledgeFixture()
        let entry = WikiEntry.parse(text: "---\nstatus: confirmed\n---\n历史正文", fileURL: f.entry().fileURL)
        #expect(entry.body == "历史正文")
        #expect(f.state(entry) == .unreviewed)
    }

    @Test func confirmationRoundTrips() throws {
        let f = try KnowledgeFixture()
        try f.write("src/Rule.swift", "let scope = user")
        let entry = f.confirmed(f.entry(sources: ["src/Rule.swift"]))
        let loaded = WikiEntry.parse(text: entry.markdown(), fileURL: entry.fileURL)
        #expect(loaded.confirmation?.contentDigest == entry.confirmation?.contentDigest)
        #expect(loaded.confirmation?.sources == entry.confirmation?.sources)
        #expect(f.state(loaded) == .current)
    }

    @Test func sourceChangesRequireReview() throws {
        let f = try KnowledgeFixture()
        try f.write("src/Rule.swift", "user")
        let entry = f.confirmed(f.entry(sources: ["src/Rule.swift"]))
        #expect(f.state(entry) == .current)
        try f.write("src/Rule.swift", "everyone")
        #expect(f.state(entry) == .stale)
    }

    @Test func missingSourceIsNotTrusted() throws {
        let f = try KnowledgeFixture()
        try f.write("Rule.swift", "user")
        let entry = f.confirmed(f.entry(sources: ["Rule.swift"]))
        try FileManager.default.removeItem(at: f.root.appending(path: "Rule.swift"))
        #expect(!f.state(entry).canReference)
    }

    @Test func changedBodyOrScopeInvalidatesReceipt() throws {
        let f = try KnowledgeFixture()
        var entry = f.confirmed(f.entry())
        entry.body = "返回所有用户的数据"
        #expect(f.state(entry) == .stale)
        entry = f.confirmed(f.entry())
        entry.domains = ["different-domain"]
        #expect(f.state(entry) == .stale)
    }

    @Test func agreementIsNotImplementationProof() throws {
        let f = try KnowledgeFixture()
        #expect(f.state(f.confirmed(f.entry())) == .agreement)
        #expect(f.state(f.confirmed(f.entry(type: .module))) == .unverifiable)
    }

    @Test func directoriesAndAliasesDoNotBecomeEvidence() throws {
        let f = try KnowledgeFixture()
        try f.write("src/Main.swift", "hello")
        for path in ["src", "agent/workbench", "https://example.com/rule", "../outside", "/etc/hosts"] {
            #expect(!f.state(f.confirmed(f.entry(sources: [path]))).canReference)
        }
    }

    @Test func symlinkCannotReadOutsideRepository() throws {
        let f = try KnowledgeFixture(), outside = try KnowledgeFixture()
        try outside.write("secret.txt", "do not read")
        try FileManager.default.createSymbolicLink(
            at: f.root.appending(path: "escape.txt"), withDestinationURL: outside.root.appending(path: "secret.txt")
        )
        var reader = WikiSourceInspector(root: f.root)
        #expect(reader.inspect("escape.txt").digest == nil)
    }

    @Test func emptyFileIsValidEvidence() throws {
        let f = try KnowledgeFixture()
        try f.write("Empty.swift", "")
        #expect(f.state(f.confirmed(f.entry(sources: ["Empty.swift"]))) == .current)
    }

    @Test func malformedReceiptDoesNotBecomeTrusted() throws {
        let f = try KnowledgeFixture()
        let text = "---\nstatus: confirmed\nconfirmation: {wrong}\n---\n正文"
        #expect(f.state(WikiEntry.parse(text: text, fileURL: f.entry().fileURL)) == .unreviewed)
    }

    @Test func contextExcludesDraftsAndStaleKnowledge() throws {
        let f = try KnowledgeFixture()
        let accepted = f.confirmed(f.entry("accepted"))
        var draft = f.entry("draft")
        draft.body = "DRAFT_MUST_NOT_ENTER_CONTEXT"
        var stale = f.confirmed(f.entry("stale"))
        stale.body = "STALE_MUST_NOT_ENTER_CONTEXT"
        let entries = [accepted, draft, stale]
        let report = WikiKnowledgeReview.evaluate(entries: entries, root: f.root)
        let snapshot = WikiKnowledgeContext.build(entries: entries, report: report, root: f.root)
        #expect(snapshot.items.map(\.id) == ["accepted"])
        #expect(snapshot.excludedCount == 2)
        #expect(!snapshot.text.contains(draft.body))
        #expect(!snapshot.text.contains(stale.body))
    }

    @Test func pathMatchingRespectsDirectoryBoundaries() {
        #expect(WikiKnowledgeContext.matches(source: "src/orders", path: "src/orders/Rule.swift"))
        #expect(!WikiKnowledgeContext.matches(source: "src/order", path: "src/orders/Rule.swift"))
        #expect(!WikiKnowledgeContext.matches(source: "Rule.swift", path: "elsewhere/Rule.swift"))
    }

    @Test func contextBudgetIsExplicit() throws {
        let f = try KnowledgeFixture()
        var entry = f.entry()
        entry.body = String(repeating: "业务规则", count: 1_000)
        entry = f.confirmed(entry)
        let report = WikiKnowledgeReview.evaluate(entries: [entry], root: f.root)
        let snapshot = WikiKnowledgeContext.build(entries: [entry], report: report, root: f.root, maxCharacters: 800)
        #expect(snapshot.items.first?.truncated == true)
        #expect(snapshot.text.contains("已截断"))
        let empty = WikiKnowledgeContext.build(entries: [entry], report: report, root: f.root, maxCharacters: 0)
        #expect(empty.items.isEmpty)
        #expect(empty.omittedCount == 1)
    }

    @Test func reconfirmedSourceVersionInvalidatesContextCache() throws {
        let f = try KnowledgeFixture()
        try f.write("Rule.swift", "version one")
        let first = f.confirmed(f.entry(sources: ["Rule.swift"]))
        let before = WikiKnowledgeContext.build(entries: [first], report: WikiKnowledgeReview.evaluate(entries: [first], root: f.root), root: f.root)
        try f.write("Rule.swift", "version two")
        let second = f.confirmed(first)
        let after = WikiKnowledgeContext.build(entries: [second], report: WikiKnowledgeReview.evaluate(entries: [second], root: f.root), root: f.root)
        #expect(before.fingerprint != after.fingerprint)
    }

    @Test func repositoryIdentitySeparatesEqualKnowledge() throws {
        let one = try KnowledgeFixture(), two = try KnowledgeFixture()
        let entry = one.confirmed(one.entry())
        let report = WikiKnowledgeReview.evaluate(entries: [entry], root: one.root)
        let a = WikiKnowledgeContext.build(entries: [entry], report: report, root: one.root)
        let b = WikiKnowledgeContext.build(entries: [entry], report: report, root: two.root)
        #expect(a.fingerprint != b.fingerprint)
    }
}

@Suite(.serialized) @MainActor struct WikiKnowledgeStoreTests {
    private func readyStore(_ f: KnowledgeFixture) throws -> (WikiStore, WikiEntry) {
        let store = WikiStore(root: f.root)
        var entry = try store.create(type: .rule, title: "数据范围")
        entry.body = "仅返回当前用户的数据"
        try store.save(entry)
        try store.confirm(try #require(store.entry(id: entry.id)))
        return (store, try #require(store.entry(id: entry.id)))
    }
    private func update(_ entry: WikiEntry) -> WikiDraft {
        .init(action: .update, target: entry.title, title: entry.title, type: .rule,
              tags: [], relations: [], body: "新增组织范围，但保留原用户校验", reason: "更新规则",
              sources: [], mergeMode: .replace)
    }

    @Test func newEntryNeedsExplicitConfirmation() throws {
        let f = try KnowledgeFixture()
        let store = WikiStore(root: f.root)
        let entry = try store.create(type: .rule)
        #expect(entry.isDraft)
        #expect(entry.confirmation == nil)
    }

    @Test func humanEditInvalidatesConfirmation() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        var edited = saved
        edited.body += "，排除注销用户"
        try store.save(edited)
        let result = try #require(store.entry(id: saved.id))
        #expect(result.isDraft)
        #expect(result.confirmation == nil)
    }

    @Test func aiUpdateDoesNotOverwriteConfirmedEntry() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        let proposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        #expect(store.entry(id: saved.id)?.body == saved.body)
        #expect(store.entry(id: saved.id)?.status == .confirmed)
        #expect(proposal.proposalFor == saved.id)
        #expect(proposal.isDraft)
        #expect(proposal.id != saved.id)
        let repeatProposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        #expect(repeatProposal.id == proposal.id)
        #expect(store.entries.count == 2)
    }

    @Test func acceptingProposalPreservesArchivedOriginal() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        let proposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        let accepted = try store.acceptProposal(proposal)
        #expect(accepted.id == saved.id)
        #expect(accepted.body == proposal.body)
        #expect(accepted.confirmation != nil)
        #expect(store.entry(id: proposal.id) == nil)
        let archive = f.root.appending(path: ".qiyide/wiki/revisions")
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(files.contains { (try? String(contentsOf: $0, encoding: .utf8)) == saved.markdown() })
    }

    @Test func proposalCannotOverwriteChangedBaseline() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        let proposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        var changed = saved
        changed.body = "人工新增的另一条规则"
        try store.save(changed)
        #expect(throws: WikiKnowledgeError.self) { try store.acceptProposal(proposal) }
        #expect(store.entry(id: saved.id)?.body == changed.body)
    }

    @Test func bulkConfirmationSkipsUpdateProposals() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        let proposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        #expect(store.confirm(ids: [proposal.id]) == 0)
        #expect(store.entry(id: saved.id)?.body == saved.body)
    }

    @Test func confirmRefusesStaleEditorContent() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        var other = saved
        other.body = "外部改动"
        try other.markdown().write(to: saved.fileURL, atomically: true, encoding: .utf8)
        #expect(throws: WikiKnowledgeError.self) { try store.confirm(saved) }
    }

    @Test func regeneratedProposalDoesNotEraseHumanEdits() throws {
        let f = try KnowledgeFixture()
        let (store, saved) = try readyStore(f)
        var proposal = try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        proposal.body = "人修正了这个更新建议"
        try store.save(proposal)
        #expect(throws: WikiKnowledgeError.self) {
            try store.applyDraft(update(saved), generatedBy: "test-model", sources: [])
        }
        #expect(store.entry(id: proposal.id)?.body == proposal.body)
    }
}

@Suite struct StructureVerdictTrustTests {
    private func diff() -> StructureDiff {
        var diff = StructureDiff()
        diff.asks = [
            .init(id: "one", kind: .dependency, title: "依赖", detail: "", anchors: [["orders", "core"]]),
            .init(id: "two", kind: .interface, title: "接口", detail: "", anchors: [["pay", "api"]])
        ]
        return diff
    }

    @Test func violationsNeverBecomeReviewComplete() {
        let verdict = StructureVerdict.make(
            diff: diff(), index: .empty, path: [], decisions: ["one": .violation, "two": .violation]
        )
        #expect(verdict.openCount == 0)
        #expect(verdict.violationCount == 2)
        #expect(verdict.headline.contains("待修改"))
        #expect(!verdict.headline.contains("审完"))
    }

    @Test func acceptedStructureIsNotBusinessAcceptance() {
        let verdict = StructureVerdict.make(
            diff: diff(), index: .empty, path: [], decisions: ["one": .accepted, "two": .accepted]
        )
        #expect(verdict.headline.contains("业务与测试仍需单独验证"))
        #expect(!verdict.headline.contains("审完"))
    }

    @Test func undecidedAndViolationsRemainSeparate() {
        let verdict = StructureVerdict.make(diff: diff(), index: .empty, path: [], decisions: ["one": .violation])
        #expect(verdict.openCount == 1)
        #expect(verdict.violationCount == 1)
    }

    @Test func scopedVerdictCountsOnlyRelatedIssues() {
        let verdict = StructureVerdict.make(
            diff: diff(), index: .empty, path: ["orders"], decisions: ["two": .violation]
        )
        #expect(verdict.openCount == 1)
        #expect(verdict.violationCount == 0)
    }

    @Test func testFilesDoNotImplyExecutionResults() {
        var diff = StructureDiff()
        diff.testFiles = 13
        let verdict = StructureVerdict.make(diff: diff, index: .empty, path: [])
        #expect(verdict.facts.contains(StructureVerdict.scopeNote))
        #expect(!verdict.facts.joined().contains("测试通过"))
    }
}

@Suite(.serialized) @MainActor struct WikiContextIntegrationTests {
    @Test func narrativeUsesSameValidatedContextAsExport() throws {
        let f = try KnowledgeFixture()
        let entry = f.confirmed(f.entry())
        let report = WikiKnowledgeReview.evaluate(entries: [entry], root: f.root)
        let context = WikiKnowledgeContext.build(entries: [entry], report: report, root: f.root)
        let review = ChangeReviewAnalyzer.analyze(.init(
            hash: "abc", shortHash: "abc", subject: "更新规则", body: "", author: "tester", date: Date(),
            numstat: [], diffText: ""
        ))
        let prompt = AINarrativePrompt.user(for: review, diff: "", limit: 300, knowledge: context)
        #expect(prompt.text.contains(entry.body))
        #expect(prompt.text.contains("人工约定"))
        #expect(prompt.text.contains("不代表该历史提交的验收结果"))
    }

    @Test func curatorDoesNotUseDraftSummaryAsAuthority() throws {
        let f = try KnowledgeFixture()
        var draft = f.entry("草稿标题")
        draft.body = "DO_NOT_TREAT_DRAFT_AS_AUTHORITY"
        let prompt = WikiCurator.userPrompt(input: .init(subject: "任务", files: [], signals: [], diff: ""), existing: [draft])
        #expect(prompt.contains("草稿标题"))
        #expect(!prompt.contains(draft.body))
    }

    @Test func contextReloadRechecksSources() async throws {
        let f = try KnowledgeFixture()
        try f.write("Rule.swift", "old")
        let entry = f.confirmed(f.entry(sources: ["Rule.swift"]))
        try f.write(".qiyide/wiki/rule.md", entry.markdown())
        let before = await WikiKnowledgeContext.load(root: f.root)
        #expect(before.items.count == 1)
        try f.write("Rule.swift", "new")
        let after = await WikiKnowledgeContext.load(root: f.root)
        #expect(after.items.isEmpty)
        #expect(after.excludedCount == 1)
        #expect(before.fingerprint != after.fingerprint)
    }

    @Test func contextDoesNotReadLinkedKnowledgeOutsideRoot() async throws {
        let f = try KnowledgeFixture(), outside = try KnowledgeFixture()
        try f.write(".qiyide/wiki/local.md", "local")
        try outside.write("secret.md", "secret")
        try FileManager.default.createSymbolicLink(
            at: f.root.appending(path: ".qiyide/wiki/linked.md"),
            withDestinationURL: outside.root.appending(path: "secret.md")
        )
        let snapshot = await WikiKnowledgeContext.load(root: f.root)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.readIssues.contains("未读取 linked.md"))
        #expect(!snapshot.text.contains("\nsecret"))
    }

    @Test func manuallyEditedConfirmedKnowledgeIsProtectedOnRegeneration() throws {
        let f = try KnowledgeFixture()
        let store = WikiStore(root: f.root)
        var create = WikiDraft(action: .create, target: "", title: "模型知识", type: .rule,
                               tags: [], relations: [], body: "AI 初稿", reason: "", sources: [])
        let generated = try store.applyDraft(create, generatedBy: "model", sources: [])
        try store.confirm(generated)
        var humanEdit = try #require(store.entry(id: generated.id))
        humanEdit.body = "人工修正后的业务规则"
        try store.save(humanEdit)
        create.action = .update
        create.target = generated.title
        create.body = "AI 又生成的版本"
        create.mergeMode = .replace
        let proposal = try store.applyDraft(create, generatedBy: "model", sources: [])
        #expect(proposal.proposalFor == generated.id)
        #expect(store.entry(id: generated.id)?.body == humanEdit.body)
    }

    @Test func untouchedAIDraftCanRefreshInPlace() throws {
        let f = try KnowledgeFixture()
        let store = WikiStore(root: f.root)
        var draft = WikiDraft(action: .create, target: "", title: "草稿", type: .module,
                              tags: [], relations: [], body: "初稿", reason: "", sources: [])
        let created = try store.applyDraft(draft, generatedBy: "model", sources: [])
        draft.action = .update
        draft.target = created.title
        draft.body = "更新后的 AI 草稿"
        draft.mergeMode = .replace
        let updated = try store.applyDraft(draft, generatedBy: "model", sources: [])
        #expect(updated.id == created.id)
        #expect(updated.body == draft.body)
        #expect(store.entries.count == 1)
    }

    @Test func emptyKnowledgeCannotBeConfirmed() throws {
        let f = try KnowledgeFixture()
        let store = WikiStore(root: f.root)
        let entry = try store.create(type: .rule)
        #expect(throws: WikiKnowledgeError.self) { try store.confirm(entry) }
        #expect(store.confirm(ids: [entry.id]) == 0)
        #expect(store.actionError != nil)
        #expect(store.errorMessage == nil)
    }

    @Test func blankImportedReceiptCannotEnterContext() throws {
        let f = try KnowledgeFixture()
        var entry = f.entry()
        entry.body = "  \n  "
        #expect(!f.state(f.confirmed(entry)).canReference)
    }

    @Test func reviewedHumanContentCannotBeDiscardedAsAIDraft() throws {
        let f = try KnowledgeFixture()
        let store = WikiStore(root: f.root)
        var entry = try store.create(type: .rule, title: "规则")
        entry.body = "人工规则"
        try store.save(entry)
        try store.confirm(try #require(store.entry(id: entry.id)))
        entry = try #require(store.entry(id: entry.id))
        entry.body += "（修订）"
        try store.save(entry)
        let changed = try #require(store.entry(id: entry.id))
        #expect(throws: WikiKnowledgeError.self) { try store.discardDraft(changed) }
        #expect(store.discardDrafts(ids: [changed.id]) == 0)
        #expect(FileManager.default.fileExists(atPath: changed.fileURL.path))
    }
}
