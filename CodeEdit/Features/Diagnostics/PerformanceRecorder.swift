//
//  PerformanceRecorder.swift
//  CodeEdit
//
//  轻量性能采样器：后台采集、超时自动聚合、容量有硬上限。
//
//  设计约束：
//  1) 记录调用必须极轻——只把样本塞进内存队列，落盘与聚合都在串行后台队列；
//  2) 原始样本超过 1 小时即折算为「小时聚合」，原始数组不会无限增长；
//  3) 原始样本数、聚合桶数、保留天数三重上限，单个 JSON 常态 < 300 KB；
//  4) 只记录类别、耗时、计数等度量数据，不记录文件内容或绝对路径。
//

import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

final class PerformanceRecorder {
    static let shared = PerformanceRecorder()

    // MARK: - 类别

    enum Category: String, CaseIterable {
        /// 应用冷启动到首窗可交互。
        case appLaunch = "app.launch"
        /// 主线程停顿（看门狗检测）。
        case mainThreadStall = "ui.stall"
        /// 改动列表刷新（git status）。
        case gitStatus = "git.status"
        /// 行级 blame 拉取。
        case gitBlame = "git.blame"
        /// 差异计算。
        case gitDiff = "git.diff"
        /// 文件树整表重载。
        case treeReload = "tree.reload"
        /// 一键展开 / 收起。
        case treeExpand = "tree.expand"
        /// Markdown 预览渲染。
        case markdownRender = "markdown.render"
        /// LSP 请求往返。
        case lspRequest = "lsp.request"
    }

    // MARK: - 数据结构

    struct Sample: Codable {
        let time: Double          // Unix 时间戳（秒）
        let category: String
        let durationMS: Double
        let meta: [String: String]?
    }

    /// 一小时 × 一个类别的聚合结果。
    struct Rollup: Codable {
        let hourStart: Double
        let category: String
        var count: Int = 0
        var totalMS: Double = 0
        var maxMS: Double = 0
        /// 直方图：固定 11 个分桶，用于估算 p95，避免保存全部原始值。
        var buckets: [Int] = Array(repeating: 0, count: PerformanceRecorder.bucketEdgesMS.count + 1)

        var averageMS: Double { count > 0 ? totalMS / Double(count) : 0 }

        /// 由直方图估算分位值（返回桶上界，属于保守估计）。
        func percentile(_ p: Double) -> Double {
            guard count > 0 else { return 0 }
            let target = Double(count) * p
            var seen = 0
            for (index, value) in buckets.enumerated() {
                seen += value
                if Double(seen) >= target {
                    let edges = PerformanceRecorder.bucketEdgesMS
                    return index < edges.count ? edges[index] : maxMS
                }
            }
            return maxMS
        }
    }

    private struct Store: Codable {
        var samples: [Sample] = []
        var rollups: [Rollup] = []
    }

    // MARK: - 容量与保留策略（集中在这里，便于调参）

