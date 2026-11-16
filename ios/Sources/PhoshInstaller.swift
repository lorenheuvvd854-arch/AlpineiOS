// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation

enum PhoshApp: String, CaseIterable, Identifiable {
    case firefox, nautilus, console, telegram, editor, monitor

    static let defaults: Set<Self> = [.firefox, .nautilus, .console]
    var id: String { rawValue }

    var title: String {
        switch self {
        case .firefox: "Firefox"
        case .nautilus: "Files (Nautilus)"
        case .console: "Console"
        case .telegram: "Telegram Desktop"
        case .editor: "Mousepad Text Editor"
        case .monitor: "htop (terminal)"
        }
    }
}

struct PhoshInstaller {
    private struct Manifest: Decodable {
        let version: Int
        let assets: [String: Asset]
    }

    private struct Asset: Decodable {
        let bytes: Int64
        let sha256: String
    }

    private final class RedirectPolicy: NSObject, URLSessionDownloadDelegate {
        private let progress: (@Sendable (Int64) -> Void)?
        private let resumeData: Data?
        private var lastProgress = Date.distantPast
        private let transferLock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var downloadedFile: URL?
        private var fileError: Error?
        private var cancelled = false
        private var storedResumeData: Data?
        var pendingResumeData: Data? {
            transferLock.lock()
            defer { transferLock.unlock() }
            return storedResumeData
        }

        init(progress: (@Sendable (Int64) -> Void)? = nil, resumeData: Data? = nil) {
            self.progress = progress
            self.resumeData = resumeData
        }

        func download(from url: URL) async throws -> (URL, URLResponse) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    transferLock.lock()
                    self.continuation = continuation
                    let configuration = URLSessionConfiguration.default
                    // Long image downloads must survive short Wi-Fi drops and lock-screen suspension
                    // instead of failing the whole transfer.
                    configuration.waitsForConnectivity = true
                    configuration.timeoutIntervalForRequest = 60
                    configuration.timeoutIntervalForResource = 60 * 60 * 6
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    let task = self.resumeData.map { session.downloadTask(withResumeData: $0) }
                        ?? session.downloadTask(with: url)
                    self.session = session
                    self.task = task
                    let cancel = cancelled
                    transferLock.unlock()
                    if cancel { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                self.transferLock.lock()
                self.cancelled = true
                let task = self.task
                self.transferLock.unlock()
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                downloadedFile = destination
            } catch { fileError = error }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            transferLock.lock()
            storedResumeData = resumeData
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            self.session = nil
            transferLock.unlock()
            session.finishTasksAndInvalidate()
            if let error = error ?? fileError {
                if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
                continuation?.resume(throwing: error)
            } else if let downloadedFile, let response = task.response {
                continuation?.resume(returning: (downloadedFile, response))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let now = Date()
            guard now.timeIntervalSince(lastProgress) >= 0.4 ||
                    totalBytesWritten == totalBytesExpectedToWrite else { return }
            lastProgress = now
            progress?(totalBytesWritten)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url, PhoshInstaller.sourceURL(url.absoluteString) != nil,
                  response.url?.scheme != "https" || url.scheme == "https" else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    enum SetupError: LocalizedError {
        case invalidAddress, invalidManifest, downloadFailed(String), badAsset(String), existingMachine, insufficientStorage

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter an HTTPS manifest URL or an HTTP URL on your local network."
            case .invalidManifest: "The Phosh image manifest is invalid or uses an unsupported version."
            case .downloadFailed(let name): "Could not download \(name). Check the address and try again."
            case .badAsset(let name): "The downloaded \(name) did not match the manifest."
            case .insufficientStorage: "There is not enough free space to download and unpack Phosh."
            case .existingMachine: "A machine already exists at this location. Move its files before installing a new image."
            }
        }
    }

    private static let names = ["code.fd", "vars.fd", "alpine.hvsparse"]
    private static let documents = URL.documentsDirectory
    private static let share = documents.appendingPathComponent("Shared", isDirectory: true)
    private static let request = share.appendingPathComponent(".alpineios-install-request")
    private static let status = share.appendingPathComponent(".alpineios-install-status")
    private static let passwordStore = URL.applicationSupportDirectory
        .appendingPathComponent("AlpineiOS", isDirectory: true).appendingPathComponent("console-password")


