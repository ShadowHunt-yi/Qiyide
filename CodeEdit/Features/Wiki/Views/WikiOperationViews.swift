//
//  WikiOperationViews.swift
//  CodeEdit
//
//  常驻反馈、可收起的详情与独立空态共用同一任务快照。
//

import SwiftUI

struct WikiOperationElapsed: View {
    let snapshot: WikiOperationSnapshot

    var body: some View {
        Group {
            if snapshot.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    label(at: context.date)
                }
            } else if snapshot.startedAt != nil {
                label(at: snapshot.finishedAt ?? .now)
            }
        }
    }

    private func label(at date: Date) -> some View {
        Text("已用 \(Int(snapshot.elapsed(at: date))) 秒")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

struct WikiOperationBanner: View {
    let snapshot: WikiOperationSnapshot
    let canRetrySave: Bool
    let showsResultAction: Bool
    let onDetails: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onStatic: () -> Void
    let onSettings: () -> Void
    let onResult: () -> Void
    let onDismiss: () -> Void

    private var tint: Color {
        switch snapshot.status {
        case .failed: return .red
        case .blocked: return .orange
        case .completed: return .green
        default: return .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if snapshot.isActive {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(snapshot.title)
            } else {
                Image(systemName: snapshot.status == .completed ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.title).font(.system(size: 12, weight: .medium))
                Text(snapshot.outcome ?? snapshot.progress.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if snapshot.isActive, let attempt = snapshot.progress.attempt, let attempts = snapshot.progress.attempts {
                    Text("模型请求第 \(attempt)/\(attempts) 次尝试；等待时间未知")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WikiOperationElapsed(snapshot: snapshot)
            if snapshot.isActive {
                Button(snapshot.status == .cancelling ? "取消中…" : "取消任务", action: onCancel)
                    .disabled(!snapshot.canCancel)
                    .help(snapshot.progress.stage == .save ? "正在原子保存；这个短暂阶段不可取消" : "取消请求并等待后台工作退出")
            } else if snapshot.status == .failed {
                Button(canRetrySave ? "重试保存" : "重新生成", action: onRetry)
            } else if snapshot.status == .blocked {
                Button("仅静态分析", action: onStatic)
                Button("去设置", action: onSettings)
            } else if snapshot.status == .completed && showsResultAction {
                Button("查看结果", action: onResult)
            }
            Button("详情", action: onDetails)
            if !snapshot.isActive {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭此任务提醒，保留任务记录")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint.opacity(0.07))
        .accessibilityElement(children: .contain)
    }
}

struct WikiOperationSteps: View {
    let snapshot: WikiOperationSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(WikiOperationStage.allCases) { stage in
                let recorded = snapshot.steps.first { $0.stage == stage }
                let isCurrent = snapshot.progress.stage == stage && snapshot.isActive
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: recorded?.finished == true ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(recorded?.finished == true ? Color.green : (isCurrent ? Color.accentColor : .secondary))
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stage.title).font(.system(size: 12, weight: .medium))
                        Text(isCurrent ? snapshot.progress.detail : (recorded?.detail ?? "等待前一阶段完成"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if isCurrent && snapshot.status != .cancelling {
                            if let fraction = snapshot.progress.fraction {
                                ProgressView(value: fraction).progressViewStyle(.linear)
                                    .accessibilityLabel("当前阶段的文件证据解析进度，不是整个任务进度")
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(stage == .save ? "正在验证并提交文件" : "进行中，完成时间未知")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("\(stage.title)，完成时间未知")
                            }
                        }
                        if isCurrent, let attempt = snapshot.progress.attempt, let attempts = snapshot.progress.attempts {
                            Text("第 \(attempt)/\(attempts) 次模型请求")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct WikiArchitectureTaskContent: View {
    let snapshot: WikiOperationSnapshot
    let canRetrySave: Bool
    let onStart: () -> Void
    let onStatic: () -> Void
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(snapshot.status == .idle ? "尚未生成系统架构" : snapshot.title)
                    .font(.system(size: 20, weight: .medium))
                Text(snapshot.outcome ?? (snapshot.isActive
                    ? "可以切换视角或关闭窗口；任务仍会在后台运行。可靠保存后再展示结果。"
                    : "分析代码与依赖，得到系统分层和职责。无需先创建知识条目或识别领域模型。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if snapshot.isActive {
                    HStack {
                        Text(snapshot.status == .cancelling ? "等待后台工作退出" : snapshot.progress.stage.title)
                        Spacer()
                        WikiOperationElapsed(snapshot: snapshot)
                    }
                    .font(.system(size: 12))
                    WikiOperationSteps(snapshot: snapshot)
                } else {
                    HStack(spacing: 10) {
                        if snapshot.status == .blocked {
                            Button("去配置 AI", action: onSettings)
                        } else {
                            Button(snapshot.status == .failed ? (canRetrySave ? "重试保存" : "重新生成") : "生成架构视图") {
                                if snapshot.status == .failed { onRetry() } else { onStart() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("仅静态分析", action: onStatic)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WikiArchitectureTaskDetails: View {
    @ObservedObject var runner: WikiArchitectureRunner
    let onClose: () -> Void
    let onResult: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(runner.snapshot.title).font(.system(size: 15, weight: .medium))
                Spacer()
                WikiOperationElapsed(snapshot: runner.snapshot)
            }.padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("项目：\(runner.root.path)").font(.system(size: 12)).textSelection(.enabled)
                    if let outcome = runner.snapshot.outcome {
                        Text(outcome).font(.system(size: 12)).textSelection(.enabled)
                            .foregroundStyle(runner.snapshot.status == .failed ? Color.red : .secondary)
                    }
                    WikiOperationSteps(snapshot: runner.snapshot)
                    ForEach(runner.snapshot.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    Text("产物：.qiyide/wiki/architecture.json · AI 草稿与静态分析均不代表业务已验证")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(18)
            }
            Divider()
            HStack {
                if runner.snapshot.isActive {
                    Button(runner.snapshot.status == .cancelling ? "取消中…" : "取消任务") { runner.cancel() }
                        .disabled(!runner.snapshot.canCancel)
                } else if runner.snapshot.status == .failed {
                    Button(runner.canRetrySave ? "重试保存" : "重新生成") { runner.retry() }
                } else if runner.snapshot.status == .blocked {
                    Button("去设置", action: onSettings)
                    Button("仅静态分析") { runner.start(mode: .staticOnly) }
                } else if runner.snapshot.status == .completed {
                    Button("查看结果", action: onResult)
                }
                Spacer()
                Button(runner.snapshot.isActive ? "在后台继续" : "关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }.padding(18)
        }
        .frame(width: 560, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
