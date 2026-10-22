//
//  SoftwareUpdater.swift
//  CodeEdit
//
//  Created by Austin Condiff on 9/19/22.
//

import Foundation
import Sparkle

class SoftwareUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// 自有更新通道配置。
    ///
    /// Qiyide 是从 CodeEdit fork 出的独立发行版，**不能**沿用上游的 appcast 与 EdDSA 公钥：
    /// 否则应用会把自己「更新」回 CodeEdit，覆盖当前安装，与「两个版本共存」的目标直接冲突。
    /// 在发布自有 appcast 之前，更新通道保持未配置，更新器整体关闭。
    ///
    /// 启用步骤：
    /// 1. 用自有 EdDSA 私钥签名发行包，并在 Info.plist 写入 `SUPublicEDKey`；
    /// 2. 将下方 `appcastURL` 指向自有 feed；
    /// 3. 双键齐备后 ``isAvailable`` 自动变为 `true`，设置页的更新控件随之启用。
    enum UpdateChannel {
        static let appcastURL: URL? = nil
        static let isConfigured: Bool = appcastURL != nil
    }

    /// 更新功能是否可用。设置页据此禁用相关控件，避免用户点击后收到误导性错误。
    static var isAvailable: Bool { UpdateChannel.isConfigured }

    private var updater: SPUUpdater?
    private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?
    private var lastUpdateCheckDateObservation: NSKeyValueObservation?

    @Published var automaticallyChecksForUpdates = false {
        didSet {
            updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var lastUpdateCheckDate: Date?

    @Published var includePrereleaseVersions = true {
        didSet {
            UserDefaults.standard.setValue(includePrereleaseVersions, forKey: "includePrereleaseVersions")
        }
    }

    private var feedURLTask: Task<(), Never>?

    /// 应用自有 appcast。上游通过 GitHub API 反查最新 tag 的方式只适用于 CodeEdit 官方仓库，
    /// 自有发行版直接在 ``UpdateChannel`` 中固定 feed 地址。
    private func setFeedURL() async {
        guard let feedURL = UpdateChannel.appcastURL else { return }
        await MainActor.run {
            self.updater?.setFeedURL(feedURL)
        }
    }

    override init() {
        super.init()

        includePrereleaseVersions = UserDefaults.standard.bool(forKey: "includePrereleaseVersions")

        // 未配置自有更新源时不创建 updater，避免继承上游 feed 导致自我覆盖。
        guard UpdateChannel.isConfigured else {
            return
        }

        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        ).updater

        feedURLTask = Task {
            await setFeedURL()
        }

        automaticallyChecksForUpdatesObservation = updater?.observe(
            \.automaticallyChecksForUpdates,
            options: [.initial, .new, .old],
            changeHandler: { [unowned self] updater, change in
                guard change.newValue != change.oldValue else { return }
                self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
            }
        )

        lastUpdateCheckDateObservation = updater?.observe(
            \.lastUpdateCheckDate,
            options: [.initial, .new, .old],
            changeHandler: { [unowned self] updater, _ in
                self.lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        )
    }

    deinit {
        feedURLTask?.cancel()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // 自有发行版只分发稳定通道；预发布通道在配置自有 feed 后再按需开启。
        return []
    }

    func checkForUpdates() {
        guard SoftwareUpdater.isAvailable else { return }
        updater?.checkForUpdates()
    }
}