    private static let pendingPasswordStore = passwordStore.deletingLastPathComponent()
        .appendingPathComponent("pending-console-password")
    private static let passwordRequest = share.appendingPathComponent(".alpineios-password-request")
    private static let passwordApplied = share.appendingPathComponent(".alpineios-password-applied")

    static func validCustomPassword(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.utf8.allSatisfy { (32...126).contains($0) && $0 != 58 }
    }

    static func pendingPassword() -> String? {
        try? String(contentsOf: pendingPasswordStore, encoding: .utf8)
    }

    static func stagePasswordChange() throws {
        guard let value = pendingPassword() else { return }
        try Data(value.utf8).write(to: passwordRequest, options: [.atomic, .completeFileProtection])
    }

    static func finishPasswordChange(verifiedLogin: Bool = false) -> String? {
        guard verifiedLogin || (try? String(contentsOf: passwordApplied, encoding: .utf8)) == "ok",
              let password = pendingPassword() else { return nil }
        do {
            try Data(password.utf8).write(to: passwordStore, options: [.atomic, .completeFileProtection])
            try FileManager.default.removeItem(at: pendingPasswordStore)
            try? FileManager.default.removeItem(at: passwordRequest)
            try? FileManager.default.removeItem(at: passwordApplied)
            return password
        } catch {
            return nil
        }
    }

    enum SoftwareStatus: String {
        case installing, retrying, ready
    }

