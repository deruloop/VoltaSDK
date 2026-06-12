//
//  PrivacyLevelBadge.swift
//  AIProviderKitUI
//
//  Badge compatto che comunica dove vengono elaborati i dati.
//  Componente opzionale: il core non dipende mai da SwiftUI.
//

import SwiftUI
import AIProviderKit

/// Badge per un `PrivacyLevel` (icona + etichetta). Personalizzabile via
/// `tint(_:)`/`font(_:)` standard; per un look completamente custom lo
/// sviluppatore può ignorarlo e usare direttamente `PrivacyLevel`.
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
        case .onDevice:   return "Sul dispositivo"
        case .appleCloud: return "Private Cloud Compute"
        case .external:   return "Provider esterno"
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
