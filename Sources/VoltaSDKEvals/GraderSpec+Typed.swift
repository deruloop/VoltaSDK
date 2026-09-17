//
//  GraderSpec+Typed.swift
//  VoltaSDKEvals
//
//  Typed constructors for the grader registry. A task file names graders
//  as strings (`{"kind": "language", "params": {"path": "note"}}`); in
//  Swift the same graders are built with these functions, so a misspelled
//  kind or parameter is a compile error instead of a silent no-op at run
//  time. Each constructor produces exactly the JSON the reference document
//  (docs/evals/TASK-FORMAT.md) describes.
//

import Foundation
import VoltaSDK

extension GraderSpec {

    /// Every grader kind the engine knows, in registry order.
    public static let knownKinds: [String] = [
        "json-only", "schema", "required", "forbidden-fields", "expect-fields",
        "expect-contains", "expect-shape", "language", "forbidden-patterns",
        "elements-match", "mentions", "claimed-action", "retention",
    ]

    /// The reply is one JSON object with nothing around it. A bare code
    /// fence is tolerated unless `allowFences` is false.
    public static func jsonOnly(allowFences: Bool = true, name: String? = nil) -> GraderSpec {
        make("json-only", ["allowFences": .bool(allowFences)], name: name)
    }

    /// The parsed value validates against the task's schema.
    public static func schema(name: String? = nil) -> GraderSpec {
        make("schema", [:], name: name)
    }

    /// Fields present and non-blank; an array entry may carry bounds as
    /// `"completions:1:3"` (min 1, max 3) or `"items:1"` (min 1).
    public static func required(paths: [String], name: String? = nil) -> GraderSpec {
        make("required", ["paths": .array(paths.map(JSONValue.string))], name: name)
    }

    /// None of the paths is present (or non-empty).
    public static func forbiddenFields(paths: [String], name: String? = nil) -> GraderSpec {
        make("forbidden-fields", ["paths": .array(paths.map(JSONValue.string))], name: name)
    }

    /// Per-sample `expect.fields`: each path's value is one of the allowed
    /// values. Samples without `expect.fields` are ignored by this grader.
    public static func expectFields(name: String? = nil) -> GraderSpec {
        make("expect-fields", [:], name: name)
    }

    /// Per-sample `expect.contains`: each array holds every required
    /// element (normalized: case-insensitive, articles stripped).
    public static func expectContains(name: String? = nil) -> GraderSpec {
        make("expect-contains", [:], name: name)
    }

    /// Per-sample `expect.shape`: the answer takes the named `anyOf` choice.
    public static func expectShape(name: String? = nil) -> GraderSpec {
        make("expect-shape", [:], name: name)
    }

    /// The prose at `path` (or the whole reply) is in `language` (BCP-47;
    /// defaults to the task's `language`). Texts shorter than `minWords`
    /// are ignored: language detection needs a few words.
    public static func language(path: String? = nil, language: String? = nil, minWords: Int? = nil, name: String? = nil) -> GraderSpec {
        var params: [String: JSONValue] = [:]
        if let path { params["path"] = .string(path) }
        if let language { params["language"] = .string(language) }
        if let minWords { params["minWords"] = .number(Double(minWords)) }
        return make("language", params, name: name)
    }

    /// No regular expression in `patterns` matches the text at `path` (or
    /// the whole reply). Case-insensitive.
    public static func forbiddenPatterns(path: String? = nil, patterns: [String], name: String? = nil) -> GraderSpec {
        var params: [String: JSONValue] = ["patterns": .array(patterns.map(JSONValue.string))]
        if let path { params["path"] = .string(path) }
        return make("forbidden-patterns", params, name: name)
    }

    /// At least `minFraction` (default 1.0) of the array's elements match
    /// the regular expression.
    public static func elementsMatch(path: String, pattern: String, minFraction: Double? = nil, name: String? = nil) -> GraderSpec {
        var params: [String: JSONValue] = ["path": .string(path), "pattern": .string(pattern)]
        if let minFraction { params["minFraction"] = .number(minFraction) }
        return make("elements-match", params, name: name)
    }

    /// The reply does not claim an action in prose (any pattern matches the
    /// text) while `field` is absent or empty.
    public static func claimedAction(field: String, patterns: [String], name: String? = nil) -> GraderSpec {
        make("claimed-action", ["field": .string(field), "patterns": .array(patterns.map(JSONValue.string))], name: name)
    }

    /// Multi-turn retention: the values at `keepItems` (a `[]` path) on the
    /// last turn include every value from the first turn; and no member of
    /// the object at `keepStates` drops from `from` to `notTo`.
    /// The text at `path` names at least one element of the array at `of`.
    public static func mentions(path: String, of: String, all: Bool = false, name: String? = nil) -> GraderSpec {
        var params: [String: JSONValue] = ["path": .string(path), "of": .string(of)]
        if all { params["all"] = .bool(true) }
        return make("mentions", params, name: name)
    }

