//
//  DemoRootView.swift
//  AIProviderKitDemoUI
//
//  La UI di prova condivisa tra la demo macOS (`swift run AIProviderKitDemo`)
//  e la app demo iOS (Examples/iOSDemo). Stessa logica su entrambe le
//  piattaforme: configurazione live, stato della catena di fallback (con i
//  motivi di indisponibilità, es. device senza Apple Intelligence),
//  playground con provenienza della risposta e log dei downgrade di privacy.
//
//  Layout adattivo:
//   - macOS: HSplitView (configurazione | playground)
//   - iOS:   TabView (Configura / Playground)
//

import SwiftUI
import AIProviderKit
import AIProviderKitUI

/// Eventi di downgrade di privacy raccolti dalla policy `.notify`,
/// per renderli visibili nella UI di test.
@MainActor @Observable
final class DowngradeLog {
    var events: [String] = []
}

public struct DemoRootView: View {
    // Configurazione editabile (ricrea l'orchestratore su "Applica").
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

    // MARK: Layout per piattaforma

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
            Tab("Configura", systemImage: "gearshape") {
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

    // MARK: Pannelli

    private var configurationForm: some View {
        Form {
            Section("Provider") {
                Toggle("Modello on-device", isOn: $enableOnDevice)
                SecureField("OpenAI API key", text: $apiKey)
                    .textContentType(.password)
                TextField("Modello developer key", text: $model)
                    .autocorrectionDisabled()
                Picker("Preferenza", selection: $preference) {
                    Text("Prima on-device").tag(ModelPreference.preferOnDevice)
                    Text("Prima developer key").tag(ModelPreference.preferDeveloperKey)
                    Text("Solo on-device").tag(ModelPreference.onDeviceOnly)
                    Text("Solo developer key").tag(ModelPreference.developerKeyOnly)
                }
            }
            Section("Privacy") {
                Toggle("Notifica downgrade di privacy", isOn: $notifyDowngrades)
                if !downgradeLog.events.isEmpty {
                    ForEach(downgradeLog.events.indices, id: \.self) { index in
                        Text(downgradeLog.events[index])
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                Button("Applica configurazione") { applyConfiguration() }
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
            placeholder: "Prova un prompt (es. \"Pianifica un weekend a Roma\")"
        )
        .padding()
    }

    // MARK: Configurazione

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