    /// 原始样本保留时长：超过即折算进小时聚合。
    static let rawRetention: TimeInterval = 60 * 60
    /// 原始样本硬上限（约 4000 × 120B ≈ 480 KB，超出部分立即聚合）。
    static let maxRawSamples = 4_000
    /// 聚合数据保留天数。
    static let rollupRetention: TimeInterval = 30 * 24 * 60 * 60
    /// 聚合桶硬上限（30 天 × 24 小时）；超出按时间淘汰最旧。
    static let maxRollups = 30 * 24
    /// 单个样本携带的元数据键上限。
    static let maxMetaKeys = 4
    /// 分桶边界（毫秒）。
    static let bucketEdgesMS: [Double] = [10, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000, 30_000]
    /// 落盘节流（秒）。频繁写入对 SSD 无意义，异常退出最多丢 30 秒样本。
    private static let flushInterval: TimeInterval = 30
    /// 文件体积硬上限：超过即丢弃最旧的聚合桶与一半原始样本，保证永不无界膨胀。
    private static let maxFileBytes = 2 * 1024 * 1024
    /// 看门狗判定为主线程卡顿的阈值（毫秒）。
    private static let stallThresholdMS: Double = 250
    /// 两次卡顿记录的最小间隔，避免长时间冻结时刷爆样本。
    private static let stallCooldown: TimeInterval = 10

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.qiyide",
        category: "Performance"
    )

    // MARK: - 状态（全部在 queue 上访问）

    private let queue = DispatchQueue(label: "app.qiyide.performance", qos: .utility)
    private var store = Store()
    private var isDirty = false
    private var didLoad = false
    private var lastStallTime: TimeInterval = 0
    private var flushTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?

    /// 记录开关（UserDefaults 持久化）。
    private(set) var isRecordingEnabled: Bool

    private static let enabledKey = "performanceRecorder.enabled"

    private init() {
        isRecordingEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        startFlushTimer()
        queue.async { [weak self] in
            self?.loadLocked()
        }
    }

    // MARK: - 对外 API

    /// 记录一次耗时样本。立即返回，落盘异步进行。
    func record(_ category: Category, durationMS: Double, meta: [String: String] = [:]) {
        guard isRecordingEnabled, durationMS.isFinite, durationMS >= 0 else { return }
        var trimmedMeta = meta
        if trimmedMeta.count > Self.maxMetaKeys {
            // 元数据只保留前几项：防止调用方塞入大对象把文件撑大。
            let limited = meta.prefix(Self.maxMetaKeys).map { ($0.key, $0.value) }
            trimmedMeta = Dictionary(uniqueKeysWithValues: limited)
        }
        let sample = Sample(
            time: Date().timeIntervalSince1970,
            category: category.rawValue,
            durationMS: durationMS,
            meta: trimmedMeta.isEmpty ? nil : trimmedMeta
        )
        queue.async { [weak self] in
            guard let self else { return }
            self.loadLockedIfNeeded()
            self.store.samples.append(sample)
            self.isDirty = true
            if self.store.samples.count > Self.maxRawSamples {
                self.compactLocked(force: true)
            }
        }
    }

    /// 测量一个同步代码块。
    @discardableResult
    func measure<T>(_ category: Category, meta: [String: String] = [:], _ body: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            record(category, durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1_000, meta: meta)
        }
        return try body()
    }

    /// 记录一个「开始时间」，配合 ``record(startedAt:category:meta:)`` 用于 async 场景。
    func begin() -> CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    func record(startedAt start: CFAbsoluteTime, category: Category, meta: [String: String] = [:]) {
        record(category, durationMS: (CFAbsoluteTimeGetCurrent() - start) * 1_000, meta: meta)
    }

    // MARK: - 开关与运维

    func setRecordingEnabled(_ enabled: Bool) {
        isRecordingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startWatchdogIfNeeded()
        } else {
            queue.async { [weak self] in
                self?.watchdog?.cancel()
                self?.watchdog = nil
            }
        }
    }

    /// 主线程看门狗：后台每秒探一次主队列，超过阈值即记一笔卡顿。
    /// 这是排查「界面卡死」最直接的数据，且开销固定在每秒一次空转。
    func startWatchdogIfNeeded() {
        guard isRecordingEnabled else { return }
        queue.async { [weak self] in
            guard let self, self.watchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "app.qiyide.performance.watchdog", qos: .utility)
            )
            timer.schedule(deadline: .now() + 2, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let start = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let latency = (CFAbsoluteTimeGetCurrent() - start) * 1_000
                    guard latency > Self.stallThresholdMS else { return }
                    let now = Date().timeIntervalSince1970
                    guard now - self.lastStallTime > Self.stallCooldown else { return }
                    self.lastStallTime = now
                    self.record(.mainThreadStall, durationMS: latency)
                    Self.logger.warning("主线程停顿 \(Int(latency))ms")
                }
            }
            timer.resume()
            self.watchdog = timer
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.store = Store()
            self.isDirty = true
            self.persistLocked()
        }
    }

    /// 同步落盘（退出前调用）。
    func flush() {
        queue.sync { [weak self] in
            self?.loadLockedIfNeeded()
            self?.compactLocked(force: false)
            self?.persistLocked()
        }
    }

    /// 导出快照 JSON（供「导出性能记录」使用）。
    func exportJSON() -> Data {
        queue.sync { [weak self] in
            guard let self else { return Data() }
            self.loadLockedIfNeeded()
            self.compactLocked(force: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(self.store) {
                return data
            }
            return Data()
        }
    }

    /// 存储位置（便于用户排查）。
    var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Qiyide", isDirectory: true)
            .appendingPathComponent("Performance", isDirectory: true)
            .appendingPathComponent("metrics.json")
    }

    // MARK: - 聚合

    /// 把过期/超量的原始样本折算进小时聚合。
    /// - Parameter force: 由数量上限触发时也做一次时间聚合。
    private func compactLocked(force: Bool) {
        let now = Date().timeIntervalSince1970
        let cutoff = now - Self.rawRetention

        // 1) 超过保留时长的样本 → 聚合
        var remaining: [Sample] = []
        remaining.reserveCapacity(store.samples.count)
        var toAggregate: [Sample] = []
        for sample in store.samples {
            if sample.time < cutoff {
                toAggregate.append(sample)
            } else {
                remaining.append(sample)
            }
        }

        // 2) 数量超限 → 从最旧的开始聚合，保持原始数组有界
        if remaining.count > Self.maxRawSamples {
            let overflow = remaining.count - Self.maxRawSamples
            toAggregate.append(contentsOf: remaining.prefix(overflow))
            remaining.removeFirst(overflow)
        }

        if !toAggregate.isEmpty {
            mergeIntoRollupsLocked(toAggregate)
            store.samples = remaining
            isDirty = true
        } else if force {
            store.samples = remaining
        }

        // 3) 聚合数据的时间与数量上限
        let rollupCutoff = now - Self.rollupRetention
        let before = store.rollups.count
        store.rollups.removeAll { $0.hourStart < rollupCutoff }
        if store.rollups.count > Self.maxRollups {
            store.rollups.sort { $0.hourStart < $1.hourStart }
            store.rollups.removeFirst(store.rollups.count - Self.maxRollups)
        }
        if store.rollups.count != before {
            isDirty = true
        }
    }

    private func mergeIntoRollupsLocked(_ samples: [Sample]) {
        // 先按 (小时, 类别) 建索引，避免逐条线性查找聚合桶。
        var index: [String: Int] = [:]
        index.reserveCapacity(store.rollups.count)
        for (offset, rollup) in store.rollups.enumerated() {
            index["\(Int(rollup.hourStart))|\(rollup.category)"] = offset
        }

        for sample in samples {
            let hourStart = (sample.time / 3_600).rounded(.down) * 3_600
            let key = "\(Int(hourStart))|\(sample.category)"
            let bucket = Self.bucketIndex(for: sample.durationMS)
            if let offset = index[key] {
                store.rollups[offset].count += 1
                store.rollups[offset].totalMS += sample.durationMS
                store.rollups[offset].maxMS = max(store.rollups[offset].maxMS, sample.durationMS)
                store.rollups[offset].buckets[bucket] += 1
            } else {
                var rollup = Rollup(hourStart: hourStart, category: sample.category)
                rollup.count = 1
                rollup.totalMS = sample.durationMS
                rollup.maxMS = sample.durationMS
                rollup.buckets[bucket] = 1
                store.rollups.append(rollup)
                index[key] = store.rollups.count - 1
            }
        }
    }

    private static func bucketIndex(for durationMS: Double) -> Int {
        for (index, edge) in bucketEdgesMS.enumerated() where durationMS <= edge {
            return index
        }
        return bucketEdgesMS.count
    }

    // MARK: - 持久化

    private func loadLockedIfNeeded() {
        guard !didLoad else { return }
        loadLocked()
    }

    private func loadLocked() {
        didLoad = true
        defer { compactLocked(force: false) }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode(Store.self, from: data) else {
            Self.logger.error("性能记录文件解析失败，将重建")
            return
        }
        store = decoded
    }

    private func persistLocked() {
        guard isDirty else { return }
        isDirty = false
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            var data = try encoder.encode(store)
            if data.count > Self.maxFileBytes {
                // 兜底：正常策略下不会触发；异常高频写入时仍保证文件有硬上限。
                Self.logger.warning("性能记录超过体积上限（\(data.count) 字节），丢弃最旧数据")
                if store.rollups.count > 0 {
                    store.rollups.removeFirst(store.rollups.count / 2)
                }
                if store.samples.count > Self.maxRawSamples / 2 {
                    store.samples.removeFirst(store.samples.count - Self.maxRawSamples / 2)
                }
                data = (try? encoder.encode(store)) ?? Data()
            }
            try data.write(to: storeURL, options: .atomic)
        } catch {
            Self.logger.error("性能记录写入失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.loadLockedIfNeeded()
            self.compactLocked(force: false)
            self.persistLocked()
        }
        timer.resume()
        flushTimer = timer
    }
}

