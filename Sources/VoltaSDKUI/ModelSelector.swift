//
//  ModelSelector.swift
//  VoltaSDKUI
//
//  USER-side model picker, ready to use out of the box.
//
//  The developer decides which providers exist (configuration); this view
//  lets the END USER choose which one leads the chain. The options shown
//  derive from the orchestrator's real state, so a provider the developer
//  didn't configure never appears, and an unavailable one shows its reason.
//
//  Activation gating: selecting a row can be subject to developer logic via
//  the `activation` handler — e.g. on-device activates immediately (return
//  true), the cloud model requires an active subscription (run a paywall,
//  then return the outcome), and on iOS 27 user-account providers will run
//  their OAuth flow in the same hook. While the handler runs, the row shows
//  a spinner and the active badge says "Activating…"; the selection only
//  commits when the handler returns true.
//
//  Customization:
//   - `labels:` overrides title/subtitle/icon per provider (e.g. brand the
//     developer-key row as "Included with Premium").
//   - `showsActiveBadge` / `hidesUnavailable` flags.
//   - `ModelSelectorRow` is public: recompose your own layout on top of
//     `providerStatuses()` if you need full design control.
//   - Standard SwiftUI modifiers (.tint, .font, …) apply.
//

import SwiftUI
import VoltaSDK

// MARK: - Labels

/// Display metadata for one selectable provider. Defaults are provided;
/// override per provider to brand the options (see D4: the developer key
/// should read as "included with the app", not as an API key).
public struct ModelSelectorLabel: Sendable {
    public let title: String
    public let subtitle: String?
    public let systemImage: String

    public init(title: String, subtitle: String? = nil, systemImage: String = "cpu") {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    static func `default`(for identifier: ProviderIdentifier) -> ModelSelectorLabel {
        switch identifier {
        case .onDevice:
            return ModelSelectorLabel(
                title: "On device",
                subtitle: "Private — runs entirely on this device",
                systemImage: "iphone"
            )
        case .openAI, .anthropic, .gemini:
            // All developer-key vendors read as the same user-facing option:
            // a cloud model included with the app (D4) — the vendor is an
            // implementation detail unless the developer brands it.
            return ModelSelectorLabel(
                title: "Cloud model",
                subtitle: "Included with your subscription",
                systemImage: "sparkles"
            )
        default:
            return ModelSelectorLabel(title: identifier.rawValue, systemImage: "globe")
        }
    }
}

// MARK: - Row

/// A single selectable option. Public so developers can recompose the
/// selector with their own container/layout.
public struct ModelSelectorRow: View {
    private let label: ModelSelectorLabel
    private let status: ProviderStatus
    private let isSelected: Bool
    private let isActivating: Bool

    public init(
        label: ModelSelectorLabel,
        status: ProviderStatus,
        isSelected: Bool,
        isActivating: Bool
    ) {
        self.label = label
        self.status = status
        self.isSelected = isSelected
        self.isActivating = isActivating
    }

    private var isAvailable: Bool { status.availability == .available }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: label.systemImage)
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.title)
                    .font(.body.weight(isSelected ? .semibold : .regular))
                if let subtitle = label.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .unavailable(let reason) = status.availability {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            PrivacyLevelBadge(level: status.privacyLevel, showsLabel: false)
            if isActivating {
                ProgressView().controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Selected")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .opacity(isAvailable ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

// MARK: - Selector

/// Ready-to-use user-side selector. On iOS 26 the options are on-device and
/// the developer-key model; on iOS 27 the new providers (PCC, Gemini,
/// Claude, …) will appear automatically once configured, and their OAuth
/// flows attach through the same `activation` hook.
public struct ModelSelector: View {
    /// Developer gate run before committing a selection. Return `true` to
    /// activate the option, `false` to reject it (e.g. paywall dismissed,
    /// OAuth cancelled). Rows without blocking logic should just return
    /// `true` — that's why on-device activates immediately.
    public typealias ActivationHandler = @Sendable (ProviderIdentifier) async -> Bool

    private let orchestrator: AIOrchestrator
    @Binding private var selection: ProviderIdentifier?
    private let labels: [ProviderIdentifier: ModelSelectorLabel]
    private let activation: ActivationHandler?
    private let showsActiveBadge: Bool
    private let hidesUnavailable: Bool

    @State private var statuses: [ProviderStatus] = []
    @State private var activatingID: ProviderIdentifier?
    @State private var failureText: String?

    public init(
        orchestrator: AIOrchestrator,
        selection: Binding<ProviderIdentifier?>,
        labels: [ProviderIdentifier: ModelSelectorLabel] = [:],
        activation: ActivationHandler? = nil,
        showsActiveBadge: Bool = true,
        hidesUnavailable: Bool = false
    ) {
        self.orchestrator = orchestrator
        self._selection = selection
        self.labels = labels
        self.activation = activation
        self.showsActiveBadge = showsActiveBadge
        self.hidesUnavailable = hidesUnavailable
    }

    private func label(for identifier: ProviderIdentifier) -> ModelSelectorLabel {
        labels[identifier] ?? .default(for: identifier)
    }

    private var visibleStatuses: [ProviderStatus] {
        hidesUnavailable
            ? statuses.filter { $0.availability == .available }
            : statuses
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsActiveBadge {
                activeBadge
            }
            ForEach(visibleStatuses) { status in
                Button {
                    select(status)
                } label: {
                    ModelSelectorRow(
                        label: label(for: status.identifier),
                        status: status,
                        isSelected: selection == status.identifier,
                        isActivating: activatingID == status.identifier
                    )
                }
                .buttonStyle(.plain)
                .disabled(status.availability != .available || activatingID != nil)
            }
            if let failureText {
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: ObjectIdentifier(orchestrator)) {
            statuses = await orchestrator.providerStatuses()
        }
    }

    /// The confirmation element: tells the user which preference is active
    /// right now (selection only commits after the activation gate passes).
    @ViewBuilder
    private var activeBadge: some View {
        HStack(spacing: 6) {
            if let activatingID {
                ProgressView().controlSize(.small)
                Text("Activating \(label(for: activatingID).title)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let selection {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("Active: \(label(for: selection).title)")
                    .font(.caption.weight(.medium))
            } else {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                Text("No model selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func select(_ status: ProviderStatus) {
        let identifier = status.identifier
        guard identifier != selection, activatingID == nil else { return }
        failureText = nil

        // No gate attached: the selection commits immediately.
        guard let activation else {
            selection = identifier
            return
        }

        activatingID = identifier
        Task {
            let approved = await activation(identifier)
            if approved {
                selection = identifier
            } else {
                failureText = "\(label(for: identifier).title) couldn't be activated."
            }
            activatingID = nil
        }
    }
}
