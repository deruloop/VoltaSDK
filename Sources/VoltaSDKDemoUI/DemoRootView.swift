//
//  DemoRootView.swift
//  VoltaSDKDemoUI
//
//  Test UI shared between the macOS demo (`swift run VoltaSDKDemo`)
//  and the iOS demo app (Examples/iOSDemo). It deliberately mirrors the
//  two roles in a real integration:
//
//   - DEVELOPER side: the configuration form (which providers exist, keys,
//     fallback preference, privacy policy) + "Apply configuration".
//   - USER side: the chat on top and the ModelSelector below it — the user
//     picks the model, the developer's activation gate runs (here, a
//     simulated subscription check for the cloud model), and the chat shows
//     the result of configuration × user preference.
//
//  Adaptive layout:
//   - macOS: HSplitView (developer | user)
//   - iOS:   TabView (Developer / User)
//

import SwiftUI
import VoltaSDK
import VoltaSDKUI

/// Privacy-downgrade events collected by the `.notify` policy, surfaced
/// in the test UI.
@MainActor @Observable
final class DowngradeLog {
    var events: [String] = []
}

public struct DemoRootView: View {
    // Developer configuration (recreates the orchestrator on "Apply").
    @State private var enableOnDevice = true
    @State private var apiKey = ""
    @State private var model = "gpt-4o-mini"
    @State private var preference: ModelPreference = .preferOnDevice
    @State private var notifyDowngrades = true

    // Simulated entitlement: in a real app this would be your paywall /
    // StoreKit check. The cloud-model row is gated on it.
    @State private var userHasSubscription = true

    // User-side state: what the end user picked in the ModelSelector.
    @State private var userSelection: ProviderIdentifier?

    @State private var orchestrator = AIOrchestrator(configuration: AIConfiguration())
    @State private var downgradeLog = DowngradeLog()

    public init() {}

    public var body: some View {
        platformLayout
            .onAppear { applyConfiguration() }
            .onChange(of: userSelection) {
                // The user's choice re-leads the fallback chain.
                applyConfiguration()
            }
    }

    // MARK: Per-platform layout

    @ViewBuilder
    private var platformLayout: some View {
        #if os(macOS)
        HSplitView {
            configurationForm
                .frame(minWidth: 300, maxWidth: 360)
            userPane
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        #else
        TabView {
            Tab("Developer", systemImage: "gearshape") {
                NavigationStack {
                    configurationForm
                        .navigationTitle("Developer")
                }
            }
            Tab("User", systemImage: "person.crop.circle") {
                NavigationStack {
                    userPane
                        .navigationTitle("User")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        #endif
    }

    // MARK: Developer side

    private var configurationForm: some View {
        Form {
            Section("Providers") {
                Toggle("On-device model", isOn: $enableOnDevice)
                SecureField("OpenAI API key", text: $apiKey)
                    .textContentType(.password)
                TextField("Developer key model", text: $model)
                    .autocorrectionDisabled()
                Picker("Default preference", selection: $preference) {
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
            Section("Simulated entitlements") {
                Toggle("User has an active subscription", isOn: $userHasSubscription)
                Text("The \"Cloud model\" option in the user-side selector is gated on this — flip it off and try selecting it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: User side

    private var userPane: some View {
        VStack(spacing: 12) {
            // The chat: shows the result of configuration × user preference.
            AIPlaygroundView(
                orchestrator: orchestrator,
                instructions: nil,
                placeholder: "Try a prompt (e.g. \"Plan a weekend in Rome\")"
            )

            Divider()

            // The user-side selector, with the developer's activation gate.
            ModelSelector(
                orchestrator: orchestrator,
                selection: $userSelection,
                activation: { [userHasSubscription] provider in
                    // On-device is immediate; the cloud model simulates a
                    // paywall/entitlement check (in a real app: StoreKit,
                    // or on iOS 27 an OAuth flow for user-account providers).
                    guard provider == .openAI else { return true }
                    try? await Task.sleep(for: .milliseconds(700))
                    return userHasSubscription
                }
            )
        }
        .padding()
    }

    // MARK: Configuration

    private func applyConfiguration() {
        let log = downgradeLog
        var config = AIConfiguration()
        config.enableOnDevice = enableOnDevice
        config.developerKey = apiKey.isEmpty ? nil : apiKey
        config.developerKeyModel = model
        config.preference = effectivePreference
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

    /// The user's selection (when present) leads the chain; the developer's
    /// form preference is the default until the user picks something.
    private var effectivePreference: ModelPreference {
        switch userSelection {
        case .onDevice: return .preferOnDevice
        case .openAI:   return .preferDeveloperKey
        default:        return preference
        }
    }
}
