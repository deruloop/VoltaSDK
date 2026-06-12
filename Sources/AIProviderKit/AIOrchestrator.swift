//
//  AIOrchestrator.swift
//  AIProviderKit
//
//  L'orchestratore e l'API pubblica stabile.
//  Su iOS 26 risolve tra due provider (on-device + developer key) con
//  fallback automatico e disclosure di privacy. La stessa superficie
//  pubblica reggerà su iOS 27, dove si aggiungeranno PCC, provider utente
//  e la catena per-bisogno (.lightweight / .reasoning / .largeContext).
//
//  Nota sul nome: il tipo NON si chiama come il modulo (AIProviderKit)
//  perché in Swift un tipo che oscura il proprio modulo rende impossibile
//  qualificare gli altri simboli (`AIProviderKit.Xyz` risolverebbe sempre
//  il tipo, mai il modulo). "Orchestrator" riflette anche il valore reale
//  del framework: risoluzione del modello, non esecuzione di agenti.
//

import Foundation
import Synchronization

// MARK: - Preferenza di selezione

/// Forma embrionale del fallback. Su iOS 27 diventerà una catena più ricca
/// (per-bisogno: .lightweight / .reasoning / .largeContext, con quote PCC).
public enum ModelPreference: Sendable, CaseIterable {
    /// On-device se disponibile, altrimenti developer key. Default sensato.
    case preferOnDevice
    /// Developer key per prima, on-device come rete di sicurezza.
    case preferDeveloperKey
    /// Solo on-device. Se non disponibile, errore.
    case onDeviceOnly
    /// Solo developer key.
    case developerKeyOnly
}

// MARK: - Configurazione

public struct AIConfiguration: Sendable {
    /// Abilita il modello on-device (richiede Apple Intelligence sul device).
    public var enableOnDevice: Bool = true

    /// Developer key del provider cloud (es. OpenAI). Iniettata dall'app,
    /// tipicamente da un secret Xcode. Se nil, il provider cloud non è creato.
    public var developerKey: String? = nil

    /// Modello da usare con la developer key.
    public var developerKeyModel: String = "gpt-4o-mini"

    public var maxTokens: Int = 1000
    public var temperature: Double = 0.3

    /// Ordine di preferenza on-device vs developer key.
    public var preference: ModelPreference = .preferOnDevice

    /// Cosa fare quando il fallback attraversa una soglia di privacy
    /// verso il basso (es. on-device → OpenAI). Vedi `PrivacyDisclosure`.
    public var privacyDisclosure: PrivacyDisclosure = .silent

    public init() {}
}

// MARK: - Risposta dettagliata

/// Risposta arricchita con la provenienza: indispensabile per UI che vogliono
/// mostrare quale modello ha risposto e a quale livello di privacy.
public struct AIResponse: Sendable {
    public let text: String
    public let provider: ProviderIdentifier
    public let privacyLevel: PrivacyLevel
}

// MARK: - Orchestratore

