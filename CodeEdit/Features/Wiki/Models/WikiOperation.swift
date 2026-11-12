//
//  WikiOperation.swift
//  CodeEdit
//
//  资源是否为空与任务是否运行是不同问题。窗口只展示快照，不持有任务。
//

import Foundation

/// 任务条与详情共用的执行状态。取消请求发出后，底层退出前仍是运行中的任务。
enum WikiOperationStatus: String, Sendable {
    case idle, running, cancelling, completed, cancelled, failed, blocked

    var isActive: Bool { self == .running || self == .cancelling }
}

enum WikiOperationStage: Int, CaseIterable, Sendable, Identifiable {
    case prepare, scan, dependencies, plan, validate, save

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .prepare: return "检查项目"
        case .scan: return "扫描代码"
        case .dependencies: return "分析依赖"
        case .plan: return "划分系统"
        case .validate: return "核对来源"
        case .save: return "保存结果"
        }
    }
}

/// 只报告有来源的计数。未知总量、模型等待和保存阶段没有百分比。
struct WikiOperationProgress: Sendable, Equatable {
    var stage: WikiOperationStage
    var detail: String
    var completed: Int?
    var total: Int?
    var attempt: Int?
    var attempts: Int?

    init(
        _ stage: WikiOperationStage,
        _ detail: String,
        completed: Int? = nil,
        total: Int? = nil,
        attempt: Int? = nil,
        attempts: Int? = nil
    ) {
        self.stage = stage
        self.detail = detail
        self.completed = completed
        self.total = total
        self.attempt = attempt
        self.attempts = attempts
    }

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

struct WikiOperationStep: Sendable, Equatable, Identifiable {
    var stage: WikiOperationStage
    var detail: String
    var finished: Bool = false
    var id: Int { stage.rawValue }
}

struct WikiOperationSnapshot: Sendable, Equatable {
    var id: UUID?
    var status: WikiOperationStatus = .idle
    var progress = WikiOperationProgress(.prepare, "待开始")
    var startedAt: Date?
    var finishedAt: Date?
    var steps: [WikiOperationStep] = []
    var warnings: [String] = []
    var outcome: String?
    var mode: WikiArchitectureMode = .automatic

    var isActive: Bool { status.isActive }
    var canCancel: Bool { status == .running && progress.stage != .save }
    var title: String {
        switch status {
        case .idle: return "生成系统架构"
        case .running: return "正在生成系统架构"
        case .cancelling: return "正在取消架构任务"
        case .completed: return "系统架构已生成"
        case .cancelled: return "架构任务已取消"
        case .failed: return "架构任务未完成"
        case .blocked: return "AI 增强暂不可用"
        }
    }

    func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }

    /// 迟到的扫描计数不能把后续阶段改回扫描；重试创建新的任务 ID。
    mutating func receive(_ update: WikiOperationProgress) {
        guard status == .running, update.stage.rawValue >= progress.stage.rawValue else { return }
        if let index = steps.firstIndex(where: { $0.stage == update.stage }) {
            steps[index].detail = update.detail
        } else {
            if !steps.isEmpty { steps[steps.count - 1].finished = true }
            steps.append(WikiOperationStep(stage: update.stage, detail: update.detail))
        }
        progress = update
    }
}

enum WikiArchitectureMode: String, Sendable {
    /// 配置有效时允许 AI；简单项目仍直接使用静态分析。
    case automatic
    case staticOnly
}