    public static func retention(keepItems: String? = nil, keepStates: String? = nil, from: String? = nil, notTo: String? = nil, name: String? = nil) -> GraderSpec {
        var params: [String: JSONValue] = [:]
        if let keepItems { params["keepItems"] = .string(keepItems) }
        if let keepStates { params["keepStates"] = .string(keepStates) }
        if let from { params["from"] = .string(from) }
        if let notTo { params["notTo"] = .string(notTo) }
        return make("retention", params, name: name)
    }

    /// The same grader, applied only to samples whose typed input matches
    /// the pattern (case-insensitive); other samples ignore it.
    public func when(promptMatches pattern: String) -> GraderSpec {
        var params = self.params ?? [:]
        params["whenPrompt"] = .string(pattern)
        return GraderSpec(kind: kind, params: params)
    }

    private static func make(_ kind: String, _ params: [String: JSONValue], name: String?) -> GraderSpec {
        var params = params
        if let name { params["name"] = .string(name) }
        return GraderSpec(kind: kind, params: params.isEmpty ? nil : params)
    }
}

// MARK: - Task validation

/// One problem found in a task, with the path to the offending field.
public struct TaskProblem: Sendable, Equatable, CustomStringConvertible {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

extension EvalTask {

    /// Checks the task beyond what decoding can: unknown grader kinds,
    /// missing grader parameters, duplicate or empty samples, expectations
    /// that name fields the schema does not have, a carry template on a
    /// single-turn task, a `shape` that names no `anyOf` choice. Empty
    /// result = the task is well-formed. `load(from:)` runs this and throws
    /// `EvalEngineError.invalidTask` when anything is reported.
    public func validate() -> [TaskProblem] {
        var problems: [TaskProblem] = []
        func report(_ path: String, _ message: String) { problems.append(TaskProblem(path: path, message: message)) }

        if id.isEmpty { report("id", "must not be empty") }
        if instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { report("instructions", "must not be empty") }
        if graders.isEmpty { report("graders", "list at least one grader") }
        if samples.isEmpty { report("samples", "list at least one sample") }

        // Graders: known kinds, required parameters.
        for (index, grader) in graders.enumerated() {
            let path = "graders[\(index)]"
            guard GraderSpec.knownKinds.contains(grader.kind) else {
                report(path + ".kind", "unknown grader \"\(grader.kind)\"; known: \(GraderSpec.knownKinds.joined(separator: ", "))")
                continue
            }
            func need(_ key: String) {
                if grader.params?[key] == nil { report(path + ".params.\(key)", "\(grader.kind) needs \"\(key)\"") }
            }
            switch grader.kind {
            case "required", "forbidden-fields": need("paths")
            case "forbidden-patterns": need("patterns")
            case "elements-match": need("path"); need("pattern")
            case "claimed-action": need("field"); need("patterns")
            case "retention":
                if grader.params?["keepItems"] == nil, grader.params?["keepStates"] == nil {
                    report(path + ".params", "retention needs \"keepItems\" and/or \"keepStates\"")
                }
                if grader.params?["keepStates"] != nil, grader.params?["from"] == nil || grader.params?["notTo"] == nil {
                    report(path + ".params", "retention with \"keepStates\" needs \"from\" and \"notTo\"")
                }
            case "schema", "expect-shape":
                if schema == nil { report(path, "\(grader.kind) needs the task to declare a schema") }
            case "language":
                if grader.params?["language"] == nil, language == nil {
                    report(path, "language needs a task-level \"language\" or a \"language\" parameter")
                }
            default: break
            }
        }

        // Samples: ids unique, turns present, shapes known.
        var seen = Set<String>()
        let choiceNames: [String]? = {
            if case .anyOf(_, _, let choices)? = schema { return choices.map(\.rootName) }
            return nil
        }()
        let usesRetention = graders.contains { $0.kind == "retention" }
        for (index, sample) in samples.enumerated() {
            let path = "samples[\(index)]"
            if sample.id.isEmpty { report(path + ".id", "must not be empty") }
            if !seen.insert(sample.id).inserted { report(path + ".id", "duplicate id \"\(sample.id)\"") }
            if sample.turns.isEmpty || sample.turns.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                report(path + ".turns", "needs one or more non-empty turns")
            }
            if usesRetention, sample.turns.count < 2 {
                report(path + ".turns", "the retention grader needs at least two turns")
            }
            if let shape = sample.expect?.shape {
                if let choiceNames, !choiceNames.contains(shape) {
                    report(path + ".expect.shape", "\"\(shape)\" is not one of the schema's anyOf choices \(choiceNames)")
                } else if choiceNames == nil {
                    report(path + ".expect.shape", "the task schema is not an anyOf, so a shape cannot be expected")
                }
            }
        }
        if carry != nil, !samples.contains(where: { $0.turns.count > 1 }) {
            report("carry", "a carry template needs at least one multi-turn sample")
        }
        return problems
    }
}
