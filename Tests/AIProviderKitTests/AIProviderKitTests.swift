//
//  AIProviderKitTests.swift
//  AIProviderKitTests
//

import Foundation
import Testing
import Synchronization
@testable import AIProviderKit

// MARK: - Selezione e fallback

@Suite("Orchestratore e fallback")
struct OrchestratorFallbackTests {

    @Test("Usa il primo provider disponibile")
    func usesFirstAvailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("on-device")),
            MockProvider(identifier: .openAI, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "ciao")
        #expect(result == "on-device")
    }

    @Test("Salta un provider non disponibile")
    func skipsUnavailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "no Apple Intelligence"),
                         outcome: .success("on-device")),
            MockProvider(identifier: .openAI, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "ciao")
        #expect(result == "openai")
    }

    @Test("Fa fallback su rate limit")
    func fallsBackOnRateLimit() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.rateLimited(retryAfter: nil))),
            MockProvider(identifier: .onDevice, outcome: .success("on-device"))
        ])
        let result = try await kit.respond(to: "ciao")
        #expect(result == "on-device")
    }

    @Test("Fa fallback su context window superato")
    func fallsBackOnContextWindow() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .failure(.contextWindowExceeded)),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        let result = try await kit.respond(to: "ciao")
        #expect(result == "openai")
    }

    @Test("Non fa fallback su errore terminale (auth)")
    func doesNotFallBackOnTerminalError() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.unauthorized)),
            MockProvider(identifier: .onDevice, outcome: .success("on-device"))
        ])
        await #expect(throws: ProviderError.unauthorized) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("Non fa fallback su guardrail violation")
    func doesNotFallBackOnGuardrail() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .failure(.guardrailViolation("bloccato"))),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        await #expect(throws: ProviderError.guardrailViolation("bloccato")) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("Errore se la lista provider è vuota")
    func errorWhenEmpty() async {
        let kit = AIOrchestrator(providers: [])
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("Errore se tutti i provider sono indisponibili")
    func errorWhenAllUnavailable() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI,
                         availability: .unavailable(reason: "y"),
                         outcome: .success("b"))
        ])
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("Riporta l'ultimo errore se tutti i provider falliscono in modo recuperabile")
    func reportsLastRecoverableError() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .openAI, outcome: .failure(.rateLimited(retryAfter: nil))),
            MockProvider(identifier: .onDevice, outcome: .failure(.network(code: -1009)))
        ])
        await #expect(throws: ProviderError.network(code: -1009)) {
            _ = try await kit.respond(to: "ciao")
        }
    }
}

// MARK: - Risposta dettagliata e risoluzione

@Suite("Risoluzione e provenienza")
struct ResolutionTests {

    @Test("respondDetailed riporta provider e livello di privacy")
    func detailedResponseCarriesProvenance() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ])
        let response = try await kit.respondDetailed(to: "ciao")
        #expect(response.text == "openai")
        #expect(response.provider == .openAI)
        #expect(response.privacyLevel == .external)
    }

    @Test("resolveProvider restituisce il primo disponibile senza eseguire")
    func resolveReturnsFirstAvailable() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
        ])
        let provider = try await kit.resolveProvider()
        #expect(provider.identifier == .openAI)
    }

    @Test("resolveProvider con denyDowngrade esclude i provider sotto soglia")
    func resolveRespectsDenyDowngrade() async {
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice,
                             privacyLevel: .onDevice,
                             availability: .unavailable(reason: "x"),
                             outcome: .success("a")),
                MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
            ],
            privacyDisclosure: .denyDowngrade
        )
        await #expect(throws: ProviderError.noProviderAvailable) {
            _ = try await kit.resolveProvider()
        }
    }

    @Test("providerStatuses riporta tutta la catena nell'ordine, con i motivi")
    func statusesReportWholeChain() async {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         privacyLevel: .onDevice,
                         availability: .unavailable(reason: "niente Apple Intelligence"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("b"))
        ])
        let statuses = await kit.providerStatuses()
        #expect(statuses.count == 2)
        #expect(statuses[0].identifier == .onDevice)
        #expect(statuses[0].availability == .unavailable(reason: "niente Apple Intelligence"))
        #expect(statuses[1].identifier == .openAI)
        #expect(statuses[1].availability == .available)
        #expect(statuses[1].privacyLevel == .external)
    }
}

// MARK: - Disclosure di privacy

@Suite("Disclosure di privacy")
struct PrivacyDisclosureTests {

    /// Catena: on-device (indisponibile) → openai (external).
    /// Il baseline è onDevice, quindi usare openai è un downgrade.
    private func downgradeChain() -> [any ModelProvider] {
        [
            MockProvider(identifier: .onDevice,
                         privacyLevel: .onDevice,
                         availability: .unavailable(reason: "x"),
                         outcome: .success("a")),
            MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
        ]
    }

    @Test("silent: il downgrade procede senza segnalazioni")
    func silentAllowsDowngrade() async throws {
        let kit = AIOrchestrator(providers: downgradeChain(), privacyDisclosure: .silent)
        #expect(try await kit.respond(to: "ciao") == "openai")
    }

    @Test("notify: il downgrade procede e l'handler riceve l'evento")
    func notifyFiresHandler() async throws {
        let events = Mutex<[PrivacyDowngrade]>([])
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .notify { downgrade in
                events.withLock { $0.append(downgrade) }
            }
        )
        let result = try await kit.respond(to: "ciao")
        #expect(result == "openai")

