//
//  ProviderStatusList.swift
//  AIProviderKitUI
//
//  Lista dello stato dei provider nella catena di fallback.
//  Componente opzionale e componibile: `ProviderStatusRow` è pubblica,
//  così chi vuole un layout diverso può costruirselo sopra
//  `AIOrchestrator.providerStatuses()`.
//

import SwiftUI
import AIProviderKit

/// Riga singola: nome provider, disponibilità (con motivo) e badge privacy.
public struct ProviderStatusRow: View {
    private let status: ProviderStatus

    public init(status: ProviderStatus) {
        self.status = status
    }

    public var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isAvailable ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.identifier.rawValue)
                    .font(.body.weight(.medium))
                if case .unavailable(let reason) = status.availability {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let contextSize = status.contextSize {
                    Text("Finestra: \(contextSize.formatted()) token")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            PrivacyLevelBadge(level: status.privacyLevel)
        }
        .padding(.vertical, 2)
    }

    private var isAvailable: Bool {
        status.availability == .available
    }
}

/// Lista pronta all'uso: interroga l'orchestratore e mostra una riga per
/// provider, nell'ordine reale della catena di fallback.
public struct ProviderStatusList: View {
    private let orchestrator: AIOrchestrator
    @State private var statuses: [ProviderStatus] = []
    @State private var isLoading = true

    public init(orchestrator: AIOrchestrator) {
        self.orchestrator = orchestrator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Catena di fallback")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Aggiorna stato provider")
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if statuses.isEmpty {
                Text("Nessun provider configurato")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statuses) { status in
                    ProviderStatusRow(status: status)
                }
            }
        }
        .task(id: ObjectIdentifier(orchestrator)) {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        statuses = await orchestrator.providerStatuses()
        isLoading = false
    }
}
