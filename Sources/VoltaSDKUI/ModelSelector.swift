//
//  ModelSelector.swift
//  VoltaSDKUI
//
//  USER-side model picker, ready to use out of the box.
//
//  Layout: collapsed by default — a single row showing the current choice.
//  Tapping it expands the list of options; picking one (or an external
//  commit) collapses it again. This scales to any number of providers
//  (iOS 27 adds PCC and user-account vendors) without growing the resting
//  footprint.
//
//  Selection is a three-way conversation with the app via `onSelection`:
//   - `.activate`  → commit immediately (on-device is the typical case);
//   - `.deny`      → refuse, with an optional message under the selector;
//   - `.deferred`  → the APP takes over: present a paywall, a settings page,
//     or (iOS 27) a page that runs a provider's OAuth flow. The selector
//     steps aside; when the app's flow succeeds, it commits the choice by
//     setting the `selection` binding — the selector reflects it instantly.
//
//  Customization:
//   - `labels:` overrides title/subtitle/icon per provider. The defaults
//     make NO business assumptions (no "included with subscription" claims —
//     only the developer knows their model); brand the rows via labels.
//   - `hidesUnavailable` flag; standard SwiftUI modifiers (.tint, .font, …).
//   - `ModelSelectorRow` is public: recompose your own layout on top of
//     `providerStatuses()` if you need full design control.
//

import SwiftUI
import VoltaSDK

// MARK: - Selection response

/// What the app decides when the user taps an option.
public enum ModelSelectionResponse: Sendable {
    /// Commit the selection immediately.
    case activate
    /// Refuse the selection. The optional message is shown under the
    /// selector; pass `nil` for a generic one.
    case deny(message: String? = nil)
    /// The app is taking over with its own flow (paywall, OAuth page, …).
    /// The selector does nothing now; commit later by setting the
    /// `selection` binding from your flow.
    case deferred
}

// MARK: - Labels

/// Display metadata for one selectable provider. Defaults are deliberately
/// neutral — brand the options (e.g. "Included with Premium") via `labels:`.
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
            // One neutral face for any developer-key vendor: no assumptions
            // about the developer's business model.
            return ModelSelectorLabel(
                title: "Cloud model",
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
        .opacity(isAvailable ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

// MARK: - Selector

/// Ready-to-use user-side selector. Collapsed it occupies a single row;
/// on iOS 27 new providers (PCC, user-account vendors) appear in the
/// expanded list automatically once configured, and their custom flows
/// (OAuth pages) attach through the same `onSelection` hook via `.deferred`.
public struct ModelSelector: View {
    public typealias SelectionHandler =
        @MainActor (ProviderIdentifier) async -> ModelSelectionResponse

    private let orchestrator: AIOrchestrator
    @Binding private var selection: ProviderIdentifier?
    private let labels: [ProviderIdentifier: ModelSelectorLabel]
    private let onSelection: SelectionHandler?
    private let hidesUnavailable: Bool

    @State private var statuses: [ProviderStatus] = []
    @State private var isExpanded = false
    @State private var activatingID: ProviderIdentifier?
    @State private var failureText: String?

    public init(
        orchestrator: AIOrchestrator,
        selection: Binding<ProviderIdentifier?>,
        labels: [ProviderIdentifier: ModelSelectorLabel] = [:],
        hidesUnavailable: Bool = false,
        onSelection: SelectionHandler? = nil
    ) {
        self.orchestrator = orchestrator
        self._selection = selection
        self.labels = labels
        self.hidesUnavailable = hidesUnavailable
        self.onSelection = onSelection
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
        VStack(alignment: .leading, spacing: 4) {
            collapsedHeader

            if isExpanded {
                Divider()
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
            }

            if let failureText {
                Text(failureText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(6)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .task(id: ObjectIdentifier(orchestrator)) {
            statuses = await orchestrator.providerStatuses()
        }
        .onChange(of: selection) {
            // External commits (e.g. the app's paywall/OAuth flow setting
            // the binding) close the list and show the new active row.
            withAnimation { isExpanded = false }
        }
    }

    /// The resting state: one row showing the active choice (or a prompt),
    /// tappable to expand the options.
    private var collapsedHeader: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                if let activatingID {
                    ProgressView().controlSize(.small)
                    Text("Activating \(label(for: activatingID).title)…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else if let selection {
                    Image(systemName: label(for: selection).systemImage)
                        .frame(width: 22)
                        .foregroundStyle(Color.accentColor)
                    Text(label(for: selection).title)
                        .font(.body.weight(.semibold))
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Active")
                } else {
                    Image(systemName: "cpu")
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    Text("Choose a model")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            selection.map { "Active model: \(label(for: $0).title)" } ?? "Choose a model"
        )
        .accessibilityHint("Shows the available models")
    }

    private func select(_ status: ProviderStatus) {
        let identifier = status.identifier
        guard activatingID == nil else { return }
        if identifier == selection {
            withAnimation { isExpanded = false }
            return
        }
        failureText = nil

        // No handler attached: selections commit immediately.
        guard let onSelection else {
            selection = identifier
            withAnimation { isExpanded = false }
            return
        }

        activatingID = identifier
        Task { @MainActor in
            let response = await onSelection(identifier)
            switch response {
            case .activate:
                selection = identifier
                withAnimation { isExpanded = false }
            case .deny(let message):
                failureText = message ?? "\(label(for: identifier).title) couldn't be activated."
            case .deferred:
                // The app is presenting its own flow; it will commit by
                // setting the `selection` binding when (and if) it succeeds.
                withAnimation { isExpanded = false }
            }
            activatingID = nil
        }
    }
}
