//
//  EvalTask.swift
//  VoltaSDKEvals
//
//  The generic triple (D20): a TASK = schema + dataset + graders, as data.
//  The engine runs any task through any tier of the chain and measures it;
//  a client's task file is the only client-specific artifact, consumed by
//  path. Nothing here knows any client's domain — the multi-turn wrapper,
//  the per-sample expectations, and the graders are all generic primitives
//  the task file composes.
//

import Evaluations
import Foundation
import FoundationModels
import VoltaSDK

// MARK: - Task

/// One evaluation task: the schema the app expects, the instructions it
/// sends, the samples it collected, and the graders that define PASS.
struct EvalTask: Codable, Sendable {
    /// Stable identifier, e.g. `raviolo.task-a`. Rows of the capability map
    /// are keyed by it.
    var id: String
    var title: String
    /// Version of the schema + prompt this dataset was written against.
    /// Datasets are keyed to it: a schema change means a re-run.
    var schemaVersion: String
    /// The system instructions, verbatim as the app sends them.
    var instructions: String
    /// Expected language of the answer's prose fields (BCP-47), if any.
    var language: String?
    /// The output shape. Optional: a task may be free text.
    var schema: OutputSchema?
    /// How a later turn's prompt is built from the previous turn (multi-turn
    /// tasks). Absent = turns are sent as typed, history carries the rest.
    var carry: CarryTemplate?
    /// The grader list. PASS for a sample = every grader passes.
    var graders: [GraderSpec]
    /// Optional model-judge dimensions (session 335); a cloud judge scores
    /// them when configured, and its agreement with human ratings is
    /// measured before it is trusted.
    var judge: JudgeSpec?
    var samples: [EvalSample]

    /// Loads a task file (JSON).
    static func load(from url: URL) throws -> EvalTask {
        try JSONDecoder().decode(EvalTask.self, from: Data(contentsOf: url))
    }
}

// MARK: - Sample

/// One dataset entry: the user's turns (one or more) and the expectations
/// the graders check. Plain data; `FrameworkSample` adapts it to the
/// framework's sample protocols.
struct EvalSample: Codable, Sendable, Identifiable, Equatable {
    var id: String
    /// The user's turns, as typed in the app.
    var turns: [String]
    /// A fallback conversation state for the carry template when the
    /// previous turn produced nothing usable (the handoff's "canonical
    /// expected state").
    var canonicalState: JSONValue?
    /// What the graders check for this sample specifically.
    var expect: EvalExpectation?
    /// Free-form notes (why the sample exists, the ambiguity it probes).
    var notes: String?
}

/// The framework-facing sample: an `EvalSample` plus the instructions the
/// model saw, so the built-in loaders, the judge prompt, and the result
/// tables all show the real input. `ExpectedValue` is the engine's
/// outcome type (the framework requires subject and expectation to share
/// a type); the deterministic expectations live on `sample.expect`.
@available(iOS 27.0, macOS 27.0, *)
struct FrameworkSample: ModelSampleProtocol, Codable, Sendable {
    typealias ExpectedValue = EvalOutcome
    typealias Expectation = TrajectoryExpectation

    var sample: EvalSample
    var instructions: String

    var id: String { sample.id }

    var input: ModelSampleInput {
        ModelSampleInput(
            prompt: Prompt(sample.turns.joined(separator: "\n---\n")),
            instructions: Instructions(instructions)
        )
    }

    var output: ModelSampleOutput<EvalOutcome, TrajectoryExpectation> {
        ModelSampleOutput(value: nil, expectations: nil)
    }

    var expected: EvalOutcome? { nil }
}

/// Per-sample expectations, all generic: field values, array contents,
/// forbidden fields. A task's graders decide which ones apply.
struct EvalExpectation: Codable, Sendable, Equatable {
    /// `path → allowed values` — the value at the path must be one of them
    /// (strings compared case-insensitively).
    var fields: [String: [String]]?
    /// `path → required elements` — the array at the path must contain each
    /// element (normalized: case-insensitive, articles stripped, substring
    /// match either way).
    var contains: [String: [String]]?
    /// Which `anyOf` choice (by object name) the answer should take.
    var shape: String?
}

// MARK: - Outcome (what the engine produces)

/// The engine's record of one sample's run: every turn's raw text, parsed
/// value, provenance, and error, plus what the carry template produced.
struct EvalOutcome: Codable, Sendable, Equatable {
    var turns: [TurnOutcome]
    var tier: String
    var mode: String

    struct TurnOutcome: Codable, Sendable, Equatable {
        /// The prompt actually sent (post-carry).
        var prompt: String
        var text: String?
        var value: JSONValue?
        var provider: String?
        var error: String?
        /// The `ProviderError` case name when the provider failed.
        var errorKind: String?
        var repaired: Bool?
        var nativeSchema: Bool?
        var carriedFromCanonicalState: Bool?
        var latencySeconds: Double?
    }

    var last: TurnOutcome? { turns.last }
    var failedTurn: TurnOutcome? { turns.first { $0.error != nil } }
}

// MARK: - Grader / judge specs (data)

/// A grader declared in the task file: a kind from the registry + params.
struct GraderSpec: Codable, Sendable, Equatable {
    var kind: String
    var params: [String: JSONValue]?

