//
//  Graders.swift
//  VoltaSDKEvals
//
//  The deterministic grader registry. Every grader is generic — it reads
//  paths, patterns, and expectations from the task file — and produces one
//  framework `Metric` per sample. A client's acceptance rules are a
//  composition of these; none of them knows what a "ripieno" is.
//
//  Rules shared by all graders:
//  - A provider failure that is NOT model output (unsupported language,
//    unavailability, rate limit, network) makes every grader `ignore` the
//    sample; the engine counts it under `availability` instead, so pass
//    rates measure the model, never the infrastructure.
//  - Graders look at the LAST turn's output unless they say otherwise.
//

import Evaluations
import Foundation
import NaturalLanguage
import VoltaSDK

// MARK: - Registry

@available(iOS 27.0, macOS 27.0, *)
public enum Graders {

    /// The metric name the capability map reports as the task's pass rate.
    public static let passMetric = Metric("pass")
    /// Per-sample availability of the model itself (Phase 0's number).
    public static let availabilityMetric = Metric("model-available")
    /// Whether the on-device tier rejected the language (Phase 0, D-series).
    public static let languageAcceptedMetric = Metric("language-accepted")

    /// Every metric a task will report, for aggregation.
    public static func metrics(for task: EvalTask) -> [Metric] {
        [passMetric, availabilityMetric, languageAcceptedMetric]
            + task.graders.map { Metric(name(of: $0)) }
    }

    public static func name(of spec: GraderSpec) -> String {
        if let custom = spec.string("name") { return custom }
        if let path = spec.string("path") { return "\(spec.kind):\(path)" }
        return spec.kind
    }

    /// Runs every grader of the task on one outcome.
    public static func grade(task: EvalTask, sample: EvalSample, outcome: EvalOutcome) -> [Metric] {
        var metrics: [Metric] = []

        // Infrastructure first: availability and language are reported on
        // their own, and a non-model failure short-circuits the graders.
        let failure = outcome.failedTurn
        let kind = failure?.errorKind
        let languageRejected = kind == "unsupportedLanguage"
        let infrastructureFailure = kind.map(Self.isInfrastructureFailure) ?? false

        metrics.append(languageRejected
            ? languageAcceptedMetric.failing(rationale: failure?.error)
            : languageAcceptedMetric.passing())
        metrics.append(infrastructureFailure
            ? availabilityMetric.failing(rationale: failure?.error)
            : availabilityMetric.passing())

        if infrastructureFailure {
            let rationale = "not model output: \(failure?.error ?? kind ?? "unknown")"
            for spec in task.graders {
                metrics.append(Metric(name(of: spec)).ignore(rationale: rationale))
            }
            metrics.append(passMetric.ignore(rationale: rationale))
            return metrics
        }

        var allPassed = true
        var reasons: [String] = []
        for spec in task.graders {
            let metric = run(spec, task: task, sample: sample, outcome: outcome)
            metrics.append(metric)
            if case .failing = metric.value {
                allPassed = false
                reasons.append("\(metric.name): \(metric.rationale ?? "failed")")
            }
        }
        metrics.append(allPassed
            ? passMetric.passing()
            : passMetric.failing(rationale: reasons.joined(separator: " | ")))
        return metrics
    }

    /// Failures that say nothing about the model's ability at the task.
    public static func isInfrastructureFailure(_ errorKind: String) -> Bool {
        ["unsupportedLanguage", "noProviderAvailable", "rateLimited", "network",
         "unauthorized", "privacyRestricted", "cancelled", "contextWindowExceeded"]
            .contains(errorKind)
    }

    // MARK: Dispatch

