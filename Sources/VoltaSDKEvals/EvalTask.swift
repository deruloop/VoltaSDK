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
public struct EvalTask: Codable, Sendable {
    /// Stable identifier, e.g. `raviolo.task-a`. Rows of the capability map
    /// are keyed by it.
    public var id: String
    public var title: String
    /// Version of the schema + prompt this dataset was written against.
    /// Datasets are keyed to it: a schema change means a re-run.
    public var schemaVersion: String
    /// The system instructions, verbatim as the app sends them.
    public var instructions: String
    /// Expected language of the answer's prose fields (BCP-47), if any.
    public var language: String?
    /// The output shape. Optional: a task may be free text.
    public var schema: OutputSchema?
    /// How a later turn's prompt is built from the previous turn (multi-turn
    /// tasks). Absent = turns are sent as typed, history carries the rest.
    public var carry: CarryTemplate?
    /// The grader list. PASS for a sample = every grader passes.
    public var graders: [GraderSpec]
    /// Optional model-judge dimensions (session 335); a cloud judge scores
    /// them when configured, and its agreement with human ratings is
    /// measured before it is trusted.
    public var judge: JudgeSpec?
    public var samples: [EvalSample]
    /// Free-form notes on the dataset as a whole: why it exists, what changed between versions.
    public var notes: String?

    public init(
        id: String,
        title: String,
        schemaVersion: String = "v1",
        instructions: String,
        language: String? = nil,
        schema: OutputSchema? = nil,
        carry: CarryTemplate? = nil,
        graders: [GraderSpec],
        judge: JudgeSpec? = nil,
        samples: [EvalSample],
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.schemaVersion = schemaVersion
        self.instructions = instructions
        self.language = language
        self.schema = schema
        self.carry = carry
        self.graders = graders
        self.judge = judge
        self.samples = samples
        self.notes = notes
    }

    /// Loads a task file (JSON) and validates it. A malformed file throws
    /// `EvalEngineError.invalidTask` naming the field and the reason, so a
    /// task author never has to read a `DecodingError`.
    public static func load(from url: URL) throws -> EvalTask {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EvalEngineError.invalidTask(file: url.lastPathComponent, problems: ["cannot read the file: \(error.localizedDescription)"])
        }
        let task: EvalTask
        do {
            task = try JSONDecoder().decode(EvalTask.self, from: data)
        } catch let error as DecodingError {
            throw EvalEngineError.invalidTask(file: url.lastPathComponent, problems: [Self.describe(error)])
        }
        let problems = task.validate()
        guard problems.isEmpty else {
            throw EvalEngineError.invalidTask(file: url.lastPathComponent, problems: problems.map(\.description))
        }
        return task
    }

    /// A `DecodingError` as "path: what is wrong", the way a task author
    /// reads it.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let parts = context.codingPath.map { key -> String in
                if let index = key.intValue { return "[\(index)]" }
                return "." + key.stringValue
            }
            let joined = parts.joined()
            return joined.hasPrefix(".") ? String(joined.dropFirst()) : (joined.isEmpty ? "(root)" : joined)
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(path(context)): missing required field \"\(key.stringValue)\""
        case .typeMismatch(let type, let context):
            return "\(path(context)): expected \(type)"
        case .valueNotFound(let type, let context):
            return "\(path(context)): expected a \(type), found null"
        case .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    public init(contentsOf url: URL) throws {
        self = try Self.load(from: url)
    }

    /// The generic example tasks shipped with the engine — a starting point
    /// to copy, and the dataset the engine's own tests run.
    public static var examples: [EvalTask] {
        get throws {
            guard let directory = Bundle.module.url(forResource: "Examples", withExtension: nil) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return try files.filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map(load(from:))
        }
    }

    public static func example(_ id: String) throws -> EvalTask {
        guard let task = try examples.first(where: { $0.id == id }) else {
            throw EvalEngineError.taskNotFound(id)
        }
        return task
    }
}

// MARK: - Sample

/// One dataset entry: the user's turns (one or more) and the expectations
/// the graders check. Plain data; `FrameworkSample` adapts it to the
/// framework's sample protocols.
public struct EvalSample: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    /// The user's turns, as typed in the app.
    public var turns: [String]
    /// A fallback conversation state for the carry template when the
    /// previous turn produced nothing usable (the handoff's "canonical
    /// expected state").
    public var canonicalState: JSONValue?
    /// What the graders check for this sample specifically.
    public var expect: EvalExpectation?
    /// Free-form notes (why the sample exists, the ambiguity it probes).
    public var notes: String?

    public init(id: String, turns: [String], canonicalState: JSONValue? = nil, expect: EvalExpectation? = nil, notes: String? = nil) {
        self.id = id
        self.turns = turns
        self.canonicalState = canonicalState
        self.expect = expect
        self.notes = notes
    }
}

/// The framework-facing sample: an `EvalSample` plus the instructions the
/// model saw, so the built-in loaders, the judge prompt, and the result
/// tables all show the real input. `ExpectedValue` is the engine's
/// outcome type (the framework requires subject and expectation to share
/// a type); the deterministic expectations live on `sample.expect`.
@available(iOS 27.0, macOS 27.0, *)
public struct FrameworkSample: ModelSampleProtocol, Codable, Sendable {
    public typealias ExpectedValue = EvalOutcome
    public typealias Expectation = TrajectoryExpectation

    public var sample: EvalSample
    public var instructions: String

    public var id: String { sample.id }

    public var input: ModelSampleInput {
        ModelSampleInput(
            prompt: Prompt(sample.turns.joined(separator: "\n---\n")),
            instructions: Instructions(instructions)
        )
    }

