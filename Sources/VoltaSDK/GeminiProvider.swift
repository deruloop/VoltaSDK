//
//  GeminiProvider.swift
//  VoltaSDK
//
//  Developer-key provider for Google's Gemini API (generateContent).
//  Same shape as the other cloud providers: typed errors, Codable DTOs,
//  history → the vendor's native contents format (D12).
//
//  API notes:
//   - Auth is the `x-goog-api-key` header.
//   - History roles are "user" and "model" (not "assistant").
//   - Instructions go in the top-level `systemInstruction`.
//   - Errors use {error: {code, message, status}}; an invalid key surfaces
//     as a 400 INVALID_ARGUMENT, not a 401.
//

import Foundation

public struct GeminiProvider: ModelProvider {

    public let identifier = ProviderIdentifier.gemini
    public let privacyLevel = PrivacyLevel.external

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let temperature: Double
    private let baseURL: URL
    private let urlSession: URLSession
    private let explicitContextSize: Int?

    public init(
        apiKey: String,
        model: String = CloudVendor.gemini.defaultModel,
        maxTokens: Int = 1000,
        temperature: Double = 0.3,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        urlSession: URLSession = .shared,
        contextSize: Int? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.explicitContextSize = contextSize
    }

    // MARK: Token awareness (D13) — honest estimates

    public var contextSize: Int? {
        if let explicitContextSize { return explicitContextSize }
        return Self.knownContextSize(forModel: model)
    }

    static func knownContextSize(forModel model: String) -> Int? {
        if model.hasPrefix("gemini-1.5-pro") { return 2_097_152 }
        if model.hasPrefix("gemini-") { return 1_048_576 }
        return nil
    }

    /// ESTIMATE (~4 characters/token), like the other cloud providers.
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
        let endpoint = baseURL.appendingPathComponent("models/\(model):generateContent")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        // App-supplied history (D12) → user/model turns → current prompt.
        var contents: [GenerateRequest.Content] = []
        for turn in history {
            contents.append(.init(
                role: turn.role == .user ? "user" : "model",
                parts: [.init(text: turn.text)]
            ))
        }
        contents.append(.init(role: "user", parts: [.init(text: prompt)]))

        do {
            request.httpBody = try JSONEncoder().encode(
                GenerateRequest(
                    systemInstruction: (instructions?.isEmpty == false)
                        ? .init(role: nil, parts: [.init(text: instructions!)])
                        : nil,
                    contents: contents,
                    generationConfig: .init(
                        temperature: temperature,
                        maxOutputTokens: maxTokens
                    )
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
            throw ProviderError.network(code: http.statusCode)
        default:
            if let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data) {
                // An invalid key is a 400 INVALID_ARGUMENT here, not a 401.
                if envelope.error.message.localizedCaseInsensitiveContains("api key not valid") {
                    throw ProviderError.unauthorized
                }
                throw ProviderError.api(message: envelope.error.message, code: envelope.error.status)
            }
            let raw = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            throw ProviderError.api(message: "HTTP \(http.statusCode): \(raw)", code: nil)
        }

        guard !data.isEmpty else { throw ProviderError.emptyResponse }

        do {
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            guard let text = decoded.candidates?.first?.content.parts.first?.text,
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

private struct GenerateRequest: Encodable {
    let systemInstruction: Content?
    let contents: [Content]
    let generationConfig: GenerationConfig

    struct Content: Encodable {
        let role: String?
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
    }
}

private struct GenerateResponse: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String?
    }
}

private struct GeminiErrorEnvelope: Decodable {
    let error: APIError
    struct APIError: Decodable {
        let code: Int
        let message: String
        let status: String?
    }
}