    public static func run(_ spec: GraderSpec, task: EvalTask, sample: EvalSample, outcome: EvalOutcome) -> Metric {
        let metric = Metric(name(of: spec))
        guard let turn = outcome.last else {
            return metric.failing(rationale: "no turns")
        }
        // A model-side failure (malformed output after repair, guardrail,
        // generation error, empty) is a FAIL for content graders.
        if let error = turn.error, turn.text == nil {
            return metric.failing(rationale: "provider error: \(error)")
        }
        let text = turn.text ?? ""
        let value = turn.value

        switch spec.kind {
        case "json-only":
            return jsonOnly(metric, text: text, allowFences: spec.bool("allowFences") ?? true)
        case "schema":
            return schema(metric, spec: spec, task: task, value: value)
        case "required":
            return required(metric, spec: spec, value: value)
        case "forbidden-fields":
            return forbiddenFields(metric, spec: spec, value: value)
        case "expect-fields":
            return expectFields(metric, sample: sample, value: value)
        case "expect-contains":
            return expectContains(metric, sample: sample, value: value)
        case "expect-shape":
            return expectShape(metric, sample: sample, task: task, value: value)
        case "language":
            return language(metric, spec: spec, task: task, value: value, text: text)
        case "forbidden-patterns":
            return forbiddenPatterns(metric, spec: spec, value: value, text: text)
        case "elements-match":
            return elementsMatch(metric, spec: spec, value: value)
        case "claimed-action":
            return claimedAction(metric, spec: spec, value: value, text: text)
        case "retention":
            return retention(metric, spec: spec, outcome: outcome)
        default:
            return metric.ignore(rationale: "unknown grader kind \(spec.kind)")
        }
    }

    // MARK: Graders

    /// The whole reply is the JSON object (a bare code fence is tolerated by
    /// default, since the app's parser strips it; prose is not).
    public static func jsonOnly(_ metric: Metric, text: String, allowFences: Bool) -> Metric {
        do {
            let (_, surrounded) = try JSONValue.extractObject(from: text)
            if surrounded { return metric.failing(rationale: "text outside the JSON object") }
            if !allowFences, text.contains("```") { return metric.failing(rationale: "code fence around the JSON") }
            return metric.passing()
        } catch StructuredOutputError.noJSONFound {
            return metric.failing(rationale: "no JSON object: \(text.prefix(80))")
        } catch {
            return metric.failing(rationale: "unparseable JSON: \(error)")
        }
    }

    /// Validates against the task schema (or a grader-supplied one).
    public static func schema(_ metric: Metric, spec: GraderSpec, task: EvalTask, value: JSONValue?) -> Metric {
        guard let schema = task.schema else { return metric.ignore(rationale: "task has no schema") }
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        let violations = schema.validate(value)
        return violations.isEmpty
            ? metric.passing()
            : metric.failing(rationale: violations.prefix(4).map(\.description).joined(separator: "; "))
    }

    /// Fields present and non-empty; arrays may carry `min`/`max` counts
    /// via `paths` entries like `completions:1:3`.
    public static func required(_ metric: Metric, spec: GraderSpec, value: JSONValue?) -> Metric {
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        var missing: [String] = []
        for entry in spec.strings("paths") ?? [] {
            let parts = entry.split(separator: ":").map(String.init)
            let path = parts[0]
            guard let field = JSONPath.value(at: path, in: value) else { missing.append("\(path) missing"); continue }
            switch field {
            case .string(let string) where string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                missing.append("\(path) blank")
            case .array(let items):
                let minimum = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                let maximum = parts.count > 2 ? Int(parts[2]) : nil
                if items.count < minimum { missing.append("\(path) has \(items.count) < \(minimum)") }
                if let maximum, items.count > maximum { missing.append("\(path) has \(items.count) > \(maximum)") }
            case .null:
                missing.append("\(path) null")
            default:
                break
            }
        }
        return missing.isEmpty ? metric.passing() : metric.failing(rationale: missing.joined(separator: "; "))
    }

    /// The listed fields must be absent (or empty).
    public static func forbiddenFields(_ metric: Metric, spec: GraderSpec, value: JSONValue?) -> Metric {
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        let present = (spec.strings("paths") ?? []).filter { path in
            guard let field = JSONPath.value(at: path, in: value) else { return false }
            if let items = field.arrayValue { return !items.isEmpty }
            if let members = field.objectValue { return !members.isEmpty }
            return !field.isNull
        }
        return present.isEmpty ? metric.passing() : metric.failing(rationale: "present: \(present.joined(separator: ", "))")
    }

    /// Per-sample `expect.fields`: each path's value must be one of the
    /// allowed values.
    public static func expectFields(_ metric: Metric, sample: EvalSample, value: JSONValue?) -> Metric {
        guard let fields = sample.expect?.fields, !fields.isEmpty else {
            return metric.ignore(rationale: "no field expectations")
        }
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        var wrong: [String] = []
        for (path, allowed) in fields.sorted(by: { $0.key < $1.key }) {
            let actual = JSONPath.value(at: path, in: value).map(CarryTemplate.plain) ?? "<missing>"
            if !allowed.contains(where: { $0.caseInsensitiveCompare(actual) == .orderedSame }) {
                wrong.append("\(path)=\(actual) not in \(allowed)")
            }
        }
        return wrong.isEmpty ? metric.passing() : metric.failing(rationale: wrong.joined(separator: "; "))
    }

