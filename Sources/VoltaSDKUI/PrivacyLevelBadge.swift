//
//  PrivacyLevelBadge.swift
//  VoltaSDKUI
//
//  Compact badge communicating where the data is processed.
//  Optional component: the core never depends on SwiftUI.
//

import SwiftUI
import VoltaSDK

/// Badge for a `PrivacyLevel` (icon + label). Customizable via the standard
/// `tint(_:)`/`font(_:)` modifiers; for a fully custom look the developer
/// can ignore it and use `PrivacyLevel` directly.
public struct PrivacyLevelBadge: View {
    private let level: PrivacyLevel
    private let showsLabel: Bool

    public init(level: PrivacyLevel, showsLabel: Bool = true) {
        self.level = level
        self.showsLabel = showsLabel
    }

    public var body: some View {
        Label {
            if showsLabel { Text(label) }
        } icon: {
            Image(systemName: symbol)
        }
        .font(.caption)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityLabel(label)
    }

    private var label: String {
        switch level {
        case .onDevice:   return "On device"
        case .appleCloud: return "Private Cloud Compute"
        case .external:   return "External provider"
        }
    }

    private var symbol: String {
        switch level {
        case .onDevice:   return "iphone"
        case .appleCloud: return "lock.icloud"
        case .external:   return "globe"
        }
    }

    private var color: Color {
        switch level {
        case .onDevice:   return .green
        case .appleCloud: return .blue
        case .external:   return .orange
        }
    }
}
