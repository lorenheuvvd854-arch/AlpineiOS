// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import UIKit

@MainActor
final class VMViewModel: ObservableObject {
    @Published var isJITLive: Bool = false
    @Published var isVMRunning: Bool = false
    @Published var isUnpacking: Bool = false
    @Published var unpackProgress: Double = 0
    @Published var jitStatusText: String = "Checking JIT..."
    @Published var vmStatusText: String = "Initializing..."
    @Published var systemKeyboardVisible = false

    @Published var hasMachine = false
    @Published var imageStatus: String?
    @Published var imageError: String?
    @Published var downloadProgress: Double?
    @Published var downloadBytesText: String?
    @Published var downloadSpeedText: String?
    @Published var downloadRemainingText: String?
    @Published var lastDownloadActivity: Date?
    private var lastDownloadSampleTime: TimeInterval = 0
    private var lastDownloadSampleBytes: Int64 = 0
    private var downloadBytesPerSecond: Double = 0

    private func updateDownloadProgress(_ received: Int64, total: Int64) {
        let fraction = total > 0 ? Double(received) / Double(total) : 0
        downloadProgress = min(1, max(0, fraction))
        let format: (Int64) -> String = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        downloadBytesText = "\(format(received)) / \(format(total))"
        lastDownloadActivity = Date()
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastDownloadSampleTime
        let restarted = received < lastDownloadSampleBytes
        // A retry or a lock-screen pause makes the gap between samples huge. Rebase the
        // measurement instead of averaging the pause into a near-zero download speed.
        if elapsed < 0 || elapsed > 2 || restarted {
            lastDownloadSampleTime = now
            lastDownloadSampleBytes = received
            if restarted || elapsed > 2 {
                downloadBytesPerSecond = 0
                downloadSpeedText = nil
                downloadRemainingText = nil
            }
            return
        }
        guard elapsed >= 0.3, received > lastDownloadSampleBytes else { return }
        let sample = Double(received - lastDownloadSampleBytes) / elapsed
        if sample.isFinite, sample > 0 {
            downloadBytesPerSecond = downloadBytesPerSecond == 0 ? sample : 0.3 * sample + 0.7 * downloadBytesPerSecond
        }
        lastDownloadSampleTime = now
        lastDownloadSampleBytes = received
        guard downloadBytesPerSecond.isFinite, downloadBytesPerSecond > 1 else { return }
        downloadSpeedText = "\(format(Int64(downloadBytesPerSecond)))/s"
        let remaining = min(Double(max(0, total - received)) / downloadBytesPerSecond, 24 * 60 * 60)
        let seconds = max(0, Int(remaining))
        if seconds >= 60 {
            downloadRemainingText = "About \(max(1, (seconds + 30) / 60)) min remaining"
        } else {
            downloadRemainingText = "About \(max(1, seconds)) sec remaining"
        }
    }

    private func clearDownloadProgress() {
        downloadProgress = nil
        downloadBytesText = nil
        downloadSpeedText = nil
        downloadRemainingText = nil
        lastDownloadActivity = nil
    }

    private func updateIdleTimer() {
        // Auto-lock suspends the app mid-transfer and used to look like a download speed
        // collapse. Keep the display on while installing or while the guest is running.
        UIApplication.shared.isIdleTimerDisabled = installTask != nil || isVMRunning || isUnpacking
    }
    @Published private(set) var installationLog = ""
    private let installLogURL = URL.applicationSupportDirectory.appendingPathComponent("AlpineiOS/installation.log")