// MARK: - 导出与菜单动作

@MainActor
extension PerformanceRecorder {
    /// 生成可读摘要（按类别聚合最近 30 天，含样本量与 p95），用于快速判断优化方向。
    func summaryText() -> String {
        let lines: [String] = queue.sync { [weak self] in
            guard let self else { return [] }
            self.loadLockedIfNeeded()
            self.compactLocked(force: false)

            var perCategory: [String: (count: Int, total: Double, maxMS: Double, p95: Double)] = [:]
            for rollup in self.store.rollups {
                var entry = perCategory[rollup.category] ?? (0, 0, 0, 0)
                entry.count += rollup.count
                entry.total += rollup.totalMS
                entry.maxMS = max(entry.maxMS, rollup.maxMS)
                entry.p95 = max(entry.p95, rollup.percentile(0.95))
                perCategory[rollup.category] = entry
            }
            // 尚未聚合的原始样本也纳入统计，否则最近一小时的记录看不到。
            for sample in self.store.samples {
                var entry = perCategory[sample.category] ?? (0, 0, 0, 0)
                entry.count += 1
                entry.total += sample.durationMS
                entry.maxMS = max(entry.maxMS, sample.durationMS)
                entry.p95 = max(entry.p95, sample.durationMS)
                perCategory[sample.category] = entry
            }

            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
            }
            func number(_ value: Double, _ width: Int) -> String {
                pad(String(format: "%.1f", value), width)
            }

            let sorted = perCategory.sorted { $0.value.total > $1.value.total }
            var result: [String] = [
                "Qiyide 性能摘要（原始样本 \(self.store.samples.count) 条，聚合桶 \(self.store.rollups.count) 个）",
                pad("类别", 20) + pad("次数", 8) + pad("平均ms", 10) + pad("p95ms", 10) + "最大ms"
            ]
            for (category, value) in sorted {
                let average = value.count > 0 ? value.total / Double(value.count) : 0
                result.append(
                    pad(category, 20)
                        + pad(String(value.count), 8)
                        + number(average, 10)
                        + number(value.p95, 10)
                        + String(format: "%.1f", value.maxMS)
                )
            }
            return result
        }
        return lines.joined(separator: "\n")
    }

    /// 复制摘要到剪贴板。
    func copySummaryToPasteboard() {
        let text = summaryText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 弹出保存面板导出快照。
    func exportViaPanel() {
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("Export Performance Records", comment: "")
        panel.nameFieldStringValue = "qiyide-performance.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = exportJSON()
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Export Failed", comment: "")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