    static func softwareStatus() -> SoftwareStatus? {
        guard let data = try? FileHandle(forReadingFrom: status) else { return nil }
        defer { try? data.close() }
        guard let contents = try? data.read(upToCount: 32),
              let value = String(data: contents, encoding: .utf8) else { return nil }
        return SoftwareStatus(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func storedPassword() -> String? {
        try? String(contentsOf: passwordStore, encoding: .utf8)
    }

    static func clearRequest() {
        try? FileManager.default.removeItem(at: request)
    }

    static func sourceURL(_ address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        if url.scheme == "https" { return url }
        guard url.scheme == "http" else { return nil }
        if host.hasSuffix(".local") || host == "localhost" { return url }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard host.split(separator: ".", omittingEmptySubsequences: false).count == 4, parts.count == 4 else { return nil }
        if parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1])) { return url }
        return nil
    }

    private final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var highest: Int64 = 0

        func update(_ value: Int64) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            highest = max(highest, value)
            return highest
        }
    }

    private static let transientErrors: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .secureConnectionFailed,
        .badServerResponse, .internationalRoamingOff, .dataNotAllowed,
    ]

    private static func retryDelay(_ attempt: Int) async throws {
        let seconds = min(8, 1 << (attempt - 1))
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }

    /// Downloads a single file, retrying transient network failures and temporary HTTP errors.
    /// Each attempt uses a fresh delegate so no state leaks between retries.
    private static func fetch(
        _ url: URL,
        label: String,
        progress: (@Sendable (Int64) -> Void)? = nil,
        attempts: Int = 4
    ) async throws -> (URL, URLResponse) {
        var lastError: Error = SetupError.downloadFailed(label)
        var resumeData: Data?
        let report: (@Sendable (Int64) -> Void)?
        if let progress {
            let box = ProgressTracker()
            report = { progress(box.update($0)) }
        } else {
            report = nil
        }
        for attempt in 1...attempts {
            try Task.checkCancellation()
            let policy = RedirectPolicy(progress: report, resumeData: resumeData)
            do {
                let (file, response) = try await policy.download(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode
                if let status, status == 429 || (500...599).contains(status) {
                    try? FileManager.default.removeItem(at: file)
                    lastError = SetupError.downloadFailed(label)
                    resumeData = nil
                    guard attempt < attempts else { throw lastError }
                } else {
                    return (file, response)
                }
            } catch let error as URLError where transientErrors.contains(error.code) {
                lastError = error
                resumeData = policy.pendingResumeData ?? resumeData
                guard attempt < attempts else { throw error }
            }
            try await retryDelay(attempt)
        }
        throw lastError
    }

    @MainActor
    static func install(
        address: String,
        apps: Set<PhoshApp>,
        password: String,
        customPassword: String,
        progress: @escaping @MainActor (Int64, Int64) -> Void,
        update: (String) -> Void
    ) async throws {
        guard let source = sourceURL(address) else { throw SetupError.invalidAddress }
        let fm = FileManager.default
        let machines = documents.appendingPathComponent("Machines", isDirectory: true)
        let target = machines.appendingPathComponent("PostmarketOS-Native", isDirectory: true)
        let staging = machines.appendingPathComponent(".phosh-download", isDirectory: true)
        func checkDestination() throws {
            if fm.fileExists(atPath: target.path),
               try !fm.contentsOfDirectory(atPath: target.path).isEmpty {
                throw SetupError.existingMachine
            }
        }
        try checkDestination()
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        update("Reading image manifest…")
        let (manifestFile, manifestResponse) = try await fetch(source, label: "manifest")
        defer { try? fm.removeItem(at: manifestFile) }
        guard let response = manifestResponse as? HTTPURLResponse, response.statusCode == 200,
              let manifestURL = response.url, sourceURL(manifestURL.absoluteString) != nil,
              let size = try? manifestFile.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024,
              let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1,
              Set(manifest.assets.keys) == Set(names) else { throw SetupError.invalidManifest }

        let assets = try names.map { name in
            guard let asset = manifest.assets[name], asset.bytes > 0, asset.bytes <= 16 * 1024 * 1024 * 1024,
                  asset.sha256.utf8.count == 64,
                  asset.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw SetupError.invalidManifest
            }
            return (name, asset)
        }
        let downloadBytes = assets.reduce(Int64(0)) { $0 + $1.1.bytes }
        if let free = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < downloadBytes * 2 {
            throw SetupError.insufficientStorage
        }

        var completedBytes: Int64 = 0
        for (index, item) in assets.enumerated() {
            let (name, asset) = item
            let url = source.deletingLastPathComponent().appendingPathComponent(name)
            update("Downloading \(name) (\(index + 1)/\(names.count))…")
            let previousBytes = completedBytes
            let (download, response) = try await fetch(url, label: name) { received in
                Task { @MainActor in
                    progress(previousBytes + min(received, asset.bytes), downloadBytes)
                }
            }
            defer { try? fm.removeItem(at: download) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let finalURL = http.url, sourceURL(finalURL.absoluteString) != nil else {
                throw SetupError.downloadFailed(name)
            }
            completedBytes += asset.bytes
            progress(completedBytes, downloadBytes)
            update("Verifying \(name)…")
            let valid = try await Task.detached(priority: .utility) {
                try verify(download, against: asset)
            }.value
            try Task.checkCancellation()
            guard valid else { throw SetupError.badAsset(name) }
            try fm.moveItem(at: download, to: staging.appendingPathComponent(name))
        }

        try checkDestination()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.createDirectory(at: share, withIntermediateDirectories: true)
        try? fm.removeItem(at: status)
        try? fm.removeItem(at: passwordApplied)
        try? fm.removeItem(at: passwordRequest)
        try? fm.removeItem(at: pendingPasswordStore)
        try? fm.removeItem(at: share.appendingPathComponent(".alpineios-tools-status"))
        let choices = PhoshApp.allCases.filter(apps.contains).map(\.rawValue).joined(separator: " ")
        let protection: Data.WritingOptions = [.atomic, .completeFileProtection]
        do {
            try fm.createDirectory(at: passwordStore.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(password.utf8).write(to: passwordStore, options: protection)
            if !customPassword.isEmpty {
                try Data(customPassword.utf8).write(to: pendingPasswordStore, options: protection)
            }
            try Data("\(password)\n\(choices)\n".utf8).write(to: request, options: protection)
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: passwordStore)
            try? fm.removeItem(at: pendingPasswordStore)
            clearRequest()
            throw error
        }
    }

    private static func verify(_ file: URL, against asset: Asset) throws -> Bool {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.bytes else { return false }
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}