    func string(_ key: String) -> String? { params?[key]?.stringValue }
    func strings(_ key: String) -> [String]? { params?[key]?.arrayValue?.compactMap(\.stringValue) }
    func int(_ key: String) -> Int? { params?[key]?.numberValue.map { Int($0) } }
    func double(_ key: String) -> Double? { params?[key]?.numberValue }
    func bool(_ key: String) -> Bool? { params?[key]?.boolValue }
}

struct JudgeSpec: Codable, Sendable, Equatable {
    var instructions: String?
    var dimensions: [Dimension]
    struct Dimension: Codable, Sendable, Equatable {
        var name: String
        var description: String?
        /// `passFail` (default) or a numeric scale `[value: label]` given as
        /// `{"1":"...","5":"..."}`.
        var scale: [String: String]?
    }
}

// MARK: - Carry template (multi-turn wrapper)

/// How turn N's prompt is built from turn N-1's output. A template with a
/// few generic placeholders:
///
/// - `{{prompt}}` — the user's text for this turn
/// - `{{previous.raw}}` — the previous raw answer text
/// - `{{previous.json}}` — the previous parsed value, compact JSON
/// - `{{previous.<path>}}` — the value at a dot path (`a.b[0].c`), strings unquoted
/// - `{{previous.<path>|join:<fmt>|sep:<s>}}` — an array of objects, each
///   element rendered with `<fmt>` where `{field}` reads the element's
///   field, joined by `<s>` (default ", ")
///
/// When the previous turn produced no parsed value, the sample's
/// `canonicalState` stands in (and the outcome records that); when there
/// is none either, the prompt is sent unwrapped.
struct CarryTemplate: Codable, Sendable, Equatable {
    var template: String

    func render(prompt: String, previous: JSONValue?, previousRaw: String?) -> String {
        var output = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            output += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                output += rest[open.lowerBound...]
                rest = ""
                break
            }
            // Not trimmed: a `sep:` option may legitimately end in a space.
            let directive = String(rest[open.upperBound..<close.lowerBound])
            output += resolve(directive, prompt: prompt, previous: previous, previousRaw: previousRaw)
            rest = rest[close.upperBound...]
        }
        output += rest
        return output
    }

    private func resolve(_ directive: String, prompt: String, previous: JSONValue?, previousRaw: String?) -> String {
        let keyword = directive.trimmingCharacters(in: .whitespaces)
        if keyword == "prompt" { return prompt }
        if keyword == "previous.raw" { return previousRaw ?? "" }
        if keyword == "previous.json" { return previous?.serialized() ?? "" }
        guard keyword.hasPrefix("previous.") else { return "{{\(directive)}}" }

        let parts = directive.drop(while: { $0 == " " })
            .dropFirst("previous.".count)
            .split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let path = parts[0].trimmingCharacters(in: .whitespaces)
        let value = previous.flatMap { JSONPath.value(at: path, in: $0) }
        var joinFormat: String? = nil
        var separator = ", "
        for option in parts.dropFirst() {
            if option.hasPrefix("join:") { joinFormat = String(option.dropFirst(5)) }
            if option.hasPrefix("sep:") { separator = String(option.dropFirst(4)) }
        }
        guard let value else { return "" }
        if let joinFormat, let items = value.arrayValue {
            return items.map { item in
                var rendered = joinFormat
                if let members = item.objectValue {
                    for (key, member) in members {
                        rendered = rendered.replacingOccurrences(of: "{\(key)}", with: Self.plain(member))
                    }
                } else {
                    rendered = rendered.replacingOccurrences(of: "{value}", with: Self.plain(item))
                }
                return rendered
            }.joined(separator: separator)
        }
        return Self.plain(value)
    }

    /// Strings unquoted, everything else compact JSON.
    static func plain(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return value.serialized()
    }
}

// MARK: - JSON path

/// Dot paths with array indices and a `[]` wildcard: `items[].name`
/// collects every element's `name`; `compounds.protein` reads one member.
enum JSONPath {
    static func value(at path: String, in root: JSONValue) -> JSONValue? {
        let values = collect(at: path, in: root)
        if path.contains("[]") { return .array(values) }
        return values.first
    }

    /// All values the path addresses (one unless a `[]` wildcard is used).
    static func collect(at path: String, in root: JSONValue) -> [JSONValue] {
        var current: [JSONValue] = [root]
        for component in path.split(separator: ".").map(String.init) where !component.isEmpty {
            var next: [JSONValue] = []
            // `name[0]`, `name[]`, or plain `name`.
            var key = component
            var indices: [String] = []
            while let open = key.lastIndex(of: "["), key.hasSuffix("]") {
                indices.insert(String(key[key.index(after: open)..<key.index(before: key.endIndex)]), at: 0)
                key = String(key[..<open])
            }
            for value in current {
                var candidates: [JSONValue] = key.isEmpty ? [value] : (value[key].map { [$0] } ?? [])
                for index in indices {
                    var expanded: [JSONValue] = []
                    for candidate in candidates {
                        guard let items = candidate.arrayValue else { continue }
                        if index.isEmpty { expanded += items }
                        else if let number = Int(index), items.indices.contains(number) { expanded.append(items[number]) }
                    }
                    candidates = expanded
                }
                next += candidates
            }
            current = next
        }
        return current
    }
}
