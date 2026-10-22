//
//  MemoryProbe.swift
//  CodeEdit
//
//  进程内存探针（M0 基线工具）。
//

import Foundation
import AppKit
import Darwin
import OSLog

/// 进程内存探针。
///
/// 用于给「轻量化」目标提供可复现的量化基线：定期采样当前进程的 `phys_footprint`（与 Xcode
/// Memory Report 口径一致），以及 RSS 与峰值，追加写入 JSONL 日志，供脚本汇总。
///
/// 默认不工作，仅在以下任一条件满足时启用：
/// - 启动参数包含 `--memory-probe`
/// - `UserDefaults` 中 `CEMemoryProbeEnabled == true`
///
/// 采样成本为一次 `task_info` 调用，间隔默认 11 秒，对用户无感知。
@MainActor
final class MemoryProbe: ObservableObject {
    static let shared = MemoryProbe()

    /// 采样间隔（秒）。
    static let sampleInterval: TimeInterval = 11

    /// 单次采样结果。
    struct Sample: Codable {
        let timestamp: String
        let footprintBytes: UInt64
        let residentBytes: UInt64
        let peakFootprintBytes: UInt64
        let openDocuments: Int
        let note: String?
    }

    /// 最近一次采样结果，供调试 UI 绑定。
    @Published private(set) var latest: Sample?
    @Published private(set) var isRunning = false

    private var timer: Timer?
    private var peak: UInt64 = 0
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "MemoryProbe")
    private let logURL: URL
    private let isoFormatter: ISO8601DateFormatter

    private init() {
        let supportURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Qiyide", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        logURL = supportURL.appending(path: "memory-probe.jsonl")

        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// 是否启用探针。
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--memory-probe")
            || UserDefaults.standard.bool(forKey: "CEMemoryProbeEnabled")
    }

    /// 探针日志文件位置。
    static var logFileURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Qiyide/memory-probe.jsonl")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sample(note: "start")

        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample(note: nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("MemoryProbe started. Log: \(self.logURL.path, privacy: .public)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// 立即采样一次。
    func sample(note: String? = nil) {
        let footprint = Self.currentFootprint()
        peak = max(peak, footprint)

        let sample = Sample(
            timestamp: isoFormatter.string(from: Date()),
            footprintBytes: footprint,
            residentBytes: Self.currentResident(),
            peakFootprintBytes: peak,
            openDocuments: NSDocumentController.shared.documents.count,
            note: note
        )

        latest = sample
        append(sample)
    }

    // MARK: - Mach 采样

    /// 当前进程的物理内存占用（与 Xcode Memory Report 的 footprint 同口径）。
    static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// 当前进程的常驻内存（RSS）。
    static func currentResident() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    // MARK: - 落盘

    private func append(_ sample: Sample) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        var payload = data
        payload.append(0x0A) // 换行，形成 JSONL

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: logURL, options: .atomic)
        }
    }
}
