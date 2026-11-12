//
//  WikiIngestSheet.swift
//  CodeEdit
//
//  整仓建档的控制台。
//
//  这一版的重点不是「点一下跑一轮」，而是「启动一个可以放着不管的长任务」：
//  面板显示轮次、调用数、缓存复用数；关掉面板任务照常跑；再打开能看到当前进度。
//  暂停与停止是两个语义——暂停保留 job 可续，停止取消在飞请求。
//

import SwiftUI

struct WikiIngestSheet: View {

    @ObservedObject var runner: WikiCurationRunner
    let store: WikiStore
    let onClose: () -> Void

    @State private var options = WikiCurationRunner.Options.standard
    @State private var showDetails = false

    private var belongsToProject: Bool {
        guard let root = runner.root else { return true }
        return root.standardizedFileURL.resolvingSymlinksInPath() == store.root.standardizedFileURL.resolvingSymlinksInPath()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if runner.isRunning && !belongsToProject {
                Label("建档任务正在处理另一个项目：\(runner.root?.lastPathComponent ?? "未知项目")", systemImage: "info.circle")
                    .font(.system(size: 12))
                Text("任务不会切换到本项目，也不会从这个窗口取消。请回到原项目查看进度。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                HStack { Spacer(); Button("关闭", action: onClose).keyboardShortcut(.cancelAction) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        statsRow
                        compatibilityNotice
                        Divider()
                        progressSection
                        if showDetails {
                            Divider()
                            stageList
                            logSection
                        }
                    }
                }
                Divider()
                footer
            }
        }
        .padding(18)
        .frame(width: 600, height: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        // 光有缓存不算建过档；范围统计也在后台执行。
        .task {
            await runner.preview(root: store.root, curatedPaths: Set(store.entries.flatMap(\.sources)), entries: store.entries)
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12))
                Text("仓库建档")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                statusBadge
            }
            Text("文件理解与模块输出分开统计。每次开始只使用本次有限额度，历史请求不会锁死续跑；已有观察、知识和人工内容保留。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch runner.job.status {
            case .running: return (runner.isPaused ? "暂停中" : "运行中", .accentColor)
            case .paused:
                return (runner.job.lastRun?.pauseReason == .requestBudget ? "本次额度已用尽" : "已暂停", .orange)
            case .finished: return ("已完成", .green)
            case .failed: return ("已中止", .red)
            case .idle: return ("未开始", .secondary)
            }
        }()
        return Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: 规模统计

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                stat("全仓文件", "\(runner.coverage.totalFiles)")
                stat("当前理解", "\(runner.coverage.understoodFiles)")
                    .help("当前内容版本和模型策略匹配的文件观察；缓存已存不等于模块已输出")
                stat("模块已输出", "\(runner.coverage.outputFiles)")
                    .help("已有完整模块草稿或更新建议，或已明确无需沉淀；不代表业务已验收")
                stat("待输出", "\(runner.coverage.pendingOutputFiles)")
                Spacer()
            }
            HStack(spacing: 18) {
                stat("已有知识条目", "\(runner.coverage.savedEntries)")
                if runner.coverage.updateProposals > 0 { stat("更新建议", "\(runner.coverage.updateProposals)") }
                if runner.coverage.legacyObservations > 0 { stat("旧观察待升级", "\(runner.coverage.legacyObservations)") }
                stat("历史轮次", "\(runner.job.round)")
                stat("历史累计请求", "\(runner.job.callsUsed)")
                    .help("保留旧版记账并累计新请求预留，不是服务商账单；历史累计不占本次额度")
                Spacer()
            }
            if let run = runner.job.lastRun {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text("\(runner.isRunning ? "本次" : "上次运行")请求：\(run.requestsUsed) / \(run.requestLimit)（含重试）")
                    Spacer()
                    if runner.isRunning { Text("剩余 \(run.remainingRequests) 次") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(runner.isRunning ? "仅本次额度参与上限判断；历史累计用于成本追踪。"
                 : "下一次可用额度：\(options.maxCallsPerRun) 次。历史累计不扣减，也不会清零。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !runner.graphSummary.isEmpty {
                Label("依赖图 " + runner.graphSummary, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Label(hintText, systemImage: "bolt.horizontal.circle")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var compatibilityNotice: some View {
        if runner.coverage.legacyObservations > 0 || runner.job.legacyProgress != nil {
            VStack(alignment: .leading, spacing: 5) {
                Label(runner.coverage.legacyObservations > 0 ? "旧版成果保留，当前口径需升级" : "旧版历史已保留", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                if let history = runner.job.legacyProgress {
                    Text("旧任务曾记录 \(history.filesDone)/\(history.filesTotal) 个已处理文件（历史口径，不是当前完成数）。")
                }
                if runner.coverage.legacyObservations > 0 {
                    Text("另有 \(runner.coverage.legacyObservations) 份旧观察缺少读取时版本，保留为历史资料；不能补盖当前摘要，也不能直接算作当前完成。")
                }
                if let notes = runner.job.legacyModuleNotes, !notes.isEmpty {
                    Text("\(notes.count) 份旧模块摘要也已保留归档；未绑定输入版本，不作为当前生成依据。")
                }
                if runner.coverage.archivedLegacyObservations > 0 {
                    Text("已保留 \(runner.coverage.archivedLegacyObservations) 份升级前的观察归档；仅作为历史资料，不参与当前缓存命中。")
                }
                Text("点击继续会按当前范围分批升级，已有知识和人工内容不清空。")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
        if runner.coverage.outdatedObservations > 0 {
            Text("\(runner.coverage.outdatedObservations) 份已存观察的来源或模型策略已变化，需要重新理解；旧资料仍保留。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(runner.isCheckingCoverage && ["全仓文件", "当前理解", "模块已输出", "待输出"].contains(label) ? "…" : value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var hintText: String {
        let mode = options.wholeRepo ? "本次预算内连续处理" : "本次只跑一轮"
        return "\(mode)；每轮调度目标 \(options.filesPerRound) 个文件，完整模块不拆分。"
    }

    // MARK: 阶段

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(WikiCurationRunner.Stage.allCases.enumerated()), id: \.element) { index, item in
                let isDone = runner.job.status == .finished
                    || (item == .scan && !runner.isCheckingCoverage && runner.coverage.totalFiles > 0)
                    || (item == .understand && runner.coverage.totalFiles > 0
                        && runner.coverage.understoodFiles == runner.coverage.totalFiles)
                let isCurrent = item == runner.stage && runner.isRunning
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.dotted" : "circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.5)))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(index + 1). \(item.title)")
                            .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                            .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                        Text(item.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            coverageProgress("文件理解", count: runner.coverage.understoodFiles,
                             value: runner.coverage.understandingProgress,
                             description: "只计当前版本有效的观察，旧记录另列")
            coverageProgress("模块输出", count: runner.coverage.outputFiles,
                             value: runner.coverage.outputProgress,
                             description: "完整草稿 / 更新建议 / 无需沉淀；仍需人工核对")
            if runner.coverage.skippedFiles > 0 {
                Text("其中 \(runner.coverage.skippedFiles) 个文件已明确无需沉淀。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if runner.isRunning && !runner.isStopping {
                HStack {
                    Text("当前阶段：\(runner.stage.title)")
                    Spacer()
                    if let progress = runner.stageProgress { Text("\(Int(progress * 100))%").monospacedDigit() }
                    else { Text("等待结果，完成时间未知") }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if let progress = runner.stageProgress { ProgressView(value: progress).progressViewStyle(.linear) }
                else { ProgressView().progressViewStyle(.linear) }
            }
            Text(runner.detail.isEmpty ? "待开始：历史累计不会占用下一次额度" : runner.detail)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = runner.finishedSummary {
                Label(summary, systemImage: "checkmark.seal").font(.system(size: 11))
                    .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            if let error = runner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11))
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func coverageProgress(_ title: String, count: Int, value: Double, description: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(runner.isCheckingCoverage ? "正在核验…" : "\(count)/\(runner.coverage.totalFiles) 个源文件")
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.system(size: 11))
            if runner.isCheckingCoverage { ProgressView().progressViewStyle(.linear) }
            else {
                ProgressView(value: value).progressViewStyle(.linear)
                    .accessibilityLabel(title + "的当前版本进度，不是业务正确性")
            }
            Text(description).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if runner.log.isEmpty {
                    Text("运行后这里会显示每一轮的进展")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 130)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: 底部控制

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("处理方式", selection: $options.wholeRepo) {
                Text("预算内连续处理").tag(true)
                Text("只跑一轮").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(runner.isRunning)

            HStack(spacing: 18) {
                Stepper(value: $options.filesPerRound, in: 40...600, step: 20) {
                    Text("每轮 \(options.filesPerRound) 个文件")
                        .font(.system(size: 11)).monospacedDigit()
                }
                .disabled(runner.isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: $options.concurrency, in: 1...6) {
                    Text("并发 \(options.concurrency)")
                        .font(.system(size: 11)).monospacedDigit()
                }
                .disabled(runner.isRunning)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 18) {
                Stepper(value: $options.maxCallsPerRun, in: 100...10_000, step: 100) {
                    Text("\(runner.isRunning ? "本次" : "下次")请求上限 \(runner.isRunning ? runner.job.lastRun?.requestLimit ?? options.maxCallsPerRun : options.maxCallsPerRun) 次")
                        .font(.system(size: 11)).monospacedDigit()
                }.disabled(runner.isRunning).frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: $options.maxMinutes, in: 5...120, step: 5) {
                    Text("\(runner.isRunning ? "本次" : "下次")时长 \(runner.isRunning ? runner.job.lastRun?.minutesLimit ?? options.maxMinutes : options.maxMinutes) 分钟")
                        .font(.system(size: 11)).monospacedDigit()
                }.disabled(runner.isRunning).frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Text("单批 \(options.maxFilesPerBatch) 个文件 / \(options.maxCharsPerBatch / 1000)K 字符。达到本次额度后暂停，不自动追加预算；再次点击继续才开启新额度。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 12) {
                Button(showDetails ? "收起阶段与日志" : "查看阶段与日志") { showDetails.toggle() }
                    .controlSize(.small)
                Spacer()

                if runner.isRunning {
                    Button(runner.isStopping ? "取消中…" : "取消任务") { runner.stop() }
                        .disabled(runner.isStopping)
                        .controlSize(.small)
                    Button(runner.isPaused ? "暂停中…" : "暂停") { runner.pause() }
                        .controlSize(.small)
                        .disabled(runner.isPaused)
                    Button("在后台继续", action: onClose).controlSize(.small)
                } else {
                    Button("关闭", action: onClose)
                        .controlSize(.small)
                    Button(runner.startButtonTitle) {
                        runner.start(root: store.root, store: store, options: options)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.isPreviewing)
                }
            }
        }
    }
}