    /// Per-sample `expect.contains`: the array at each path must contain
    /// every listed element (normalized).
    public static func expectContains(_ metric: Metric, sample: EvalSample, value: JSONValue?) -> Metric {
        guard let contains = sample.expect?.contains, !contains.isEmpty else {
            return metric.ignore(rationale: "no containment expectations")
        }
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        var missing: [String] = []
        for (path, required) in contains.sorted(by: { $0.key < $1.key }) {
            let items = (JSONPath.value(at: path, in: value)?.arrayValue ?? [])
                .map { TextNormalizer.normalize(CarryTemplate.plain($0)) }
            for wanted in required {
                let needle = TextNormalizer.normalize(wanted)
                if !items.contains(where: { $0.contains(needle) || needle.contains($0) && !$0.isEmpty }) {
                    missing.append("\(path) lacks \"\(wanted)\" (has \(items))")
                }
            }
        }
        return missing.isEmpty ? metric.passing() : metric.failing(rationale: missing.joined(separator: "; "))
    }

    /// Per-sample `expect.shape`: which `anyOf` choice (object name) the
    /// answer must match.
    public static func expectShape(_ metric: Metric, sample: EvalSample, task: EvalTask, value: JSONValue?) -> Metric {
        guard let wanted = sample.expect?.shape else { return metric.ignore(rationale: "no shape expectation") }
        guard let value else { return metric.failing(rationale: "no parsed JSON") }
        guard case .anyOf(_, _, let choices)? = task.schema else {
            return metric.ignore(rationale: "task schema is not anyOf")
        }
        guard let choice = choices.first(where: { $0.rootName == wanted }) else {
            return metric.ignore(rationale: "no choice named \(wanted)")
        }
        // Shape match = the choice's own required properties are present
        // (validity is the schema grader's job).
        if case .object(_, _, let properties) = choice {
            let required = properties.filter { !$0.isOptional }.map(\.name)
            let present = required.filter { value[$0] != nil && !(value[$0]?.isNull ?? true) }
            if present.count == required.count { return metric.passing() }
            return metric.failing(rationale: "expected shape \(wanted); missing \(Set(required).subtracting(present).sorted())")
        }
        return choice.validate(value).isEmpty ? metric.passing() : metric.failing(rationale: "expected shape \(wanted)")
    }

