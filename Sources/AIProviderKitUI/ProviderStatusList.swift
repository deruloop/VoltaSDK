//
//  ProviderStatusList.swift
//  AIProviderKitUI
//
//  Status list for the providers in the fallback chain.
//  Optional and composable: `ProviderStatusRow` is public, so anyone who
//  wants a different layout can build their own on top of
//  `AIOrchestrator.providerStatuses()`.
//

import SwiftUI
import AIProviderKit

/// Single row: provider name, availability (with reason) and privacy badge.
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
                    Text("Window: \(contextSize.formatted()) tokens")
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

/// Ready-to-use list: queries the orchestrator and shows one row per
/// provider, in the real order of the fallback chain.
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
                Text("Fallback chain")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Refresh provider status")
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if statuses.isEmpty {
                Text("No providers configured")
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
