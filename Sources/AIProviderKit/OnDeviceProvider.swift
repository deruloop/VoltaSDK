//
//  OnDeviceProvider.swift
//  AIProviderKit
//
//  Wrappa il modello on-device di Apple Intelligence (Foundation Models, iOS 26).
//  Nessuna rete, nessuna chiave, privacy massima.
//

import Foundation
import FoundationModels

public struct OnDeviceProvider: ModelProvider {

    public let identifier = ProviderIdentifier.onDevice
    public let privacyLevel = PrivacyLevel.onDevice

    public init() {}

    public func availability() async -> ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Motivo di indisponibilità sconosciuto")
        }
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        // Sessione creata per chiamata (stateless, D12): la storia della
        // conversazione arriva dall'app e viene ricostruita come Transcript
        // nativo di Foundation Models.
        let session = Self.makeSession(instructions: instructions, history: history)

        do {
            let response = try await session.respond(to: prompt)
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch {
            throw ProviderError.generation(String(describing: error))
        }
    }

    /// Costruisce la sessione per la singola chiamata. Senza storia usa gli
    /// init semplici; con storia ricostruisce un `Transcript` nativo, così il
    /// modello vede la conversazione esattamente come se fosse sua.
    private static func makeSession(
        instructions: String?,
        history: [ChatTurn]
    ) -> LanguageModelSession {
        guard !history.isEmpty else {
            if let instructions, !instructions.isEmpty {
                return LanguageModelSession(instructions: instructions)
            }
            return LanguageModelSession()
        }

        var entries: [Transcript.Entry] = []
        if let instructions, !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: instructions))],
                toolDefinitions: []
            )))
        }
        for turn in history {
            switch turn.role {
            case .user:
                entries.append(.prompt(Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            case .assistant:
                entries.append(.response(Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: turn.text))]
                )))
            }
        }
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    /// Mappa gli errori di generazione su ProviderError, distinguendo i casi
    /// recuperabili dal fallback (context window, lingua, rate limit) da
    /// quelli terminali (guardrail: non inoltriamo automaticamente a un
    /// provider esterno contenuto che il sistema ha bloccato).
    private static func map(_ error: LanguageModelSession.GenerationError) -> ProviderError {
        switch error {
        case .exceededContextWindowSize:
            return .contextWindowExceeded
        case .guardrailViolation:
            return .guardrailViolation(error.localizedDescription)
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .rateLimited:
            // Rate limit on-device (es. app in background): il fallback
            // su un provider cloud è legittimo.
            return .rateLimited(retryAfter: nil)
        default:
            return .generation(String(describing: error))
        }
    }

    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "Il dispositivo non supporta Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence non è attivo nelle Impostazioni"
        case .modelNotReady:
            return "Il modello è ancora in download o non pronto"
        @unknown default:
            return "Modello on-device non disponibile"
        }
    }
}
