//
//  PrivacyDisclosure.swift
//  AIProviderKit
//
//  Disclosure dei downgrade di privacy durante il fallback.
//
//  Perché esiste già su iOS 26: con `.preferOnDevice`, un fallimento
//  transitorio del modello on-device rimanda il prompt dell'utente a un
//  provider esterno (OpenAI) in silenzio. È un downgrade di privacy che
//  avviene OGGI, non solo su iOS 27. Il meccanismo è volutamente identico
//  a quello previsto dal design iOS 27 (.silent / .notify /
//  .askOnPrivacyChange), così l'estensione non cambierà l'API.
//
//  Solo lo sviluppatore conosce la sensibilità della propria app:
//  per questo la policy è una scelta di configurazione, non un default rigido.
//

import Foundation

/// Descrive un attraversamento di soglia di privacy: il provider che sta per
/// rispondere opera a un livello più basso del primo provider della catena.
public struct PrivacyDowngrade: Sendable, Equatable {
    /// Il livello del provider preferito (la "promessa" implicita della catena).
    public let from: PrivacyLevel
    /// Il livello del provider che sta per essere usato.
    public let to: PrivacyLevel
    /// Chi sta per ricevere il prompt.
    public let provider: ProviderIdentifier

    public init(from: PrivacyLevel, to: PrivacyLevel, provider: ProviderIdentifier) {
        self.from = from
        self.to = to
        self.provider = provider
    }
}

/// Policy applicata dall'orchestratore quando il fallback attraversa
/// una soglia di privacy verso il basso.
public enum PrivacyDisclosure: Sendable {
    /// Nessuna segnalazione: il fallback è trasparente. Default.
    case silent
    /// Il fallback procede, ma l'handler viene notificato (es. per mostrare
    /// un banner "risposta generata nel cloud"). L'handler è sincrono e
    /// non può bloccare il fallback.
    case notify(@Sendable (PrivacyDowngrade) -> Void)
    /// Il fallback si ferma e chiede: `true` per procedere, `false` per
    /// saltare il provider. Tipicamente collegato a un alert in UI.
    case askOnPrivacyChange(@Sendable (PrivacyDowngrade) async -> Bool)
    /// I provider sotto il livello del primo della catena non vengono mai
    /// usati. Se restano solo loro, `respond` lancia `.privacyRestricted`.
    case denyDowngrade
}
