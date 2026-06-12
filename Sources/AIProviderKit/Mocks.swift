//
//  Mocks.swift
//  AIProviderKit
//
//  Eredita il pattern del ChatGptManagerMock originale, generalizzato.
//  Permette di testare l'orchestratore e il fallback senza rete né device reale.
//

import Foundation

/// Provider finto con esito configurabile. Copre sia successo che fallimento,
/// così da poter testare la catena di fallback (es. un provider che restituisce
/// .rateLimited e uno che risponde correttamente subito dopo).
public struct MockProvider: ModelProvider {

    public let identifier: ProviderIdentifier
    public let privacyLevel: PrivacyLevel

    private let availabilityResult: ProviderAvailability
    private let outcome: Result<String, ProviderError>
    private let onRespond: (@Sendable (_ prompt: String, _ instructions: String?, _ history: [ChatTurn]) -> Void)?

    public init(
        identifier: ProviderIdentifier,
        privacyLevel: PrivacyLevel = .onDevice,
        availability: ProviderAvailability = .available,
        outcome: Result<String, ProviderError> = .success(""),
        onRespond: (@Sendable (_ prompt: String, _ instructions: String?, _ history: [ChatTurn]) -> Void)? = nil
    ) {
        self.identifier = identifier
        self.privacyLevel = privacyLevel
        self.availabilityResult = availability
        self.outcome = outcome
        self.onRespond = onRespond
    }

    public func availability() async -> ProviderAvailability {
        availabilityResult
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        onRespond?(prompt, instructions, history)
        switch outcome {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        }
    }
}
