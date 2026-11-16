// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

enum AlpineTheme {
    static let accent = Color(red: 0.72, green: 0.96, blue: 0.62)
    static let background = Color(red: 0.04, green: 0.085, blue: 0.08)
    static let panel = Color(red: 0.075, green: 0.15, blue: 0.135)
}

struct PhoshSetupView: View {
    @ObservedObject var vm: VMViewModel
    let openHelp: () -> Void
    @AppStorage("phoshManifestURL") private var savedAddress = ""
    @AppStorage("phoshManifestDefault") private var previousDefault = ""
    @State private var address = ""
    @State private var customPassword = ""
    @State private var selected = PhoshApp.defaults
    @State private var showSource = false
    @State private var confirmRestore = false
    @State private var showInstallationLog = false

    private var configuredSource: String {
        Bundle.main.object(forInfoDictionaryKey: "AlpineImageManifestURL") as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                if let status = vm.imageStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status).font(.subheadline)
                        if let progress = vm.downloadProgress {
                            ProgressView(value: progress)
                        } else { ProgressView() }
                        if let bytes = vm.downloadBytesText {
                            Text(bytes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let activity = vm.lastDownloadActivity, status.hasPrefix("Downloading") {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                if context.date.timeIntervalSince(activity) > 5 {
                                    Text("0 B/s · Waiting for data…")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    HStack {
                                        Text(vm.downloadSpeedText ?? "Measuring speed…")
                                        Spacer()
                                        if let remaining = vm.downloadRemainingText { Text(remaining) }
                                    }
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(AlpineTheme.panel, in: RoundedRectangle(cornerRadius: 20))
                } else if vm.hasMachine {
                    machineStatus
                } else {
                    passwordOptions
                    software
                    source
                }

                Button { showInstallationLog = true } label: {
                    Label("Installation log", systemImage: "text.alignleft")
                }

                if let error = vm.imageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color(red: 1, green: 0.64, blue: 0.57))
                }
            }
            .frame(maxWidth: 500)
            .padding(22)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showInstallationLog) { InstallationLogView(vm: vm) }
        .scrollDismissesKeyboard(.interactively)
        .background(AlpineTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
                .frame(maxWidth: 500)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(AlpineTheme.background)
        }
        .confirmationDialog("Restore the saved Linux disk? Changes since the snapshot will be lost.",
                            isPresented: $confirmRestore) {
            Button("Restore disk", role: .destructive) { vm.diskSnapshot(restore: true) }
        }
        .tint(AlpineTheme.accent)
        .onAppear {
            if previousDefault != configuredSource,
               PhoshInstaller.sourceURL(configuredSource)?.scheme == "https",
               PhoshInstaller.sourceURL(savedAddress)?.scheme == "http" {
                savedAddress = ""
            }
            previousDefault = configuredSource
            address = savedAddress.isEmpty ? configuredSource : savedAddress
            showSource = address.isEmpty
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image("AlpineMark")
                    .resizable()
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                Spacer()
                Button(action: openHelp) {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Help")
                .foregroundStyle(AlpineTheme.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("AlpineiOS").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text("postmarketOS with Phosh")
                    .font(.subheadline)
                    .foregroundStyle(Color(red: 0.76, green: 0.87, blue: 0.8))
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [AlpineTheme.panel, Color(red: 0.12, green: 0.27, blue: 0.21)],
                           startPoint: .bottomLeading, endPoint: .topTrailing),
            in: RoundedRectangle(cornerRadius: 25)
        )
    }

    private var software: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Linux apps").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                Label("Settings included", systemImage: "gearshape")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                ForEach(PhoshApp.allCases) { app in
                    Divider()
                    Toggle(isOn: Binding(
                        get: { selected.contains(app) },
                        set: { enabled in
                            if enabled { selected.insert(app) } else { selected.remove(app) }
                        }
                    )) {
                        Label(app.title, systemImage: symbol(for: app))
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, 14)
            .background(AlpineTheme.panel, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var passwordOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Linux password").font(.title3.weight(.semibold))
            SecureField("Optional password", text: $customPassword)
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text(PhoshInstaller.validCustomPassword(customPassword)
                 ? "Used for user login and doas. Leave blank to generate one."
                 : "Use up to 64 printable ASCII characters without a colon.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(AlpineTheme.panel, in: RoundedRectangle(cornerRadius: 15))
    }

    private var source: some View {
        DisclosureGroup("Image source", isExpanded: $showSource) {
            TextField("HTTPS manifest URL", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(.top, 8)
        }
        .font(.subheadline)
        .padding(14)
        .background(AlpineTheme.panel, in: RoundedRectangle(cornerRadius: 15))
    }

    private var machineStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vm.isUnpacking ? "Preparing the disk" : "Linux machine")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(vm.vmStatusText).font(.subheadline).foregroundStyle(.secondary)
            if vm.isUnpacking {
                ProgressView(value: vm.unpackProgress)
            } else if !vm.isJITLive {
                Text(vm.jitStatusText).font(.caption).foregroundStyle(.secondary)
            }
            if !vm.isUnpacking {
                Button(vm.hasDiskSnapshot ? "Replace disk snapshot" : "Save disk snapshot") {
                    vm.diskSnapshot(restore: false)
                }
                if vm.hasDiskSnapshot {
                    Button("Restore disk snapshot") { confirmRestore = true }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AlpineTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var footer: some View {
        if vm.imageStatus != nil {
            Button("Cancel download", role: .cancel, action: vm.cancelDownload)
                .buttonStyle(.bordered)
        } else if vm.hasMachine {
            if !vm.isUnpacking {
                VStack(spacing: 9) {
                    primary("Start Linux", symbol: "play.fill") { vm.startOrRetry() }
                    if !vm.isJITLive {
                        Button("Enable JIT with StikDebug") { vm.requestStikDebugJIT() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        } else {
            primary("Download and install", symbol: "arrow.down.to.line") {
                savedAddress = address
                vm.downloadPhosh(address: address, apps: selected, customPassword: customPassword)
                customPassword = ""
            }
            .disabled(PhoshInstaller.sourceURL(address) == nil || !PhoshInstaller.validCustomPassword(customPassword))
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .foregroundStyle(AlpineTheme.background)
    }

    private func symbol(for app: PhoshApp) -> String {
        switch app {
        case .firefox: "globe"
        case .nautilus: "folder"
        case .console: "terminal"
        case .telegram: "paperplane"
        case .editor: "doc.text"
        case .monitor: "waveform.path"
        }
    }
}