    func logInstallation(_ message: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        installationLog = String((installationLog + "[\(time)] \(message)\n").suffix(65_536))
        try? FileManager.default.createDirectory(at: installLogURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(installationLog.utf8).write(to: installLogURL, options: [.atomic, .completeFileProtection])
    }

    func guestInstallationLog() -> String {
        let file = SessionTools.shared.appendingPathComponent(".alpineios-install-log")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd() else { return "" }
        try? handle.seek(toOffset: length > 131_072 ? length - 131_072 : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
    @Published var softwareStatus: PhoshInstaller.SoftwareStatus?
    @Published var consolePassword = PhoshInstaller.storedPassword()
    @Published var guestToolsStatus: String?
    @Published var hasDiskSnapshot = FileManager.default.fileExists(atPath: SessionTools.snapshot.path)
    private let guestTools = GuestToolsUpdate()
    private var installTask: Task<Void, Never>?

    private var didAutoLaunchAttempt = false

    init() {
        installationLog = (try? String(contentsOf: installLogURL, encoding: .utf8)) ?? ""
        let bridge = WinIOSBridge.shared
        bridge.installTrapGuard()
        bridge.onStateChanged = { [weak self] in
            Task { @MainActor in
                self?.syncFromBridge()
            }
        }
        guestTools.prepare(password: consolePassword)
        syncFromBridge()
        Task { @MainActor [weak self] in
            self?.onAppBecameActive()
        }
    }

    func observeGuestSerial(_ data: Data) {
        guestTools.observe(data)
        if let password = PhoshInstaller.storedPassword(), consolePassword != password { consolePassword = password }
        guestToolsStatus = guestTools.status
    }

    func syncFromBridge() {
        let b = WinIOSBridge.shared
        isJITLive = b.isJITLive
        isVMRunning = b.isVMRunning
        isUnpacking = b.isUnpacking
        unpackProgress = b.unpackProgress
        jitStatusText = b.jitStatusText
        vmStatusText = b.vmStatusText
        guestTools.observe(Data())
        if let password = PhoshInstaller.storedPassword(), consolePassword != password { consolePassword = password }
        let toolsStatus = guestTools.status
        if toolsStatus != guestToolsStatus, let toolsStatus { logInstallation(toolsStatus) }
        guestToolsStatus = toolsStatus
        if b.isUnpacking {
            downloadBytesText = "Disk extraction: \(Int(b.unpackProgress * 100))%"
        }
        hasMachine = b.hasProvisionedMachine()
        if consolePassword != nil && softwareStatus != .ready {
            let status = PhoshInstaller.softwareStatus()
            if status != softwareStatus {
                switch status {
                case .installing: logInstallation("Linux is downloading and installing selected apps.")
                case .retrying: logInstallation("Linux app installation failed. Retrying.")
                case .ready: logInstallation("Selected Linux apps installed.")
                case nil: break
                }
            }
            softwareStatus = status
            if softwareStatus == .ready { PhoshInstaller.clearRequest() }
        }
        updateIdleTimer()
    }

    func onAppBecameActive() {
        let b = WinIOSBridge.shared
        if !b.isJITLive && b.isDebuggerAttached {
            _ = b.tryAcquireJIT(true)
        }
        syncFromBridge()
        if b.isJITLive && !b.isVMRunning && !b.isUnpacking && installTask == nil && imageStatus == nil && hasMachine && !didAutoLaunchAttempt {
            didAutoLaunchAttempt = true
            b.prepareAndStart(with: nil)
            syncFromBridge()
        }
    }

    func diskSnapshot(restore: Bool) {
        guard !isVMRunning, !isUnpacking, imageStatus == nil, hasMachine else { return }
        let disk = URL(fileURLWithPath: WinIOSBridge.shared.machineDirectory()).appendingPathComponent("alpine.img")
        let snapshot = SessionTools.snapshot
        imageError = nil
        imageStatus = restore ? "Restoring disk snapshot…" : "Saving disk snapshot…"
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SessionTools.copyDisk(from: restore ? snapshot : disk, to: restore ? disk : snapshot)
                }.value
                hasDiskSnapshot = true
            } catch {
                imageError = error.localizedDescription
            }
            imageStatus = nil
        }
    }

    func startOrRetry() {
        didAutoLaunchAttempt = isJITLive
        WinIOSBridge.shared.prepareAndStart(with: nil)
        syncFromBridge()
    }

    func downloadPhosh(address: String, apps: Set<PhoshApp>, customPassword: String) {
        guard installTask == nil, !hasMachine, PhoshInstaller.validCustomPassword(customPassword) else { return }
        imageError = nil
        imageStatus = "Preparing download…"
        clearDownloadProgress()
        lastDownloadSampleTime = ProcessInfo.processInfo.systemUptime
        lastDownloadSampleBytes = 0
        downloadBytesPerSecond = 0
        installationLog = ""
        logInstallation("Preparing image download")
        var lastMilestone = -1
        installTask = Task {
            let password = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            do {
                try await PhoshInstaller.install(address: address, apps: apps, password: password, customPassword: customPassword, progress: { received, total in
                    self.updateDownloadProgress(received, total: total)
                    let fraction = total > 0 ? Double(received) / Double(total) : 0
                    let milestone = Int(fraction * 10)
                    if milestone > lastMilestone {
                        lastMilestone = milestone
                        self.logInstallation("Downloaded \(Int(fraction * 100))% — \(self.downloadBytesText ?? "")")
                    }
                }) {
                    imageStatus = $0
                    logInstallation($0)
                }
                consolePassword = password
                guestTools.prepare(password: password)
                installTask = nil
                imageStatus = nil
                clearDownloadProgress()
                logInstallation("Image verified and installed. Starting Linux.")
                startOrRetry()
                updateIdleTimer()
            } catch {
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    imageError = error.localizedDescription
                    logInstallation("Error: \(error.localizedDescription)")
                } else {
                    logInstallation("Download cancelled.")
                }
                clearDownloadProgress()
                imageStatus = nil
                installTask = nil
                updateIdleTimer()
                syncFromBridge()
            }
        }
        updateIdleTimer()
    }

    func cancelDownload() { installTask?.cancel() }

    func requestStikDebugJIT() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var urlStr = "stikjit://enable-jit?bundle-id=\(bundleID)&pid=\(getpid())"
        if let scriptPath = Bundle.main.path(forResource: "henge-jit", ofType: "js"),
           let script = try? String(contentsOfFile: scriptPath, encoding: .utf8),
           let data = script.data(using: .utf8) {
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if let encoded = b64.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlStr += "&script-data=\(encoded)"
            }
        }
        if let url = URL(string: urlStr) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