    public var output: ModelSampleOutput<EvalOutcome, TrajectoryExpectation> {
        ModelSampleOutput(value: nil, expectations: nil)
    }

    public var expected: EvalOutcome? { nil }
}

/// Per-sample expectations, all generic: field values, array contents,
/// forbidden fields. A task's graders decide which ones apply.
public struct EvalExpectation: Codable, Sendable, Equatable {
    /// `path → allowed values` — the value at the path must be one of them
    /// (strings compared case-insensitively).
    public var fields: [String: [String]]?
    /// `path → required elements` — the array at the path must contain each
    /// element (normalized: case-insensitive, articles stripped, substring
    /// match either way).
    public var contains: [String: [String]]?
    /// `path → forbidden elements` — nothing at the path may match any of
    /// them (same normalization as `contains`). The per-sample complement
    /// of `contains`: what this sample's answer must leave out.
    public var forbids: [String: [String]]?
    /// `path → candidate elements` — at least one of them must appear at the
    /// path (same normalization as `contains`). For an answer that may pick
    /// any of several right things (one of the foods just named).
    public var containsAny: [String: [String]]?
    /// Which `anyOf` choice (by object name) the answer should take.
    public var shape: String?

    public init(fields: [String: [String]]? = nil, contains: [String: [String]]? = nil, forbids: [String: [String]]? = nil, containsAny: [String: [String]]? = nil, shape: String? = nil) {
        self.fields = fields
        self.contains = contains
        self.forbids = forbids
        self.containsAny = containsAny
        self.shape = shape
    }
}

// MARK: - Outcome (what the engine produces)

/// The engine's record of one sample's run: every turn's raw text, parsed
/// value, provenance, and error, plus what the carry template produced.
public struct EvalOutcome: Codable, Sendable, Equatable {
    public var turns: [TurnOutcome]
    public var tier: String
    public var mode: String

    public struct TurnOutcome: Codable, Sendable, Equatable {
        /// The prompt actually sent (post-carry).
        public var prompt: String
        public var text: String?
        public var value: JSONValue?
        public var provider: String?
        public var error: String?
        /// The `ProviderError` case name when the provider failed.
        public var errorKind: String?
        public var repaired: Bool?
        public var nativeSchema: Bool?
        public var carriedFromCanonicalState: Bool?
        public var latencySeconds: Double?
        /// How many rate-limit waits preceded the answer (nil: none).
        public var rateLimitRetries: Int?

        public init(
            prompt: String, text: String? = nil, value: JSONValue? = nil, provider: String? = nil,
            error: String? = nil, errorKind: String? = nil, repaired: Bool? = nil,
            nativeSchema: Bool? = nil, carriedFromCanonicalState: Bool? = nil, latencySeconds: Double? = nil
        ) {
            self.prompt = prompt; self.text = text; self.value = value; self.provider = provider
            self.error = error; self.errorKind = errorKind; self.repaired = repaired
            self.nativeSchema = nativeSchema; self.carriedFromCanonicalState = carriedFromCanonicalState
            self.latencySeconds = latencySeconds
        }
    }

    public init(turns: [TurnOutcome], tier: String, mode: String) {
        self.turns = turns; self.tier = tier; self.mode = mode
    }

    public var last: TurnOutcome? { turns.last }
    public var failedTurn: TurnOutcome? { turns.first { $0.error != nil } }
}

// MARK: - Grader / judge specs (data)

/// A grader declared in the task file: a kind from the registry + params.
public struct GraderSpec: Codable, Sendable, Equatable {
    public var kind: String
    public var params: [String: JSONValue]?

    public init(kind: String, params: [String: JSONValue]? = nil) {
        self.kind = kind
        self.params = params
    }

    public func string(_ key: String) -> String? { params?[key]?.stringValue }
    public func strings(_ key: String) -> [String]? { params?[key]?.arrayValue?.compactMap(\.stringValue) }
    public func int(_ key: String) -> Int? { params?[key]?.numberValue.map { Int($0) } }
    public func double(_ key: String) -> Double? { params?[key]?.numberValue }
    public func bool(_ key: String) -> Bool? { params?[key]?.boolValue }
}

public struct JudgeSpec: Codable, Sendable, Equatable {
    public var instructions: String?
    public var dimensions: [Dimension]
    public struct Dimension: Codable, Sendable, Equatable {
        public var name: String
        public var description: String?
        /// `passFail` (default) or a numeric scale `[value: label]` given as
        /// `{"1":"...","5":"..."}`.
        public var scale: [String: String]?

        public init(name: String, description: String? = nil, scale: [String: String]? = nil) {
            self.name = name
            self.description = description
            self.scale = scale
        }
    }

    public init(instructions: String? = nil, dimensions: [Dimension]) {
        self.instructions = instructions
        self.dimensions = dimensions
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
public struct CarryTemplate: Codable, Sendable, Equatable {
    public var template: String

    public init(template: String) { self.template = template }

    public func render(prompt: String, previous: JSONValue?, previousRaw: String?) -> String {
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
    public static func plain(_ value: JSONValue) -> String {
        if let string = value.stringValue { return string }
        return value.serialized()
    }
}

// MARK: - JSON path

/// Dot paths with array indices and a `[]` wildcard: `items[].name`
/// collects every element's `name`; `compounds.protein` reads one member.
public enum JSONPath {
    public static func value(at path: String, in root: JSONValue) -> JSONValue? {
        let values = collect(at: path, in: root)
        if path.contains("[]") { return .array(values) }
        return values.first
    }

    /// All values the path addresses (one unless a `[]` wildcard is used).
    public static func collect(at path: String, in root: JSONValue) -> [JSONValue] {
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
