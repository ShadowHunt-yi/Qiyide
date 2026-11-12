//
//  WikiStore+KnowledgeReview.swift
//  CodeEdit
//

import Foundation

enum WikiKnowledgeError: LocalizedError {
    case changedOnDisk, proposalNeedsComparison, proposalConflict, requiresExplicitDeletion, emptyContent

    var errorDescription: String? {
        switch self {
        case .emptyContent: return "正文为空，请先补充业务规则或说明，再确认。"
        case .requiresExplicitDeletion: return "条目包含人工编辑或确认的内容，请使用删除条目并确认；不能当成普通 AI 草稿丢弃。"
        case .changedOnDisk: return "条目已被外部修改，请刷新并重新核对后确认。"
        case .proposalNeedsComparison: return "这是已有知识的更新建议，请先对照原文，再接受更新。"
        case .proposalConflict: return "原知识已变化或不存在，不能自动接受这份更新建议。请重新生成或手动合并。"
        }
    }
}

extension WikiStore {
    func refreshKnowledge(contentChanged: Bool = false) {
        // 手动重复点击复用同一任务；只有内容变化才替换旧输入并取消旧 worker。
        guard contentChanged || !isCheckingKnowledge else { return }
        knowledgeCheckTask?.cancel()
        knowledgeGeneration &+= 1
        let generation = knowledgeGeneration
        let snapshot = entries
        let root = root
        let checker = knowledgeChecker
        let id = UUID()
        isCheckingKnowledge = true
        knowledgeReport = .init()
        knowledgeCheck = .init(id: id, status: .checking,
                              progress: .init(totalEntries: snapshot.count), startedAt: Date(),
                              message: "正在核验 \(snapshot.count) 条知识的内容、范围与来源；不会自动确认或改写条目。")
        let publishProgress: @Sendable (WikiKnowledgeCheckProgress) -> Void = { [weak self] progress in
            guard let store = self else { return }
            Task { @MainActor [weak store] in
                guard let store, store.knowledgeGeneration == generation,
                      store.knowledgeCheck.id == id, store.isCheckingKnowledge else { return }
                store.knowledgeCheck.progress = progress
            }
        }
        knowledgeCheckTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let report = try await checker(snapshot, root, publishProgress)
                try Task.checkCancellation()
                guard report.checkedAt != nil, Set(report.assessments.keys) == Set(snapshot.map(\.id)) else {
                    throw WikiGenerationError.invalidOutput("校验报告不完整，未将部分结果标为完成")
                }
                guard let self, self.knowledgeGeneration == generation, self.knowledgeCheck.id == id else { return }
                self.knowledgeReport = report
                self.isCheckingKnowledge = false
                self.knowledgeCheck.status = .completed
                self.knowledgeCheck.progress.checkedEntries = snapshot.count
                self.knowledgeCheck.progress.checkedSources = report.sourcesChecked
                self.knowledgeCheck.progress.currentEntry = ""
                self.knowledgeCheck.progress.currentPath = ""
                self.knowledgeCheck.finishedAt = report.checkedAt ?? Date()
                self.knowledgeCheck.message = WikiKnowledgeCheckCounts.count(entries: snapshot, report: report).resultText
                self.knowledgeCheckTask = nil
            } catch is CancellationError {
                guard let self, self.knowledgeGeneration == generation else { return }
                self.isCheckingKnowledge = false
                self.knowledgeCheck.status = .cancelled
                self.knowledgeCheck.finishedAt = Date()
                self.knowledgeCheck.message = "校验已取消，未确认或修改任何知识；点击重新校验可重试。"
                self.knowledgeCheckTask = nil
            } catch {
                guard let self, self.knowledgeGeneration == generation else { return }
                self.isCheckingKnowledge = false
                self.knowledgeCheck.status = .failed
                self.knowledgeCheck.finishedAt = Date()
                self.knowledgeCheck.message = "校验失败：" + error.localizedDescription
                self.knowledgeCheckTask = nil
            }
        }
    }

    func cancelKnowledgeCheck() {
        guard isCheckingKnowledge else { return }
        knowledgeCheckTask?.cancel()
        knowledgeCheckTask = nil
        knowledgeGeneration &+= 1
        isCheckingKnowledge = false
        knowledgeCheck.status = .cancelled
        knowledgeCheck.finishedAt = Date()
        knowledgeCheck.message = "校验已取消，未确认或修改任何知识；点击重新校验可重试。"
    }

    func assessment(for entry: WikiEntry) -> WikiKnowledgeAssessment {
        isCheckingKnowledge ? .checking : knowledgeReport.assessment(for: entry)
    }

    func invalidateChangedConfirmation(_ entry: inout WikiEntry) {
        if let receipt = entry.confirmation, receipt.contentDigest != WikiKnowledgeReview.contentDigest(entry) {
            entry.status = .draft
            entry.confirmation = nil
        }
    }

    func requireConfirmableContent(_ entry: WikiEntry) throws {
        guard !entry.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WikiKnowledgeError.emptyContent
        }
    }

    /// 首次确认未编辑的生成稿不能把旧结果盖上新源码凭据。人已确认/编辑后的复核仍可重新绑定。
    func requireCurrentGeneration(_ entry: WikiEntry) throws {
        if !entry.protectsHumanContent, !entry.generatedBy.isEmpty,
           entry.generationDigest == WikiKnowledgeReview.contentDigest(entry) {
            try entry.provenance?.validate(root: root, includeContext: false)
        }
    }

    func requireUnchangedOnDisk(_ entry: WikiEntry) throws {
        let text = try String(contentsOf: entry.fileURL, encoding: .utf8)
        let saved = WikiEntry.parse(text: text, fileURL: entry.fileURL)
        guard WikiKnowledgeReview.contentDigest(saved) == WikiKnowledgeReview.contentDigest(entry),
              saved.status == entry.status, WikiKnowledgeReview.confirmationDigest(saved) == WikiKnowledgeReview.confirmationDigest(entry),
              saved.proposalFor == entry.proposalFor, saved.proposalBase == entry.proposalBase,
              saved.generationDigest == entry.generationDigest,
              saved.protectsHumanContent == entry.protectsHumanContent else {
            throw WikiKnowledgeError.changedOnDisk
        }
    }

    /// 一份候选对应一个原条目版本；重复生成更新同一候选，但不覆盖别的基线。
    func proposeUpdate(
        _ draft: WikiDraft, target: WikiEntry, generatedBy: String,
        sources: [String], domainID: String?, refresh: Bool
    ) throws -> WikiEntry {
        try ensureDirectory()
        let base = WikiKnowledgeReview.digest(Data(target.markdown().utf8))
        let proposalID = "proposal-" + String(WikiKnowledgeReview.digest(Data((target.id + base).utf8)).prefix(24))
        let url = directory.appending(path: "\(proposalID).md")
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = WikiEntry.parse(text: try String(contentsOf: url, encoding: .utf8), fileURL: url)
            guard existing.isDraft, existing.proposalFor == target.id, existing.proposalBase == base,
                  existing.generationDigest == WikiKnowledgeReview.contentDigest(existing) else {
                throw WikiKnowledgeError.proposalConflict
            }
        }
        let body = WikiEntry.canonicalBody(draft.mergeMode == .append ? target.body + "\n\n" + draft.body : draft.body)
        var proposal = WikiEntry(
            id: proposalID, title: target.title + " · 更新建议", type: target.type,
            tags: target.tags, sources: draft.mergeMode == .append
                ? Array(Set(target.sources + sources)).sorted() : Array(Set(sources)).sorted(),
            domains: target.domains.isEmpty ? domainID.map { [$0] } ?? [] : target.domains,
            relations: draft.mergeMode == .append
                ? Array(Set(target.relations + draft.relations)).sorted { ($0.kind, $0.target) < ($1.kind, $1.target) }
                : draft.relations,
            body: body, updatedAt: Date(), fileURL: url, status: .draft,
            generatedBy: generatedBy, proposalFor: target.id, proposalBase: base,
            scopePaths: draft.mergeMode == .append
                ? Array(Set(target.scopePaths + draft.scopePaths)).sorted() : draft.scopePaths,
            provenance: draft.provenance
        )
        proposal.generationDigest = WikiKnowledgeReview.contentDigest(proposal)
        try write(proposal)
        if refresh { applyChanges(updated: [proposal], removed: []) }
        return proposal
    }

    /// 用户明确接受候选；原文归档，候选不再混在当前知识中。
    @discardableResult
    func acceptProposal(_ proposal: WikiEntry) throws -> WikiEntry {
        guard let targetID = proposal.proposalFor, let base = proposal.proposalBase,
              let target = entry(id: targetID) else { throw WikiKnowledgeError.proposalConflict }
        try requireConfirmableContent(proposal)
        try requireUnchangedOnDisk(proposal)
        try proposal.provenance?.validate(root: root)
        try requireUnchangedOnDisk(target)
        guard WikiKnowledgeReview.digest(Data(target.markdown().utf8)) == base else {
            throw WikiKnowledgeError.proposalConflict
        }
        var updated = target
        updated.body = WikiEntry.canonicalBody(proposal.body)
        updated.scopePaths = proposal.scopePaths
        updated.provenance = proposal.provenance
        updated.sources = proposal.sources
        updated.relations = proposal.relations
        updated.domains = proposal.domains
        updated.generatedBy = proposal.generatedBy
        updated.status = .confirmed
        updated.protectsHumanContent = true
        updated.generationDigest = nil
        updated.updatedAt = Date()
        updated.confirmation = WikiKnowledgeReview.confirmation(for: updated, root: root)
        let archive = directory.appending(path: "revisions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let previous = archive.appending(path: "\(target.id)-\(UUID().uuidString).md")
        try target.markdown().write(to: previous, atomically: true, encoding: .utf8)
        try write(updated)
        // 写入成功后先更新原条目；候选归档失败也不丢掉已经落盘的新状态。
        applyChanges(updated: [updated], removed: [])
        try FileManager.default.moveItem(
            at: proposal.fileURL, to: archive.appending(path: "\(proposal.id)-\(UUID().uuidString).md")
        )
        applyChanges(updated: [], removed: [proposal.id])
        return updated
    }
}
