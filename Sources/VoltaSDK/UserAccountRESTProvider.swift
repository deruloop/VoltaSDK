//
//  UserAccountRESTProvider.swift
//  VoltaSDK
//
//  The pre-iOS 27 path for user accounts (D19): the user's key drives the
//  same vendor REST client the developer key uses, so "the user pays" works
//  from iOS 18. On iOS 27+ the front door takes over instead
//  (`CloudAccountLanguageModel` via `LanguageModelProvider`), which
//  additionally makes the account a native `LanguageModel` for the profiles
//  bridge; the two paths share the REST clients underneath, so behaviour,
//  streaming, and error mapping are identical.
//
//  The credential stays a per-call token provider: it is resolved fresh on
//  every request (a Keychain read or a refreshed token both fit), and an
//  empty credential surfaces as `.unauthorized` before any network call.
//

import Foundation

struct UserAccountRESTProvider: ModelProvider {

    let identifier: ProviderIdentifier
    let privacyLevel = PrivacyLevel.external

    private let account: UserAccount

    init(account: UserAccount) {
        self.identifier = .userAccount(account.vendor)
        self.account = account
    }

    func availability() async -> ProviderAvailability {
        account.isConnected
            ? .available
            : .unavailable(reason: "Account not connected")
    }

    /// Resolves the credential and builds the vendor client for this call —
    /// the same construction the developer-key path uses (D15 defaults,
    /// key trimming included).
    private func makeProvider() async throws -> any ModelProvider {
        let key = try await account.token()
        guard !key.isEmpty else { throw ProviderError.unauthorized }
        var config = AIConfiguration()
        config.developerKey = key
        config.developerKeyVendor = account.vendor
        config.developerKeyModel = account.model
        guard let provider = AIOrchestrator.buildCloudProvider(from: config) else {
            throw ProviderError.unauthorized
        }
        return provider
    }

    func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        try await makeProvider().respond(
            to: prompt, instructions: instructions, history: history
        )
    }

    // MARK: Structured output (D21) — forwarded to the vendor client

    var supportsNativeStructuredOutput: Bool { true }

    func respondStructured(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn],
        schema: OutputSchema
    ) async throws -> String {
        try await makeProvider().respondStructured(
            to: prompt, instructions: instructions, history: history, schema: schema
        )
    }

    func streamResponse(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let provider = try await makeProvider()
                    for try await fragment in provider.streamResponse(
                        to: prompt, instructions: instructions, history: history
                    ) {
                        continuation.yield(fragment)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
