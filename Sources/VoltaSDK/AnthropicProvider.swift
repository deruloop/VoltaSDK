//
//  AnthropicProvider.swift
//  VoltaSDK
//
//  Developer-key provider for Anthropic's Messages API (Claude).
//  Same shape as OpenAIProvider: typed errors, Codable DTOs, history → the
//  vendor's native message format (D12).
//
//  API notes:
//   - Auth is `x-api-key` (not a Bearer token) + `anthropic-version` header.
//   - `max_tokens` is required by the API.
//   - `temperature` is deliberately NOT sent: recent Claude models
//     (Opus 4.7+) reject sampling parameters with a 400.
//   - The error envelope is {type: "error", error: {type, message}}.
//

import Foundation

public struct AnthropicProvider: ModelProvider {

    public let identifier = ProviderIdentifier.anthropic
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let endpoint: URL
    private let urlSession: URLSession
    private let explicitContextSize: Int?

    public init(
        apiKey: String,
        model: String = CloudVendor.anthropic.defaultModel,
        maxTokens: Int = 1000,
        endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!,
        urlSession: URLSession = .shared,
        contextSize: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.explicitContextSize = contextSize
    }

    // MARK: Token awareness (D13) — honest estimates

    /// Known context windows per model family; `nil` for unknown models
    /// (no pre-flight beats a wrong pre-flight). Overridable in the init.
    public var contextSize: Int? {
        if let explicitContextSize { return explicitContextSize }
        return Self.knownContextSize(forModel: model)
    }

    static func knownContextSize(forModel model: String) -> Int? {
        if model.hasPrefix("claude-haiku") { return 200_000 }
        if model.hasPrefix("claude-opus-4-6")
            || model.hasPrefix("claude-opus-4-7")
            || model.hasPrefix("claude-opus-4-8")
            || model.hasPrefix("claude-sonnet-4-6") {
            return 1_000_000
        }
        if model.hasPrefix("claude-") { return 200_000 }
        return nil
    }

    /// ESTIMATE (~4 characters/token): Anthropic has a server-side
    /// count_tokens endpoint, but calling it on every pre-flight would cost
    /// a network round-trip per request — a deliberate trade-off.
    public func tokenCount(
        prompt: String,
        instructions: String?,
        history: [ChatTurn]
    ) async -> Int? {
        var characters = prompt.count + (instructions?.count ?? 0)
        for turn in history { characters += turn.text.count }
        return (characters + 3) / 4
    }

    public func availability() async -> ProviderAvailability {
        apiKey.isEmpty
            ? .unavailable(reason: "API key not configured")
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
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // App-supplied history (D12) → user/assistant turns → current prompt.
        var messages: [MessagesRequest.Message] = []
        for turn in history {
            messages.append(.init(
                role: turn.role == .user ? "user" : "assistant",
                content: turn.text
            ))
        }
        messages.append(.init(role: "user", content: prompt))

        do {
            request.httpBody = try JSONEncoder().encode(
                MessagesRequest(
                    model: model,
                    maxTokens: maxTokens,
                    system: (instructions?.isEmpty == false) ? instructions : nil,
                    messages: messages
                )
            )
        } catch {
            throw ProviderError.encoding("Request encoding failed: \(error.localizedDescription)")
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

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw ProviderError.unauthorized
        case 429:
            let retryAfter = RetryAfterParser.parse(http.value(forHTTPHeaderField: "retry-after"))
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            // Includes 529 "overloaded" — transient, recoverable by fallback.
            throw ProviderError.network(code: http.statusCode)
        default:
            if let envelope = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data) {
                // Context overflow arrives as a 400 invalid_request_error;
                // single it out because the orchestrator can recover from it.
                if envelope.error.message.localizedCaseInsensitiveContains("prompt is too long") {
                    throw ProviderError.contextWindowExceeded
                }
                throw ProviderError.api(message: envelope.error.message, code: envelope.error.type)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw ProviderError.api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }

        guard !data.isEmpty else { throw ProviderError.emptyResponse }

        do {
            let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
            guard let text = decoded.content.first(where: { $0.type == "text" })?.text,
                  !text.isEmpty else {
                throw ProviderError.emptyResponse
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let providerError as ProviderError {
            throw providerError
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - DTOs

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, system, messages
        case maxTokens = "max_tokens"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct MessagesResponse: Decodable {
    let content: [Block]
    struct Block: Decodable {
        let type: String
        let text: String?
    }
}

private struct AnthropicErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let type: String
        let message: String
    }
}
