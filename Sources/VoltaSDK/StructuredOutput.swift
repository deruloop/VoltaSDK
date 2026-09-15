//
//  StructuredOutput.swift
//  VoltaSDK
//
//  Structured output, D21: schema in, validated typed value out, repair,
//  typed failure. The orchestrator asks the resolved provider for JSON
//  (natively constrained where the provider can — guided generation on
//  Apple models, JSON mode on the cloud vendors — prompted otherwise),
//  extracts the JSON leniently, validates it against the schema, and on a
//  violation gives the SAME provider one repair turn with the violations
//  spelled out. A second failure is a typed error the chain treats as
//  recoverable: the next provider gets its chance, and the privacy gate
//  (D7/D18) applies as for any fallback.
//
//  Only the SDK knows which provider answered, so this is the one place a
//  "validated typed value" can honestly be promised across the chain — the
//  evaluation work (D20) measures how often each tier earns it.
//

import Foundation

// MARK: - Errors from the parsing layer

/// Failures of the JSON layer itself (before schema validation).
public enum StructuredOutputError: Error, Sendable, Equatable {
    /// No `{ … }` object in the text at all.
    case noJSONFound
    /// Text that looked like JSON but did not parse.
    case invalidJSON(String)
}

// MARK: - Repair policy

/// How many repair turns the orchestrator may spend on a non-conforming
/// answer before declaring the provider's attempt failed.
public enum RepairPolicy: Sendable, Equatable {
    /// Take the first answer as is (the raw ceiling).
    case none
    /// One follow-up turn quoting the violations. The default.
    case once

    var attempts: Int {
        switch self {
        case .none: return 0
        case .once: return 1
        }
    }
}

// MARK: - Response

/// A structured answer with provenance and the path it took.
public struct StructuredResponse: Sendable {
    /// The validated value.
    public let value: JSONValue
    /// The provider's final raw text (post-repair when repaired).
    public let text: String
    public let provider: ProviderIdentifier
    public let privacyLevel: PrivacyLevel
    /// Whether a repair turn was needed to reach a conforming value.
    public let repaired: Bool
    /// Whether the provider constrained generation natively (as opposed to
    /// the prompted fallback).
    public let nativeSchema: Bool
    /// Whether text surrounded the JSON object in the (final) raw answer —
    /// the model did not obey "JSON only" even if the object inside was fine.
    public let hadSurroundingText: Bool

    /// Decodes the value into the app's own type.
    public func decode<T: Decodable>(_ type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try value.decode(type, decoder: decoder)
    }
}

// MARK: - Shared helpers

public enum StructuredOutput {
    /// The prompted fallback: the schema appended to the app's instructions.
    /// Kept as a public helper so custom providers without a native mode
    /// can build the same prompt.
    public static func promptedInstructions(_ instructions: String?, schema: OutputSchema) -> String {
        let base = (instructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? schema.promptDescription : base + "\n\n" + schema.promptDescription
    }

    /// The repair turn's prompt: the violations, and the instruction to answer
    /// again with only the corrected JSON.
    public static func repairPrompt(violations: [String]) -> String {
        "Your previous reply did not conform to the required JSON shape:\n- "
            + violations.joined(separator: "\n- ")
            + "\nReply again with ONLY the corrected JSON value, no prose."
    }

    /// The outcome of checking one raw answer against a schema.
    public enum Check: Sendable, Equatable {
        case conforming(JSONValue, hadSurroundingText: Bool)
        case violations([String])
    }

    /// Lenient extraction + validation in one step. Public so graders and
    /// tools can apply exactly the check the orchestrator applies.
    public static func check(_ text: String, against schema: OutputSchema) -> Check {
        do {
            let (value, surrounded) = try JSONValue.extractObject(from: text)
            let violations = schema.validate(value)
            guard violations.isEmpty else { return .violations(violations.map(\.description)) }
            return .conforming(value, hadSurroundingText: surrounded)
        } catch StructuredOutputError.noJSONFound {
            return .violations(["no JSON object found in the reply"])
        } catch StructuredOutputError.invalidJSON(let reason) {
            return .violations(["the JSON does not parse: \(reason)"])
        } catch {
            return .violations([String(describing: error)])
        }
    }
}

// MARK: - Orchestrator entry points

extension AIOrchestrator {

    /// Generates a JSON value conforming to `schema`, through the same
    /// resolution-and-fallback chain as `respond`. Per provider: ask (native
    /// or prompted), extract, validate, repair per `repair`, and on failure
    /// move on with `ProviderError.malformedStructuredOutput` as the reason.
    public func respondStructured(
        to prompt: String,
        instructions: String? = nil,
        history: [ChatTurn] = [],
        schema: OutputSchema,
        need: ModelNeed? = nil,
        repair: RepairPolicy = .once
    ) async throws -> StructuredResponse {
        let providers = orderedProviders(for: need)
        guard let first = providers.first else {
            throw ProviderError.noProviderAvailable
        }
        let baseline = first.privacyLevel
        var lastError: ProviderError = .noProviderAvailable

        for provider in providers {
            if let skip = await Self.admit(
                provider, baseline: baseline, disclosure: privacyDisclosure,
                reserve: responseTokenReserve,
                prompt: prompt, instructions: instructions, history: history
            ) {
                if let error = skip { lastError = error }
                continue
            }

            do {
                return try await Self.structuredAttempt(
                    on: provider, prompt: prompt, instructions: instructions,
                    history: history, schema: schema, repair: repair
                )
            } catch let error as ProviderError {
                lastError = error
                if error.isRecoverableByFallback { continue }
                throw error
            }
        }
        throw lastError
    }

    /// Typed convenience: the validated value decoded into `T`.
    public func respond<T: Decodable>(
        to prompt: String,
        instructions: String? = nil,
        history: [ChatTurn] = [],
        schema: OutputSchema,
        as type: T.Type = T.self,
        need: ModelNeed? = nil,
        repair: RepairPolicy = .once
    ) async throws -> T {
        try await respondStructured(
            to: prompt, instructions: instructions, history: history,
            schema: schema, need: need, repair: repair
        ).decode(type)
    }

    /// One provider's attempt: first answer, then up to `repair.attempts`
    /// repair turns, each carrying the previous exchange as history (D12) so
    /// the model sees what it wrote and what was wrong with it.
    static func structuredAttempt(
        on provider: any ModelProvider,
        prompt: String,
        instructions: String?,
        history: [ChatTurn],
        schema: OutputSchema,
        repair: RepairPolicy
    ) async throws -> StructuredResponse {
        var turnPrompt = prompt
        var turnHistory = history
        var lastText = ""
        var lastViolations: [String] = []

        for attempt in 0...repair.attempts {
            let text = try await provider.respondStructured(
                to: turnPrompt, instructions: instructions, history: turnHistory, schema: schema
            )
            lastText = text
            switch StructuredOutput.check(text, against: schema) {
            case .conforming(let value, let surrounded):
                return StructuredResponse(
                    value: value,
                    text: text,
                    provider: provider.identifier,
                    privacyLevel: provider.privacyLevel,
                    repaired: attempt > 0,
                    nativeSchema: provider.supportsNativeStructuredOutput,
                    hadSurroundingText: surrounded
                )
            case .violations(let violations):
                lastViolations = violations
                // Set up the repair turn: the exchange so far + the critique.
                turnHistory = turnHistory + [.user(turnPrompt), .assistant(text)]
                turnPrompt = StructuredOutput.repairPrompt(violations: violations)
            }
        }
        throw ProviderError.malformedStructuredOutput(violations: lastViolations, raw: lastText)
    }
}
