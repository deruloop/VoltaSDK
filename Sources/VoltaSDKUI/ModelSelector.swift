//
//  ModelSelector.swift
//  VoltaSDKUI
//
//  USER-side model picker, ready to use out of the box.
//
//  Two shapes, the developer's choice at init:
//   - MULTIPLE (`selections: Binding<Set<ProviderIdentifier>>`): the user
//     switches providers on and off, and the set is what the chain may use
//     (`AIConfiguration.enabledProviders`). This is the shape that matches a
//     fallback chain: more than one model is usually in play, and the user
//     decides which ones may answer at all.
//   - SINGLE (`selection: Binding<ProviderIdentifier?>`): one active model,
//     the original shape, for apps that route everything to the user's pick.
//
//  Layout: collapsed by default — a single row showing the current choice(s).
//  Tapping it expands the list of options; in single mode picking one (or an
//  external commit) collapses it again, in multiple mode the list stays open
//  while the user toggles. This scales to any number of providers (iOS 27
//  adds PCC and user-account vendors) without growing the resting footprint.
//
//  Selection is a three-way conversation with the app via `onSelection`:
//   - `.activate`  → commit immediately (on-device is the typical case);
//   - `.deny`      → refuse, with an optional message under the selector;
//   - `.deferred`  → the APP takes over: present a paywall, a settings page,
//     or (iOS 27) a page that runs a provider's OAuth flow. The selector
//     steps aside; when the app's flow succeeds, it commits the choice by
//     setting the `selection` binding — the selector reflects it instantly.
//
//  Initial state — the gate invariant: NOTHING is ever committed without
//  passing through `onSelection`. With an empty binding (nil, or an empty
//  set), the selector auto-selects the available GATE-FREE providers —
//  on-device and Private Cloud Compute (both free, private, no account): the
//  first one in the chain's order in single mode, every one of them in
//  multiple mode — and even that attempt goes through the handler. Gated
//  providers (developer-key, user-account vendors) are NEVER preselected: a
//  developer preference must not look like a user activation when a
//  subscription or OAuth gate sits behind it. A non-empty initial binding
//  (e.g. a persisted user choice) is never overridden. An empty binding
//  therefore means "no model committed yet" — gate your chat on it, or keep
//  gated providers out of the configuration entirely. Switching a provider
//  OFF never asks the handler: the gate guards activation, not withdrawal.
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
        case .privateCloudCompute:
            return ModelSelectorLabel(
                title: "Private Cloud Compute",
                subtitle: "Apple-hosted — private, no account",
                systemImage: "lock.icloud"
            )
        case .openAI, .anthropic, .gemini:
            // One neutral face for any developer-key vendor: no assumptions
            // about the developer's business model.
            return ModelSelectorLabel(
                title: "Cloud model",
                systemImage: "sparkles"
            )
        default:
            // User-account providers (iOS 27): identifiers look like
            // "user-OpenAI". Render a friendly, account-flavoured label.
            if identifier.rawValue.hasPrefix("user-") {
                let vendor = String(identifier.rawValue.dropFirst("user-".count))
                return ModelSelectorLabel(
                    title: "Your \(vendor) account",
                    subtitle: "Signed in — billed to you",
                    systemImage: "person.crop.circle"
                )
            }
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
    private let togglesOff: Bool

    /// - Parameter togglesOff: the row is one of several switches (multiple
    ///   mode): an unselected row shows an empty circle, so it reads as
    ///   something to switch on, not as a missing checkmark.
    public init(
        label: ModelSelectorLabel,
        status: ProviderStatus,
        isSelected: Bool,
        isActivating: Bool,
        togglesOff: Bool = false
    ) {
        self.label = label
        self.status = status
        self.isSelected = isSelected
        self.isActivating = isActivating
        self.togglesOff = togglesOff
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
                    .accessibilityLabel(togglesOff ? "On" : "Selected")
            } else if togglesOff && isAvailable {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Off")
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

    /// Which shape the developer chose: one active model, or a set of
    /// switched-on models. Each carries the app's binding.
    private enum Choice {
        case single(Binding<ProviderIdentifier?>)
        case multiple(Binding<Set<ProviderIdentifier>>)
    }

    private let orchestrator: AIOrchestrator
    private let choice: Choice
    private let labels: [ProviderIdentifier: ModelSelectorLabel]
    private let onSelection: SelectionHandler?
    private let hidesUnavailable: Bool

    @State private var statuses: [ProviderStatus] = []
    @State private var isExpanded = false
    @State private var activatingID: ProviderIdentifier?
    @State private var failureText: String?

    /// Single mode: one active model, committed through `selection`.
    public init(
        orchestrator: AIOrchestrator,
        selection: Binding<ProviderIdentifier?>,
        labels: [ProviderIdentifier: ModelSelectorLabel] = [:],
        hidesUnavailable: Bool = false,
        onSelection: SelectionHandler? = nil
    ) {
        self.orchestrator = orchestrator
        self.choice = .single(selection)
        self.labels = labels
        self.hidesUnavailable = hidesUnavailable
        self.onSelection = onSelection
    }

    /// Multiple mode: the user switches providers on and off; `selections`
    /// is the set the chain may use (hand it to
    /// `AIConfiguration.enabledProviders`). Activation goes through
    /// `onSelection` per provider; switching one off never does.
    public init(
        orchestrator: AIOrchestrator,
        selections: Binding<Set<ProviderIdentifier>>,
        labels: [ProviderIdentifier: ModelSelectorLabel] = [:],
        hidesUnavailable: Bool = false,
        onSelection: SelectionHandler? = nil
    ) {
        self.orchestrator = orchestrator
        self.choice = .multiple(selections)
        self.labels = labels
        self.hidesUnavailable = hidesUnavailable
        self.onSelection = onSelection
    }

    // MARK: The committed choice, read the same way in both modes

    private var isMultiple: Bool {
        if case .multiple = choice { return true }
        return false
    }

    /// Everything committed, in the chain's order (one element at most in single mode).
    private var committed: [ProviderIdentifier] {
        switch choice {
        case .single(let binding):
            return binding.wrappedValue.map { [$0] } ?? []
        case .multiple(let binding):
            let set = binding.wrappedValue
            let ordered = statuses.map(\.identifier).filter(set.contains)
            return ordered.count == set.count ? ordered : ordered + set.subtracting(ordered).sorted { $0.rawValue < $1.rawValue }
        }
    }

    private func isCommitted(_ identifier: ProviderIdentifier) -> Bool {
        switch choice {
        case .single(let binding): return binding.wrappedValue == identifier
        case .multiple(let binding): return binding.wrappedValue.contains(identifier)
        }
    }

    private func commit(_ identifier: ProviderIdentifier) {
        switch choice {
        case .single(let binding): binding.wrappedValue = identifier
        case .multiple(let binding): binding.wrappedValue.insert(identifier)
        }
    }

    private func withdraw(_ identifier: ProviderIdentifier) {
        switch choice {
        case .single(let binding): if binding.wrappedValue == identifier { binding.wrappedValue = nil }
        case .multiple(let binding): binding.wrappedValue.remove(identifier)
        }
    }

    /// A value that changes whenever the committed choice does, for `onChange`.
    private var commitSignature: [String] { committed.map(\.rawValue) }

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
                            isSelected: isCommitted(status.identifier),
                            isActivating: activatingID == status.identifier,
                            togglesOff: isMultiple
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
            // Drop a committed selection the (re)configured chain no longer
            // offers — e.g. the developer disabled that provider — so the
            // header never shows a vanished model as active and auto-select can
            // re-resolve to the next gate-free provider (on-device → PCC).
            for current in committed where !statuses.contains(where: {
                $0.identifier == current && $0.availability == .available
            }) {
                withdraw(current)
            }
            await autoSelectIfNeeded()
        }
        .onChange(of: commitSignature) {
            // Single mode: an external commit (e.g. the app's paywall/OAuth
            // flow setting the binding) closes the list and shows the new
            // active row. Multiple mode keeps the list open: the user is
            // switching several on and off in one go.
            if !isMultiple { withAnimation { isExpanded = false } }
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
                } else if let first = committed.first {
                    Image(systemName: committed.count == 1 ? label(for: first).systemImage : "square.stack.3d.up")
                        .frame(width: 22)
                        .foregroundStyle(Color.accentColor)
                    Text(headerTitle)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Active")
                } else {
                    Image(systemName: "cpu")
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    Text(isMultiple ? "Choose your models" : "Choose a model")
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
            committed.isEmpty ? (isMultiple ? "Choose your models" : "Choose a model")
                : "Active: \(committed.map { label(for: $0).title }.joined(separator: ", "))"
        )
        .accessibilityHint("Shows the available models")
    }

    /// The resting line: one name, two names joined, or a count beyond that.
    private var headerTitle: String {
        let titles = committed.map { label(for: $0).title }
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        case 2: return "\(titles[0]) + \(titles[1])"
        default: return "\(titles.count) models"
        }
    }

    /// Identifiers that carry no app-side business gate (no account, no
    /// subscription, no OAuth): on-device and Private Cloud Compute, both free
    /// and private. These are the only providers eligible for auto-selection —
    /// developer-key and user-account vendors typically hide a gate that only
    /// the app can clear, so they are never preselected.
    private func isGateFree(_ identifier: ProviderIdentifier) -> Bool {
        identifier == .onDevice || identifier == .privateCloudCompute
    }

    /// Auto-selects the available **gate-free** providers when the app hasn't
    /// committed anything yet: in single mode the first one in the chain's
    /// preference order (so on-device wins when present, and Private Cloud
    /// Compute steps in when on-device is off/unavailable), in multiple mode
    /// every one of them, since the chain uses them all. Gated providers are
    /// never candidates. Even this attempt passes through `onSelection`,
    /// keeping the invariant that nothing commits without the gate's consent;
    /// `.deny`/`.deferred` leave that provider off without showing a failure
    /// (it wasn't a user action). When no gate-free provider is available,
    /// nothing is selected and the header shows the prompt.
    private func autoSelectIfNeeded() async {
        guard committed.isEmpty, activatingID == nil else { return }
        let candidates = statuses.filter { isGateFree($0.identifier) && $0.availability == .available }.map(\.identifier)
        for identifier in (isMultiple ? candidates : Array(candidates.prefix(1))) {
            guard let onSelection else {
                commit(identifier)
                continue
            }
            activatingID = identifier
            if case .activate = await onSelection(identifier) {
                commit(identifier)
            }
            activatingID = nil
        }
    }

    private func select(_ status: ProviderStatus) {
        let identifier = status.identifier
        guard activatingID == nil else { return }
        if isCommitted(identifier) {
            // Single mode: tapping the active model just closes the list.
            // Multiple mode: it switches that model off; no gate for that.
            if isMultiple { withdraw(identifier) } else { withAnimation { isExpanded = false } }
            return
        }
        failureText = nil

        // No handler attached: selections commit immediately.
        guard let onSelection else {
            commit(identifier)
            if !isMultiple { withAnimation { isExpanded = false } }
            return
        }

        activatingID = identifier
        Task { @MainActor in
            let response = await onSelection(identifier)
            switch response {
            case .activate:
                commit(identifier)
                if !isMultiple { withAnimation { isExpanded = false } }
            case .deny(let message):
                failureText = message ?? "\(label(for: identifier).title) couldn't be activated."
            case .deferred:
                // The app is presenting its own flow; it will commit by
                // setting the binding when (and if) it succeeds.
                if !isMultiple { withAnimation { isExpanded = false } }
            }
            activatingID = nil
        }
    }
}