        let recorded = events.withLock { $0 }
        #expect(recorded == [
            PrivacyDowngrade(from: .onDevice, to: .external, provider: .openAI)
        ])
    }

    @Test("askOnPrivacyChange: true → procede")
    func askApprovedProceeds() async throws {
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .askOnPrivacyChange { _ in true }
        )
        #expect(try await kit.respond(to: "ciao") == "openai")
    }

    @Test("askOnPrivacyChange: false → privacyRestricted")
    func askDeclinedBlocks() async {
        let kit = AIOrchestrator(
            providers: downgradeChain(),
            privacyDisclosure: .askOnPrivacyChange { _ in false }
        )
        await #expect(throws: ProviderError.privacyRestricted) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("denyDowngrade: i provider sotto soglia non vengono mai usati")
    func denyBlocksDowngrade() async {
        let kit = AIOrchestrator(providers: downgradeChain(), privacyDisclosure: .denyDowngrade)
        await #expect(throws: ProviderError.privacyRestricted) {
            _ = try await kit.respond(to: "ciao")
        }
    }

    @Test("Nessun downgrade se il provider che risponde è al livello del baseline")
    func noDowngradeAtSameLevel() async throws {
        let events = Mutex<[PrivacyDowngrade]>([])
        let kit = AIOrchestrator(
            providers: [
                MockProvider(identifier: .onDevice, privacyLevel: .onDevice, outcome: .success("on-device")),
                MockProvider(identifier: .openAI, privacyLevel: .external, outcome: .success("openai"))
            ],
            privacyDisclosure: .notify { downgrade in
                events.withLock { $0.append(downgrade) }
            }
        )
        let result = try await kit.respond(to: "ciao")
        #expect(result == "on-device")
        #expect(events.withLock { $0 }.isEmpty)
    }
}

// MARK: - Transcript transparency (D12)

@Suite("Storia della conversazione (D12)")
struct ConversationHistoryTests {

    @Test("La storia fornita dall'app arriva intatta al provider")
    func historyReachesProvider() async throws {
        let received = Mutex<[ChatTurn]?>(nil)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("ok")) { _, _, history in
                received.withLock { $0 = history }
            }
        ])

        let history: [ChatTurn] = [
            .user("Pianifica un weekend"),
            .assistant("Ecco l'itinerario…")
        ]
        _ = try await kit.respond(to: "modifica il giorno 2", history: history)

        #expect(received.withLock { $0 } == history)
    }

    @Test("Senza storia il provider riceve una lista vuota")
    func defaultHistoryIsEmpty() async throws {
        let received = Mutex<[ChatTurn]?>(nil)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("ok")) { _, _, history in
                received.withLock { $0 = history }
            }
        ])
        _ = try await kit.respond(to: "ciao")
        #expect(received.withLock { $0 } == [])
    }

    @Test("Il fallback inoltra la STESSA storia al provider successivo")
    func fallbackForwardsSameHistory() async throws {
        let firstSaw = Mutex<[ChatTurn]?>(nil)
        let secondSaw = Mutex<[ChatTurn]?>(nil)

        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         outcome: .failure(.rateLimited(retryAfter: nil))) { _, _, history in
                firstSaw.withLock { $0 = history }
            },
            MockProvider(identifier: .openAI,
                         privacyLevel: .external,
                         outcome: .success("openai")) { _, _, history in
                secondSaw.withLock { $0 = history }
            }
        ])

        let history: [ChatTurn] = [.user("turno 1"), .assistant("risposta 1")]
        let result = try await kit.respond(to: "turno 2", history: history)

        // Il primo provider fallisce in modo recuperabile, il secondo riceve
        // la chiamata autocontenuta con la stessa storia: la conversazione
        // sopravvive al cambio di provider.
        #expect(result == "openai")
        #expect(firstSaw.withLock { $0 } == history)
        #expect(secondSaw.withLock { $0 } == history)
    }
}

// MARK: - Configurazione globale

@Suite("Configurazione", .serialized)
struct ConfigurationTests {

    @Test("configure imposta l'istanza attiva")
    func configureSetsActive() async {
        AIOrchestrator.configure {
            $0.enableOnDevice = false
            $0.developerKey = nil
        }
        // Nessun provider costruito → nessuno disponibile.
        let available = await AIOrchestrator.active.availableProviders()
        #expect(available.isEmpty)
    }
}

// MARK: - Parsing

@Suite("OpenAIProvider parsing")
struct OpenAIParsingTests {

    @Test("Retry-After in secondi")
    func retryAfterSeconds() {
        #expect(OpenAIProvider.parseRetryAfter("120") == 120)
    }

    @Test("Retry-After come HTTP-date (futuro) → intervallo positivo")
    func retryAfterDate() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss 'GMT'"
        let future = formatter.string(from: Date().addingTimeInterval(90))

        let parsed = try #require(OpenAIProvider.parseRetryAfter(future))
        #expect(parsed > 80 && parsed <= 91)
    }

    @Test("Retry-After assente o illeggibile → nil")
    func retryAfterInvalid() {
        #expect(OpenAIProvider.parseRetryAfter(nil) == nil)
        #expect(OpenAIProvider.parseRetryAfter("boh") == nil)
    }
}
