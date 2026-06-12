//
//  ModelProvider.swift
//  AIProviderKit
//
//  Il protocollo comune a tutti i provider di modelli.
//  È l'evoluzione di `ChatGptRepository`: stessa idea (interfaccia + mock),
//  ma astratta dal singolo provider così da poter ospitare on-device,
//  developer key, e in futuro (iOS 27) PCC, Gemini, Claude.
//

import Foundation

// MARK: - Identità del provider

/// Identificatore estensibile di un provider.
/// Volutamente non è un enum chiuso: nuovi provider (pcc, gemini, claude)
/// si aggiungono senza rompere il codice esistente.
public struct ProviderIdentifier: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let onDevice = ProviderIdentifier("on-device")
    public static let openAI   = ProviderIdentifier("openai")
    // iOS 27: .privateCloudCompute, .gemini, .claude
}

// MARK: - Livello di privacy

/// Quanto "lontano" dai dati dell'utente opera un provider.
/// È comparabile perché l'orchestratore lo usa già su iOS 26 per rilevare
/// i downgrade di privacy durante il fallback (vedi `PrivacyDisclosure`).
public enum PrivacyLevel: Int, Sendable, Comparable {
    case external   = 0   // i dati escono verso un provider terzo (es. OpenAI dev key)
    case appleCloud = 1   // Private Cloud Compute (iOS 27)
    case onDevice   = 2   // non lascia mai il dispositivo

    public static func < (lhs: PrivacyLevel, rhs: PrivacyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Disponibilità

public enum ProviderAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Fotografia dello stato di un provider, in ordine di preferenza.
/// Pensata per UI (picker, diagnostica) ma indipendente da SwiftUI.
public struct ProviderStatus: Sendable, Identifiable {
    public let identifier: ProviderIdentifier
    public let privacyLevel: PrivacyLevel
    public let availability: ProviderAvailability

    public var id: ProviderIdentifier { identifier }

    public init(
        identifier: ProviderIdentifier,
        privacyLevel: PrivacyLevel,
        availability: ProviderAvailability
    ) {
        self.identifier = identifier
        self.privacyLevel = privacyLevel
        self.availability = availability
    }
}

// MARK: - Errori tipizzati

/// Rimpiazza il `return nil` del manager originale: ogni fallimento porta con sé
/// la sua causa, così l'orchestratore può decidere se fare fallback o fermarsi.
public enum ProviderError: Error, Sendable, Equatable {
    /// Quota/limite raggiunto (HTTP 429, o rate limit on-device in background).
    /// Causa principale di fallback al provider successivo.
    case rateLimited(retryAfter: TimeInterval?)
    /// Chiave errata o mancante (HTTP 401/403). Terminale: inutile riprovare.
    case unauthorized
    /// Problema di rete. Candidato a retry o fallback.
    case network(code: Int)
    /// Risposta vuota dal server.
    case emptyResponse
    /// Errore di encoding della richiesta (lato client, prima della rete).
    case encoding(String)
    /// Errore di decodifica della risposta.
    case decoding(String)
    /// Errore applicativo restituito dall'API del provider.
    case api(message: String, code: String?)
    /// Il prompt supera la finestra di contesto del modello.
    /// Recuperabile: un provider successivo può avere una finestra più ampia.
    case contextWindowExceeded
    /// Guardrail di sicurezza scattato (on-device). Terminale per scelta:
    /// inoltrare automaticamente a un provider esterno contenuto che Apple
    /// considera non sicuro sarebbe un downgrade di privacy non richiesto.
    case guardrailViolation(String)
    /// Lingua/locale non supportati dal modello. Recuperabile: i modelli
    /// cloud coprono più lingue del modello on-device.
    case unsupportedLanguage
    /// Altro errore di generazione on-device non mappato.
    case generation(String)
    /// Nessun provider utilizzabile in questo momento.
    case noProviderAvailable
    /// Tutti i provider rimasti sono stati esclusi dalla policy di privacy
    /// (`.denyDowngrade` o `.askOnPrivacyChange` rifiutato).
    case privacyRestricted
    /// Operazione annullata.
    case cancelled

    /// Indica se l'errore consente di provare il provider successivo nella catena.
    /// (Su iOS 27 questa stessa proprietà guiderà il fallback runtime con le quote PCC.)
    public var isRecoverableByFallback: Bool {
        switch self {
        case .rateLimited, .network, .contextWindowExceeded,
             .unsupportedLanguage, .noProviderAvailable:
            return true
        case .unauthorized, .emptyResponse, .encoding, .decoding, .api,
             .guardrailViolation, .generation, .privacyRestricted, .cancelled:
            return false
        }
    }
}

// MARK: - Protocollo provider

public protocol ModelProvider: Sendable {
    var identifier: ProviderIdentifier { get }
    var privacyLevel: PrivacyLevel { get }

    /// Controllo a runtime: il provider è utilizzabile ora?
    /// (On-device → Apple Intelligence presente/attivo/pronto.
    ///  Developer key → chiave configurata. iOS 27 → anche quota residua.)
    func availability() async -> ProviderAvailability

    /// Risposta non-streaming. Firma stabile: resterà identica su iOS 27.
    ///
    /// `history` sono i turni precedenti della conversazione, forniti
    /// dall'app (D12): il provider non ricorda nulla tra una chiamata e
    /// l'altra, ma ogni chiamata è autocontenuta e può quindi essere
    /// servita da qualsiasi provider della catena di fallback.
    func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String
}

public extension ModelProvider {
    /// Convenience per la chiamata one-shot (senza conversazione).
    func respond(to prompt: String, instructions: String?) async throws -> String {
        try await respond(to: prompt, instructions: instructions, history: [])
    }
}