    /// The prose at `path` (or the whole text) is in the task's language.
    /// Short strings are ignored (language detection needs a few words).
    public static func language(_ metric: Metric, spec: GraderSpec, task: EvalTask, value: JSONValue?, text: String) -> Metric {
        guard let expected = spec.string("language") ?? task.language else {
            return metric.ignore(rationale: "no language expectation")
        }
        let sample: String
        if let path = spec.string("path") {
            guard let value, let field = JSONPath.value(at: path, in: value) else {
                return metric.failing(rationale: "\(path) missing")
            }
            sample = CarryTemplate.plain(field)
        } else {
            sample = text
        }
        guard sample.split(separator: " ").count >= (spec.int("minWords") ?? 4) else {
            return metric.ignore(rationale: "too short to detect")
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let dominant = recognizer.dominantLanguage?.rawValue else {
            return metric.ignore(rationale: "language undetermined")
        }
        return dominant.hasPrefix(expected)
            ? metric.passing()
            : metric.failing(rationale: "detected \(dominant), expected \(expected): \(sample.prefix(60))")
    }

    /// None of the regex patterns may match the field at `path` (or the
    /// whole text). Case-insensitive.
    public static func forbiddenPatterns(_ metric: Metric, spec: GraderSpec, value: JSONValue?, text: String) -> Metric {
        let target: String
        if let path = spec.string("path") {
            guard let value, let field = JSONPath.value(at: path, in: value) else {
                return metric.failing(rationale: "\(path) missing")
            }
            target = CarryTemplate.plain(field)
        } else {
            target = text
        }
        let hits = (spec.strings("patterns") ?? []).filter { pattern in
            (try? Regex(pattern).ignoresCase().firstMatch(in: target)) != nil
        }
        return hits.isEmpty ? metric.passing() : metric.failing(rationale: "matched \(hits)")
    }

    /// At least `minFraction` (default 1.0) of the array's string elements
    /// match the regex.
    public static func elementsMatch(_ metric: Metric, spec: GraderSpec, value: JSONValue?) -> Metric {
        guard let path = spec.string("path"), let pattern = spec.string("pattern") else {
            return metric.ignore(rationale: "elements-match needs path + pattern")
        }
        guard let value, let items = JSONPath.value(at: path, in: value)?.arrayValue else {
            return metric.failing(rationale: "\(path) missing")
        }
        guard !items.isEmpty else { return metric.failing(rationale: "\(path) empty") }
        guard let regex = try? Regex(pattern).ignoresCase() else {
            return metric.ignore(rationale: "bad pattern")
        }
        let matching = items.filter { (try? regex.firstMatch(in: CarryTemplate.plain($0))) != nil }.count
        let fraction = Double(matching) / Double(items.count)
        let minimum = spec.double("minFraction") ?? 1.0
        return fraction >= minimum
            ? metric.passing()
            : metric.failing(rationale: "\(matching)/\(items.count) elements match")
    }

    /// The reply claims an action in prose (any pattern matches the text)
    /// while the action field is absent — the "said added, didn't add" case.
    public static func claimedAction(_ metric: Metric, spec: GraderSpec, value: JSONValue?, text: String) -> Metric {
        guard let field = spec.string("field") else { return metric.ignore(rationale: "claimed-action needs field") }
        if let value, let action = JSONPath.value(at: field, in: value), !(action.arrayValue?.isEmpty ?? false) {
            return metric.passing()
        }
        let claimed = (spec.strings("patterns") ?? []).contains { pattern in
            (try? Regex(pattern).ignoresCase().firstMatch(in: text)) != nil
        }
        return claimed
            ? metric.failing(rationale: "claims the action in prose without \(field)")
            : metric.passing()
    }

    /// Multi-turn retention: the last turn keeps what earlier turns
    /// established. `keepItems` = a `[]` path whose set of (normalized)
    /// values must not shrink; `keepStates` = an object path whose members
    /// must not drop from `from` to `notTo`.
    public static func retention(_ metric: Metric, spec: GraderSpec, outcome: EvalOutcome) -> Metric {
        let parsed = outcome.turns.compactMap(\.value)
        guard parsed.count >= 2, let first = outcome.turns.first?.value, let last = outcome.last?.value else {
            return metric.failing(rationale: "needs a parsed value on both turns (got \(parsed.count))")
        }
        var problems: [String] = []
        if let path = spec.string("keepItems") {
            let before = Set(JSONPath.collect(at: path, in: first).map { TextNormalizer.normalize(CarryTemplate.plain($0)) })
            let after = Set(JSONPath.collect(at: path, in: last).map { TextNormalizer.normalize(CarryTemplate.plain($0)) })
            let lost = before.filter { item in !after.contains(where: { $0.contains(item) || item.contains($0) }) }
            if !lost.isEmpty { problems.append("dropped \(lost.sorted())") }
        }
        if let statesPath = spec.string("keepStates"),
           let from = spec.string("from"), let notTo = spec.string("notTo"),
           let before = JSONPath.value(at: statesPath, in: first)?.objectValue,
           let after = JSONPath.value(at: statesPath, in: last)?.objectValue {
            for (key, state) in before where state.stringValue?.lowercased() == from.lowercased() {
                if after[key]?.stringValue?.lowercased() == notTo.lowercased() {
                    problems.append("\(key) dropped from \(from) to \(notTo)")
                }
            }
        }
        return problems.isEmpty ? metric.passing() : metric.failing(rationale: problems.joined(separator: "; "))
    }
}

// MARK: - Normalization for item matching

public enum TextNormalizer {
    /// Lowercased, diacritics folded, leading articles/partitives stripped,
    /// punctuation removed — enough to match "il latte" against "latte".
    public static func normalize(_ text: String) -> String {
        var value = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        value = value.replacingOccurrences(of: "[^\\p{L}\\p{N} ]", with: " ", options: .regularExpression)
        let articles = ["il", "lo", "la", "le", "gli", "i", "un", "una", "uno", "del", "della", "dello", "dei", "degli", "delle",
                        "the", "a", "an", "some", "of", "di", "d"]
        var words = value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        while let first = words.first, articles.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }
}
