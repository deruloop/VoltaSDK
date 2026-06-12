//
//  OpenAIProvider.swift
//  AIProviderKit
//
//  Evoluzione del ChatGptManager originale.
//  Differenze chiave rispetto alla versione primitiva:
//   - firma `throws -> String` invece di `-> String?` (gli errori non si perdono)
//   - errori mappati su ProviderError (429 → .rateLimited, 401 → .unauthorized, ...)
//   - modello e parametri configurabili invece che hardcoded
//   - request/response via Codable invece di JSONSerialization
//
//  NOTA SICUREZZA (iOS 26): qui la developer key viaggia in una chiamata diretta
//  dal dispositivo all'endpoint OpenAI. La chiave è dello sviluppatore (non dell'utente),
//  ma resta nel traffico del device. Per produzione ad alto volume valutare un proxy
//  lato server. Su iOS 27 questo provider sarà rimpiazzabile dall'integrazione nativa
//  conforme al protocollo `LanguageModel`.
//

import Foundation

public struct OpenAIProvider: ModelProvider {

    public let identifier = ProviderIdentifier.openAI
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let temperature: Double
    private let endpoint: URL
    private let urlSession: URLSession

    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        maxTokens: Int = 1000,
        temperature: Double = 0.3,
        endpoint: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    public func availability() async -> ProviderAvailability {
        apiKey.isEmpty
            ? .unavailable(reason: "API key non configurata")
            : .available
    }

    public func respond(
        to prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // system → storia fornita dall'app (D12) → prompt corrente.
        var messages: [ChatRequest.Message] = []
        if let instructions, !instructions.isEmpty {
            messages.append(.init(role: "system", content: instructions))
        }
        for turn in history {
            messages.append(.init(
                role: turn.role == .user ? "user" : "assistant",
                content: turn.text
            ))
        }
        messages.append(.init(role: "user", content: prompt))

        do {
            request.httpBody = try JSONEncoder().encode(
                ChatRequest(
                    model: model,
                    messages: messages,
                    maxCompletionTokens: maxTokens,
                    temperature: temperature
                )
            )
        } catch {
            throw ProviderError.encoding("Encoding della richiesta fallito: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw ProviderError.cancelled }
            throw ProviderError.network(code: urlError.errorCode)
        } catch {
            throw ProviderError.network(code: -1)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network(code: -1)
        }

        // Errori HTTP mappati su casi semantici.
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ProviderError.unauthorized
        case 429:
            let retryAfter = Self.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        default:
            if let envelope = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                // Il context window superato arriva come errore applicativo:
                // lo distinguiamo perché per l'orchestratore è recuperabile.
                if envelope.error.code == "context_length_exceeded" {
                    throw ProviderError.contextWindowExceeded
                }
                throw ProviderError.api(message: envelope.error.message, code: envelope.error.code)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<corpo non leggibile>"
            throw ProviderError.api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }

        guard !data.isEmpty else { throw ProviderError.emptyResponse }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                throw ProviderError.emptyResponse
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    /// `Retry-After` può essere in secondi ("120") o una HTTP-date.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss 'GMT'"
        if let date = formatter.date(from: value) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
}

// MARK: - DTO

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let maxCompletionTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        // `max_tokens` è deprecato: i modelli più recenti accettano solo questo.
        case maxCompletionTokens = "max_completion_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let message: String
        let type: String?
        let code: String?
    }
}
