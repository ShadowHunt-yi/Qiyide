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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statsRow
            Divider()
            stageList
            Divider()
            progressSection
            logSection
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 560, height: 580)
        .task { runner.preview(root: store.root) }
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
            Text("长任务：按规则分辨重要度 → 分批并发理解文件 → 参考已完成模块推断联系 → 落成待确认草稿。关掉这个窗口任务不会中断。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch runner.job.status {
            case .running: return (runner.isPaused ? "暂停中" : "运行中", .accentColor)
            case .paused: return ("已暂停", .orange)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                stat("全仓", "\(runner.totalCandidates)")
                stat("已建档", "\(runner.alreadyProcessed)")
                stat("待处理", "\(pending)")
                stat("已完成轮次", "\(runner.job.round)")
                stat("模型调用", "\(runner.job.callsUsed)")
            }
            if !runner.graphSummary.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                    Text("依赖图 " + runner.graphSummary)
                        .font(.system(size: 10))
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 10))
                Text(hintText)
                    .font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var pending: Int {
        max(runner.totalCandidates - runner.alreadyProcessed, 0)
    }

    private var hintText: String {
        if runner.cacheHits > 0 {
            return "本次复用 \(runner.cacheHits) 条已有文件结论，省下同量级调用"
        }
        guard pending > 0, options.wholeRepo else {
            return "已建档的文件不会重复阅读；改动过的会重新分析"
        }
        let rounds = Int(ceil(Double(pending) / Double(max(options.filesPerRound, 1))))
        return "本轮预算 \(options.filesPerRound) 个文件，约 \(rounds) 轮跑完全仓；已建档的自动跳过"
    }

    // MARK: 阶段

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(WikiCurationRunner.Stage.allCases.enumerated()), id: \.element) { index, item in
                let currentIndex = WikiCurationRunner.Stage.allCases.firstIndex(of: runner.stage) ?? 0
                let isDone = index < currentIndex
                let isCurrent = index == currentIndex && runner.isRunning
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
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: runner.progress)
                .progressViewStyle(.linear)
            HStack(spacing: 8) {
                Text(runner.detail.isEmpty ? "待开始" : runner.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int(runner.progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let summary = runner.finishedSummary {
                Label(summary, systemImage: "checkmark.seal")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = runner.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            HStack(spacing: 14) {
                Picker("", selection: $options.wholeRepo) {
                    Text("连跑至完成").tag(true)
                    Text("只跑一轮").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(runner.isRunning)

                Stepper(value: $options.filesPerRound, in: 40...600, step: 20) {
                    Text("每轮 \(options.filesPerRound) 个文件")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .disabled(runner.isRunning || !options.wholeRepo)

                Stepper(value: $options.concurrency, in: 1...6) {
                    Text("并发 \(options.concurrency)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
                .disabled(runner.isRunning)

                Spacer()
            }

            HStack(spacing: 10) {
                Text("单批 \(options.maxFilesPerBatch) 个文件 / \(options.maxCharsPerBatch / 1000)K 字符 · 调用上限 \(options.maxCallsTotal) 次 · 时长上限 \(options.maxMinutes) 分钟")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            HStack(spacing: 12) {
                Spacer()

                if runner.isRunning {
                    Button("停止") { runner.stop() }
                        .controlSize(.small)
                    Button(runner.isPaused ? "暂停中…" : "暂停") { runner.pause() }
                        .controlSize(.small)
                        .disabled(runner.isPaused)
                } else {
                    Button("关闭", action: onClose)
                        .controlSize(.small)
                    Button(runner.job.round > 0 ? "继续建档" : "开始建档") {
                        runner.start(root: store.root, store: store, options: options)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