/// È un actor anche se oggi il suo stato è immutabile: le estensioni già
/// pianificate (tracking quote PCC, cache di sessione multi-turno) avranno
/// bisogno di stato mutabile protetto.
public actor AIOrchestrator {

    private let orderedProviders: [any ModelProvider]
    private let privacyDisclosure: PrivacyDisclosure

    // MARK: Init esplicito (consigliato: nessuno stato globale)

    public init(configuration: AIConfiguration) {
        self.orderedProviders = Self.buildProviders(from: configuration)
        self.privacyDisclosure = configuration.privacyDisclosure
    }

    /// Init diretto con provider già costruiti — utile per i test o per
    /// inserire provider custom.
    public init(
        providers: [any ModelProvider],
        privacyDisclosure: PrivacyDisclosure = .silent
    ) {
        self.orderedProviders = providers
        self.privacyDisclosure = privacyDisclosure
    }

    // MARK: Singleton opzionale per comodità

    public static let shared = AIOrchestrator(configuration: AIConfiguration())

    /// Override configurato dall'app. Mutex perché in Swift 6 una
    /// `static var` non isolata non è concurrency-safe.
    private static let _sharedOverride = Mutex<AIOrchestrator?>(nil)

    /// Configura l'istanza condivisa. Da chiamare una volta all'avvio dell'app.
    /// Esempio:
    /// ```
    /// AIOrchestrator.configure {
    ///     $0.enableOnDevice = true
    ///     $0.developerKey = Secrets.openAIKey
    ///     $0.developerKeyModel = "gpt-4o-mini"
    ///     $0.preference = .preferOnDevice
    /// }
    /// ```
    public static func configure(_ build: (inout AIConfiguration) -> Void) {
        var config = AIConfiguration()
        build(&config)
        let orchestrator = AIOrchestrator(configuration: config)
        _sharedOverride.withLock { $0 = orchestrator }
    }

    /// L'istanza attiva (override configurato, altrimenti il default).
    public static var active: AIOrchestrator {
        _sharedOverride.withLock { $0 } ?? shared
    }

    // MARK: API principale

    /// Genera una risposta usando il miglior provider disponibile secondo la
    /// preferenza, con fallback automatico sui provider successivi quando il
    /// primo è indisponibile o fallisce in modo recuperabile (429, rete,
    /// context window, lingua). Firma stabile: identica su iOS 27.
    public func respond(to prompt: String, instructions: String? = nil) async throws -> String {
        try await respondDetailed(to: prompt, instructions: instructions).text
    }

    /// Come `respond`, ma restituisce anche quale provider ha risposto e il
    /// suo livello di privacy (per banner/badge in UI).
    public func respondDetailed(
        to prompt: String,
        instructions: String? = nil
    ) async throws -> AIResponse {
        guard let first = orderedProviders.first else {
            throw ProviderError.noProviderAvailable
        }

        // La "promessa" di privacy della catena è il livello del provider
        // preferito: scendere sotto questo livello è un downgrade.
        let baseline = first.privacyLevel
        var lastError: ProviderError = .noProviderAvailable

        for provider in orderedProviders {
            // Salta i provider non disponibili senza nemmeno tentare.
            if case .unavailable = await provider.availability() {
                continue
            }

            // Gate di privacy: si applica prima di inviare qualsiasi dato.
            if provider.privacyLevel < baseline {
                let downgrade = PrivacyDowngrade(
                    from: baseline,
                    to: provider.privacyLevel,
                    provider: provider.identifier
                )
                switch privacyDisclosure {
                case .silent:
                    break
                case .notify(let handler):
                    handler(downgrade)
                case .askOnPrivacyChange(let handler):
                    guard await handler(downgrade) else {
                        lastError = .privacyRestricted
                        continue
                    }
                case .denyDowngrade:
                    lastError = .privacyRestricted
                    continue
                }
            }

            do {
                let text = try await provider.respond(to: prompt, instructions: instructions)
                return AIResponse(
                    text: text,
                    provider: provider.identifier,
                    privacyLevel: provider.privacyLevel
                )
            } catch let error as ProviderError {
                lastError = error
                if error.isRecoverableByFallback {
                    continue        // prova il provider successivo
                }
                throw error         // errore terminale (auth, guardrail, decoding, ...)
            }
        }

        throw lastError
    }

    // MARK: Risoluzione (il primitivo, non la convenience)

    /// Restituisce il primo provider disponibile della catena SENZA eseguire
    /// nulla. È il primitivo di "risoluzione del modello" — il valore centrale
    /// del framework. Su iOS 27 evolverà in `preferred(_ need:)`, che
    /// restituirà un `LanguageModel` da passare a un Dynamic Profile nativo.
    ///
    /// Nota: applica solo la disponibilità, non la disclosure interattiva
    /// (.askOnPrivacyChange ha senso solo nel ciclo di `respond`). Con
    /// `.denyDowngrade` i provider sotto soglia vengono però esclusi.
    public func resolveProvider() async throws -> any ModelProvider {
        guard let first = orderedProviders.first else {
            throw ProviderError.noProviderAvailable
        }
        let baseline = first.privacyLevel

        for provider in orderedProviders {
            if case .unavailable = await provider.availability() {
                continue
            }
            if case .denyDowngrade = privacyDisclosure,
               provider.privacyLevel < baseline {
                continue
            }
            return provider
        }
        throw ProviderError.noProviderAvailable
    }

    // MARK: Introspezione (per UI e diagnostica)

    /// I provider attualmente utilizzabili, in ordine di preferenza.
    public func availableProviders() async -> [ProviderIdentifier] {
        var result: [ProviderIdentifier] = []
        for provider in orderedProviders {
            if case .available = await provider.availability() {
                result.append(provider.identifier)
            }
        }
        return result
    }

    /// Stato completo di tutti i provider della catena (anche quelli
    /// indisponibili, con il motivo). Pensato per UI tipo picker/diagnostica.
    public func providerStatuses() async -> [ProviderStatus] {
        var result: [ProviderStatus] = []
        for provider in orderedProviders {
            result.append(ProviderStatus(
                identifier: provider.identifier,
                privacyLevel: provider.privacyLevel,
                availability: await provider.availability()
            ))
        }
        return result
    }

    // MARK: Costruzione provider

    private static func buildProviders(from config: AIConfiguration) -> [any ModelProvider] {
        let onDevice: (any ModelProvider)? = config.enableOnDevice ? OnDeviceProvider() : nil

        let openAI: (any ModelProvider)? = {
            guard let key = config.developerKey, !key.isEmpty else { return nil }
            return OpenAIProvider(
                apiKey: key,
                model: config.developerKeyModel,
                maxTokens: config.maxTokens,
                temperature: config.temperature
            )
        }()

        switch config.preference {
        case .preferOnDevice:
            return [onDevice, openAI].compactMap { $0 }
        case .preferDeveloperKey:
            return [openAI, onDevice].compactMap { $0 }
        case .onDeviceOnly:
            return [onDevice].compactMap { $0 }
        case .developerKeyOnly:
            return [openAI].compactMap { $0 }
        }
    }
}
