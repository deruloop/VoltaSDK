//
//  DemoRootView.swift
//  AIProviderKitDemoUI
//
//  Test UI shared between the macOS demo (`swift run AIProviderKitDemo`)
//  and the iOS demo app (Examples/iOSDemo). Same logic on both platforms:
//  live configuration, fallback-chain status (with unavailability reasons,
//  e.g. a device without Apple Intelligence), a playground with response
//  provenance, and a privacy-downgrade log.
//
//  Adaptive layout:
//   - macOS: HSplitView (configuration | playground)
//   - iOS:   TabView (Configure / Playground)
//

import SwiftUI
import AIProviderKit
import AIProviderKitUI

/// Privacy-downgrade events collected by the `.notify` policy, surfaced
/// in the test UI.
@MainActor @Observable
final class DowngradeLog {
    var events: [String] = []
}

public struct DemoRootView: View {
    // Editable configuration (recreates the orchestrator on "Apply").
    @State private var enableOnDevice = true
    @State private var apiKey = ""
    @State private var model = "gpt-4o-mini"
    @State private var preference: ModelPreference = .preferOnDevice
    @State private var notifyDowngrades = true

    @State private var orchestrator = AIOrchestrator(configuration: AIConfiguration())
    @State private var downgradeLog = DowngradeLog()

    public init() {}

    public var body: some View {
        platformLayout
            .onAppear { applyConfiguration() }
    }

    // MARK: Per-platform layout

    @ViewBuilder
    private var platformLayout: some View {
        #if os(macOS)
        HSplitView {
            configurationForm
                .frame(minWidth: 280, maxWidth: 340)
            playgroundPane
                .frame(minWidth: 400, maxWidth: .infinity)
        }
        #else
        TabView {
            Tab("Configure", systemImage: "gearshape") {
                NavigationStack {
                    configurationForm
                        .navigationTitle("AIProviderKit")
                }
            }
            Tab("Playground", systemImage: "bubble.left.and.text.bubble.right") {
                NavigationStack {
                    playgroundPane
                        .navigationTitle("Playground")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        #endif
    }

    // MARK: Panes

    private var configurationForm: some View {
        Form {
            Section("Providers") {
                Toggle("On-device model", isOn: $enableOnDevice)
                SecureField("OpenAI API key", text: $apiKey)
                    .textContentType(.password)
                TextField("Developer key model", text: $model)
                    .autocorrectionDisabled()
                Picker("Preference", selection: $preference) {
                    Text("On-device first").tag(ModelPreference.preferOnDevice)
                    Text("Developer key first").tag(ModelPreference.preferDeveloperKey)
                    Text("On-device only").tag(ModelPreference.onDeviceOnly)
                    Text("Developer key only").tag(ModelPreference.developerKeyOnly)
                }
            }
            Section("Privacy") {
                Toggle("Notify privacy downgrades", isOn: $notifyDowngrades)
                if !downgradeLog.events.isEmpty {
                    ForEach(downgradeLog.events.indices, id: \.self) { index in
                        Text(downgradeLog.events[index])
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button("Apply configuration") { applyConfiguration() }
                #if os(macOS)
                    .keyboardShortcut("r")
                #endif
            }
            Section {
                ProviderStatusList(orchestrator: orchestrator)
            }
        }
        .formStyle(.grouped)
    }

    private var playgroundPane: some View {
        AIPlaygroundView(
            orchestrator: orchestrator,
            instructions: nil,
            placeholder: "Try a prompt (e.g. \"Plan a weekend in Rome\")"
        )
        .padding()
    }

    // MARK: Configuration

    private func applyConfiguration() {
        let log = downgradeLog
        var config = AIConfiguration()
        config.enableOnDevice = enableOnDevice
        config.developerKey = apiKey.isEmpty ? nil : apiKey
        config.developerKeyModel = model
        config.preference = preference
        if notifyDowngrades {
            config.privacyDisclosure = .notify { downgrade in
                Task { @MainActor in
                    log.events.append(
                        "Downgrade: \(downgrade.from) → \(downgrade.to) via \(downgrade.provider)"
                    )
                }
            }
        }
        orchestrator = AIOrchestrator(configuration: config)
    }
}
