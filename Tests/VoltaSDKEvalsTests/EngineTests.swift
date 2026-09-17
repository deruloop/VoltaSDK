//
//  EngineTests.swift
//  VoltaSDKEvalsTests
//
//  The engine under test with NO real model: schema data round-trips,
//  validation, lenient extraction, the carry template, every grader
//  against scripted outputs (including the four real failure shapes a
//  client reported — recreated here on generic data), the framework run
//  over a mock provider, the capability map, and Cohen's kappa. CI-safe.
//

import Evaluations
import Foundation
import Synchronization
import TabularData
import Testing
import VoltaSDK
import VoltaSDKEvals

// MARK: - Fixtures

/// The example tasks ship inside the library's resource bundle.
enum Fixtures {
    static func task(_ name: String) throws -> EvalTask {
        let id = name == "example-task.json" ? "example.city-facts" : "example.packing-list"
        return try EvalTask.example(id)
    }
}

// MARK: - Schema as data

@Suite("Output schema (D21)")
struct OutputSchemaTests {

    @Test("A task's schema round-trips through JSON with property order intact")
    func codableRoundTrip() throws {
        let task = try Fixtures.task("example-task.json")
        guard case .object(let name, _, let properties)? = task.schema else {
            Issue.record("expected an object schema"); return
        }
        #expect(name == "CityFacts")
        #expect(properties.map(\.name) == ["city", "country", "continent", "note"])
        let data = try JSONEncoder().encode(task.schema)
        let decoded = try JSONDecoder().decode(OutputSchema.self, from: data)
        #expect(decoded == task.schema)
    }

    @Test("Validation names every violation with its path")
    func validation() throws {
        let schema = try #require(try Fixtures.task("example-task.json").schema)
        let good: JSONValue = ["city": "Rome", "country": "Italy", "continent": "Europe", "note": "Eternal."]
        #expect(schema.validate(good).isEmpty)
        let bad: JSONValue = ["city": "Rome", "continent": "Mars", "note": 3]
        let violations = schema.validate(bad).map(\.description)
        #expect(violations.contains("$.country: missing required property"))
        #expect(violations.contains { $0.hasPrefix("$.continent:") && $0.contains("Mars") })
        #expect(violations.contains { $0.hasPrefix("$.note:") && $0.contains("expected a string") })
    }

    @Test("anyOf accepts either shape and reports the closest on failure")
    func anyOf() {
        let schema = OutputSchema.anyOf(name: "Reply", choices: [
            .object(name: "A", properties: [.init("a", .string())]),
            .object(name: "B", properties: [.init("b", .array(of: .string(), minimumCount: 1))]),
        ])
        #expect(schema.validate(["a": "x"]).isEmpty)
        #expect(schema.validate(["b": ["x"]]).isEmpty)
        #expect(schema.validate(["b": []]).first?.description.contains("matches none") == true)
    }

    @Test("Vendor dialects: strict objects everywhere, patterns only where supported")
    func dialects() {
        let schema = OutputSchema.object(name: "T", properties: [
            .init("color", .string(pattern: "^#[0-9A-Fa-f]{6}$")),
            .init("tags", .array(of: .string(), minimumCount: 1), isOptional: true),
        ])
        let anthropic = schema.jsonSchema(dialect: .anthropic)
        #expect(anthropic["additionalProperties"] == false)
        #expect(anthropic["required"] == ["color"])
        #expect(anthropic["properties"]?["color"]?["pattern"] == nil)
        let openAI = schema.jsonSchema(dialect: .openAI)
        #expect(openAI["required"] == ["color", "tags"])
        #expect(openAI["properties"]?["color"]?["pattern"] == "^#[0-9A-Fa-f]{6}$")
        #expect(openAI["properties"]?["tags"]?["type"] == ["array", "null"])
        let generic = schema.jsonSchema(dialect: .generic)
        #expect(generic["properties"]?["tags"]?["minItems"] == 1)
    }

    @Test("Lenient extraction tolerates fences and reports surrounding prose")
    func extraction() throws {
        let fenced = try JSONValue.extractObject(from: "```json\n{\"a\":1}\n```")
        #expect(fenced.value == ["a": 1])
        #expect(fenced.hadSurroundingText == false)
        let prose = try JSONValue.extractObject(from: "Sure! {\"a\":1} Enjoy.")
        #expect(prose.hadSurroundingText == true)
        #expect(throws: StructuredOutputError.noJSONFound) { try JSONValue.extractObject(from: "no json here") }
    }
}

// MARK: - Structured output through the chain

@Suite("Structured output through the chain (D21)")
struct StructuredChainTests {
    let schema = OutputSchema.object(name: "Answer", properties: [
        .init("value", .string(enumeration: ["yes", "no"])),
    ])

    @Test("A conforming first answer needs no repair")
    func firstAnswer() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, structuredAnswers: ["{\"value\":\"yes\"}"])
        ])
        let response = try await kit.respondStructured(to: "?", schema: schema)
        #expect(response.value == ["value": "yes"])
        #expect(response.repaired == false)
        #expect(response.nativeSchema == true)
    }

    @Test("A violation triggers one repair turn carrying the critique as history")
    func repair() async throws {
        let seen = Mutex<[String]>([])
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice,
                         structuredAnswers: ["{\"value\":\"maybe\"}", "{\"value\":\"no\"}"]) { prompt, _, history in
                seen.withLock { $0.append("\(history.count):\(prompt.prefix(30))") }
            }
        ])
        let response = try await kit.respondStructured(to: "?", schema: schema)
        #expect(response.value == ["value": "no"])
        #expect(response.repaired == true)
        let calls = seen.withLock { $0 }
        #expect(calls.count == 2)
        #expect(calls[1].hasPrefix("2:Your previous reply did not"))
    }

    @Test("Still malformed after repair: typed failure, and the chain moves on")
    func fallbackOnMalformed() async throws {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, privacyLevel: .onDevice, structuredAnswers: ["not json at all"]),
            MockProvider(identifier: .openAI, privacyLevel: .external, structuredAnswers: ["{\"value\":\"yes\"}"]),
        ])
        let response = try await kit.respondStructured(to: "?", schema: schema)
        #expect(response.provider == .openAI)

        let alone = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, structuredAnswers: ["{\"value\":\"maybe\"}"])
        ])
        await #expect(throws: ProviderError.self) {
            try await alone.respondStructured(to: "?", schema: schema, repair: .none)
        }
    }

    @Test("Providers without a native mode get the schema in their instructions")
    func promptedFallback() async throws {
        let seen = Mutex<String?>(nil)
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("{\"value\":\"yes\"}")) { _, instructions, _ in
                seen.withLock { $0 = instructions }
            }
        ])
        let response = try await kit.respondStructured(to: "?", instructions: "Be brief.", schema: schema)
        #expect(response.nativeSchema == false)
        #expect(seen.withLock { $0 }?.contains("JSON Schema") == true)
        #expect(seen.withLock { $0 }?.hasPrefix("Be brief.") == true)
    }

    @Test("Typed convenience decodes into the app's type")
    func typed() async throws {
        struct Answer: Decodable, Equatable { let value: String }
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, structuredAnswers: ["{\"value\":\"yes\"}"])
        ])
        let answer: Answer = try await kit.respond(to: "?", schema: schema)
        #expect(answer == Answer(value: "yes"))
    }
}

// MARK: - Carry template + JSON path

@Suite("Carry template and JSON paths")
struct CarryTests {
    @Test("Placeholders render from the previous value; wildcards collect")
    func render() {
        let previous: JSONValue = [
            "items": [["name": "pollo", "compound": "protein"], ["name": "riso", "compound": "fiber"]],
            "compounds": ["protein": "present", "fiber": "light"],
        ]
        let template = CarryTemplate(template: "So far: [{{previous.items|join:{name} ({compound})|sep:, }}]. State {{previous.compounds}}. Now: {{prompt}}")
        let rendered = template.render(prompt: "aggiungo olio", previous: previous, previousRaw: nil)
        #expect(rendered == "So far: [pollo (protein), riso (fiber)]. State {\"fiber\":\"light\",\"protein\":\"present\"}. Now: aggiungo olio")
        #expect(JSONPath.value(at: "items[].name", in: previous) == ["pollo", "riso"])
        #expect(JSONPath.value(at: "items[1].compound", in: previous) == "fiber")
        #expect(JSONPath.value(at: "compounds.protein", in: previous) == "present")
    }
}

// MARK: - Graders on scripted outputs

@Suite("Graders")
struct GraderTests {
    /// A generic task shaped like a two-shape assistant (a record, or an
    /// action list), with the graders a client would compose.
    let task: EvalTask = {
        var task = EvalTask(
            id: "t", title: "t", schemaVersion: "v1",
            instructions: "Reply with ONLY JSON.",
            language: "it",
            schema: .anyOf(name: "Reply", choices: [
                .object(name: "Record", properties: [
                    .init("title", .string()),
                    .init("items", .array(of: .object(name: "Item", properties: [
                        .init("name", .string()),
                        .init("kind", .string(enumeration: ["a", "b"])),
                        .init("color", .string(pattern: "^#[0-9A-Fa-f]{6}$")),
                    ]))),
                    .init("states", .object(name: "States", properties: [
                        .init("a", .string(enumeration: ["present", "light", "missing"])),
                        .init("b", .string(enumeration: ["present", "light", "missing"])),
                    ])),
                    .init("note", .string()),
                ]),
                .object(name: "Action", properties: [
                    .init("add", .array(of: .string(), minimumCount: 1)),
                    .init("note", .string()),
                ]),
            ]),
            carry: nil,
            graders: [
                GraderSpec(kind: "json-only"),
                GraderSpec(kind: "schema"),
                GraderSpec(kind: "required", params: ["paths": ["items:1", "note"]]),
                GraderSpec(kind: "expect-fields"),
                GraderSpec(kind: "expect-contains"),
                GraderSpec(kind: "expect-shape"),
                GraderSpec(kind: "forbidden-fields", params: ["paths": ["items"], "name": "no-record-fields"]),
                GraderSpec(kind: "language", params: ["path": "note"]),
                GraderSpec(kind: "forbidden-patterns", params: ["path": "note", "patterns": ["\\d", "calorie"]]),
                GraderSpec(kind: "claimed-action", params: ["field": "add", "patterns": ["aggiunt", "added"]]),
                GraderSpec(kind: "retention", params: ["keepItems": "items[].name", "keepStates": "states", "from": "present", "notTo": "missing"]),
            ],
            judge: nil,
            samples: []
        )
        task.samples = []
        return task
    }()

    func outcome(_ texts: [String], errorKind: String? = nil) -> EvalOutcome {
        EvalOutcome(
            turns: texts.map { text in
                EvalOutcome.TurnOutcome(
                    prompt: "p", text: errorKind == nil ? text : nil,
                    value: (try? JSONValue.extractObject(from: text))?.value,
                    provider: "mock", error: errorKind, errorKind: errorKind
                )
            },
            tier: "mock", mode: "raw"
        )
    }

    @available(iOS 27.0, macOS 27.0, *)
    func metric(_ name: String, in metrics: [Metric]) -> Metric? { metrics.first { $0.name == name } }

    @Test("F1 shape: prose that claims the action without the action JSON fails")
    func claimedActionWithoutJSON() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let sample = EvalSample(id: "s", turns: ["aggiungi cetrioli"], expect: EvalExpectation(contains: ["add": ["cetrioli"]], shape: "Action"))
        let metrics = Graders.grade(task: task, sample: sample, outcome: outcome(["I cetrioli sono stati aggiunti alla lista."]))
        #expect(metric("json-only", in: metrics)?.value == .failing)
        #expect(metric("claimed-action", in: metrics)?.value == .failing)
        #expect(metric("pass", in: metrics)?.value == .failing)
    }

    @Test("F2 shape: valid JSON with every field empty fails the required grader, not the schema")
    func emptyFields() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let text = "{\"title\":\"x\",\"items\":[],\"states\":{\"a\":\"missing\",\"b\":\"missing\"},\"note\":\"Buon appetito, prova ad aggiungere un po' di pomodoro.\"}"
        let sample = EvalSample(id: "s", turns: ["crackers"], expect: EvalExpectation(fields: ["states.a": ["present", "light"]]))
        let metrics = Graders.grade(task: task, sample: sample, outcome: outcome([text]))
        #expect(metric("schema", in: metrics)?.value == .passing)
        #expect(metric("required:items:1", in: metrics) == nil)   // named by kind + first path
        #expect(metric("required", in: metrics)?.value == .failing)
        #expect(metric("expect-fields", in: metrics)?.value == .failing)
        #expect(metric("language:note", in: metrics)?.value == .passing)
    }

    @Test("F3/F4 shapes: no JSON at all, or an echo of the request, fail everything")
    func noJSON() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let sample = EvalSample(id: "s", turns: ["pesca"], expect: nil)
        for text in ["Un frutto dolce che aggiunge calore alla tavola.", "Aggiungi cetrioli, yogurt e pane alla lista della spesa."] {
            let metrics = Graders.grade(task: task, sample: sample, outcome: outcome([text]))
            #expect(metric("pass", in: metrics)?.value == .failing)
            #expect(metric("model-available", in: metrics)?.value == .passing)
        }
    }

    @Test("A good record passes, with the content checks doing real work")
    func goodRecord() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let text = "{\"title\":\"Pollo e riso\",\"items\":[{\"name\":\"pollo\",\"kind\":\"a\",\"color\":\"#D2B48C\"}],\"states\":{\"a\":\"present\",\"b\":\"missing\"},\"note\":\"Un piatto semplice e caldo che sa di casa, perfetto per la sera.\"}"
        let sample = EvalSample(id: "s", turns: ["pollo"], expect: EvalExpectation(fields: ["states.a": ["present", "light"]], shape: "Record"))
        let metrics = Graders.grade(task: task, sample: sample, outcome: outcome([text]))
        for name in ["json-only", "schema", "required", "expect-fields", "expect-shape", "language:note", "forbidden-patterns:note", "claimed-action"] {
            #expect(metric(name, in: metrics)?.value == .passing, "\(name)")
        }
        #expect(metric("no-record-fields", in: metrics)?.value == .failing)   // by construction: a record HAS items
        #expect(metric("expect-contains", in: metrics)?.value == .ignore)
        #expect(metric("retention", in: metrics)?.value == .failing)         // single turn
    }

    @Test("Numbers and diet words in the note are caught")
    func forbiddenPatterns() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let text = "{\"title\":\"x\",\"items\":[{\"name\":\"a\",\"kind\":\"a\",\"color\":\"#000000\"}],\"states\":{\"a\":\"present\",\"b\":\"light\"},\"note\":\"Solo 200 calorie, ottimo per la dieta.\"}"
        let metrics = Graders.grade(task: task, sample: EvalSample(id: "s", turns: ["x"]), outcome: outcome([text]))
        #expect(metric("forbidden-patterns:note", in: metrics)?.value == .failing)
    }

    @Test("Retention: items kept and no present state dropping to missing")
    func retention() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let first = "{\"title\":\"x\",\"items\":[{\"name\":\"Pollo\",\"kind\":\"a\",\"color\":\"#000000\"}],\"states\":{\"a\":\"present\",\"b\":\"missing\"},\"note\":\"ok\"}"
        let kept = "{\"title\":\"x\",\"items\":[{\"name\":\"pollo\",\"kind\":\"a\",\"color\":\"#000000\"},{\"name\":\"riso\",\"kind\":\"b\",\"color\":\"#000000\"}],\"states\":{\"a\":\"present\",\"b\":\"present\"},\"note\":\"ok\"}"
        let lost = "{\"title\":\"x\",\"items\":[{\"name\":\"riso\",\"kind\":\"b\",\"color\":\"#000000\"}],\"states\":{\"a\":\"missing\",\"b\":\"present\"},\"note\":\"ok\"}"
        let sample = EvalSample(id: "s", turns: ["pollo", "riso"])
        let good = Graders.grade(task: task, sample: sample, outcome: outcome([first, kept]))
        #expect(metric("retention", in: good)?.value == .passing)
        let bad = Graders.grade(task: task, sample: sample, outcome: outcome([first, lost]))
        #expect(metric("retention", in: bad)?.value == .failing)
        #expect(metric("retention", in: bad)?.rationale?.contains("pollo") == true)
        #expect(metric("retention", in: bad)?.rationale?.contains("a dropped") == true)
    }

    @Test("Action shape: items matched after normalization, record fields forbidden")
    func actionShape() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let text = "{\"add\":[\"il latte\",\"Uova\"],\"note\":\"Ho aggiunto latte e uova alla tua lista della spesa.\"}"
        let sample = EvalSample(id: "s", turns: ["mi serve del latte e le uova"], expect: EvalExpectation(contains: ["add": ["latte", "uova"]], shape: "Action"))
        let metrics = Graders.grade(task: task, sample: sample, outcome: outcome([text]))
        for name in ["json-only", "schema", "expect-contains", "expect-shape", "no-record-fields", "claimed-action"] {
            #expect(metric(name, in: metrics)?.value == .passing, "\(name)")
        }
    }

    @Test("Infrastructure failures are ignored by the graders and counted as availability")
    func infrastructure() {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let metrics = Graders.grade(task: task, sample: EvalSample(id: "s", turns: ["x"]), outcome: outcome(["x"], errorKind: "unsupportedLanguage"))
        #expect(metric("language-accepted", in: metrics)?.value == .failing)
        #expect(metric("model-available", in: metrics)?.value == .failing)
        #expect(metric("pass", in: metrics)?.value == .ignore)
        #expect(metric("schema", in: metrics)?.value == .ignore)
    }
}

// MARK: - The framework run over a mock

@Suite("Task evaluation under the framework (mock-backed)")
struct TaskEvaluationTests {

    @Test("The example task runs end to end and the capability map records it")
    func exampleTask() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let task = try Fixtures.task("example-task.json")
        // A mock that answers every city correctly, except one with prose.
        let answers = Mutex(0)
        let scripted = [
            "{\"city\":\"Rome\",\"country\":\"Italy\",\"continent\":\"Europe\",\"note\":\"Rome wears its centuries lightly and feeds you well.\"}",
            "{\"city\":\"Tokyo\",\"country\":\"Japan\",\"continent\":\"Asia\",\"note\":\"Tokyo is calm and electric at the same time.\"}",
            "Sure thing! {\"city\":\"Nairobi\",\"country\":\"Kenya\",\"continent\":\"Africa\",\"note\":\"Nairobi is the green city in the sun.\"}",
            "{\"city\":\"Buenos Aires\",\"country\":\"Argentina\",\"continent\":\"Americas\",\"note\":\"Buenos Aires dances late and eats later.\"}",
            "{\"city\":\"Sydney\",\"country\":\"Australia\",\"continent\":\"Oceania\",\"note\":\"Sydney lives on its harbour.\"}",
        ]
        let provider = ScriptedProvider { _ in
            let index = answers.withLock { value -> Int in defer { value += 1 }; return value }
            return scripted[min(index, scripted.count - 1)]
        }
        let evaluation = TaskEvaluation(task: task, provider: provider, mode: .raw)
        let result = try await evaluation.run()
        #expect(result.aggregateValue(.mean(of: Graders.passMetric)) == 0.8)
        #expect(result.passRate == 0.8)
        #expect(result.failureReasons.count == 1)
        #expect(result.aggregateValue(.mean(of: Metric("json-only"))) == 0.8)
        #expect(result.aggregateValue(.mean(of: Metric("schema"))) == 1.0)

        var map = CapabilityMap(generatedAt: Date(), entries: [])
        let entry = CapabilityMap.entry(from: result, evaluation: evaluation, host: "test", judge: nil)
        #expect(entry.samples == 5 && entry.scored == 5 && entry.passed == 4)
        #expect(entry.failureSamples.first?.contains("json-only") == true)
        map.upsert(entry)
        map.upsert(entry)   // same key: replaced, not duplicated
        #expect(map.entries.count == 1)
        #expect(map.markdown.contains("| on-device | test | 80% (4/5) |"))
    }

    @Test("Multi-turn: the carry template feeds turn two, history carries the rest")
    func multiTurn() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let task = try Fixtures.task("example-multiturn.json")
        let prompts = Mutex<[String]>([])
        let provider = ScriptedProvider { prompt in
            prompts.withLock { $0.append(prompt) }
            if prompt.hasPrefix("List so far: [") {
                // Echo the carried list plus the new word (a well-behaved model).
                let carried = prompt.split(separator: "[")[1].split(separator: "]")[0]
                let items = carried.split(separator: ",").map { "\"\($0.trimmingCharacters(in: .whitespaces))\"" }
                let new = prompt.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "and ", with: "").replacingOccurrences(of: "add the ", with: "").replacingOccurrences(of: "my ", with: "")
                return "{\"items\":[\(items.joined(separator: ",")),\"\(new)\"],\"note\":\"Got it.\"}"
            }
            let word = prompt.split(separator: " ").last!.lowercased()
            return "{\"items\":[\"\(word)\"],\"note\":\"Noted.\"}"
        }
        let evaluation = TaskEvaluation(task: task, provider: provider, mode: .raw)
        let result = try await evaluation.run()
        let sent = prompts.withLock { $0 }
        #expect(sent.contains("List so far: [towel]. The person now says: and sunscreen"))
        #expect(result.aggregateValue(.mean(of: Metric("retention"))) == 1.0)
        #expect(result.aggregateValue(.mean(of: Graders.passMetric)) == 1.0)
    }

    @Test("A rate limit is waited out and the sample is still measured")
    func rateLimitRetry() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let task = try Fixtures.task("example-task.json")
        // Every call fails twice with a 429 before the model answers, as a
        // free-tier cloud key does; the row must measure the answer.
        let calls = Mutex(0)
        let provider = FlakyProvider { _ in
            let n = calls.withLock { value -> Int in defer { value += 1 }; return value }
            if n % 3 < 2 { throw ProviderError.rateLimited(retryAfter: 0.01) }
            return "{\"city\":\"Rome\",\"country\":\"Italy\",\"continent\":\"Europe\",\"note\":\"Rome wears its centuries lightly and feeds you well.\"}"
        }
        var evaluation = TaskEvaluation(task: task, provider: provider, mode: .raw, limit: 1)
        evaluation.rateLimitRetries = 3
        let result = try await evaluation.run()
        #expect(result.aggregateValue(.mean(of: Metric("model-available"))) == 1.0)
        #expect(calls.withLock { $0 } == 3)

        // Fewer retries than failures: the sample is unavailable, not failed.
        calls.withLock { $0 = 0 }
        evaluation.rateLimitRetries = 1
        let starved = try await evaluation.run()
        #expect(starved.aggregateValue(.mean(of: Metric("model-available"))) == 0.0)
        #expect(starved.passRate == 0 && starved.failureReasons.isEmpty)
    }

    @Test("Structured mode runs the SDK path and records native/repaired flags")
    func structuredMode() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        var task = try Fixtures.task("example-task.json")
        task.samples = Array(task.samples.prefix(1))
        let provider = MockProvider(identifier: .onDevice, structuredAnswers: [
            "{\"city\":\"Rome\",\"country\":\"Italy\",\"continent\":\"Mars\",\"note\":\"Rome wears its centuries lightly.\"}",
            "{\"city\":\"Rome\",\"country\":\"Italy\",\"continent\":\"Europe\",\"note\":\"Rome wears its centuries lightly.\"}",
        ])
        let evaluation = TaskEvaluation(task: task, provider: provider, mode: .structured(repair: .once))
        let result = try await evaluation.run()
        #expect(result.aggregateValue(.mean(of: Graders.passMetric)) == 1.0)
        let outcome = try #require(result.detailed[evaluation.responseColumn.name, ModelSubject<EvalOutcome>.self].first??.value)
        #expect(outcome.turns.first?.repaired == true)
        #expect(outcome.turns.first?.nativeSchema == true)

        // Without repair the same script is a typed failure the graders score as FAIL.
        let raw = TaskEvaluation(task: task,
                                 provider: MockProvider(identifier: .onDevice, structuredAnswers: ["{\"city\":\"Rome\",\"country\":\"Italy\",\"continent\":\"Mars\",\"note\":\"x\"}"]),
                                 mode: .structured(repair: .none))
        let rawResult = try await raw.run()
        #expect(rawResult.aggregateValue(.mean(of: Graders.passMetric)) == 0.0)
        #expect(rawResult.aggregateValue(.mean(of: Graders.availabilityMetric)) == 1.0)
    }
}

// MARK: - Judge agreement

@Suite("Judge configuration and agreement (session 335)")
struct JudgeTests {
    @Test("Cohen's kappa: perfect, chance, and disagreement")
    func kappa() {
        #expect(JudgeAgreement.cohensKappa([(1, 1), (0, 0), (1, 1), (0, 0)]) == 1)
        #expect(abs(JudgeAgreement.cohensKappa([(1, 1), (1, 0), (0, 1), (0, 0)])) < 1e-9)
        #expect(JudgeAgreement.cohensKappa([(1, 0), (0, 1)]) == -1)
    }

    @Test("Agreement pools dimensions over the overlapping samples only")
    func measure() {
        let human = HumanRatings(task: "t", ratings: ["s1": ["q": 1], "s2": ["q": 0], "s9": ["q": 1]])
        let judge = ["s1": ["q": 1.0], "s2": ["q": 1.0], "s3": ["q": 0.0]]
        let agreement = JudgeAgreement.measure(judge: judge, human: human)
        #expect(agreement?.overlap == 2)
        #expect(agreement?.rawAgreement == 0.5)
    }

    @Test("A vendor never judges its own tier")
    func vendorRule() {
        let judge = JudgeConfiguration(vendor: .gemini, apiKey: "AQ.x", model: nil)
        #expect(judge.mayJudge(.cloudGemini) == false)
        #expect(judge.mayJudge(.cloudAnthropic) == true)
        #expect(judge.mayJudge(.onDevice) == true)
        let fromEnvironment = JudgeConfiguration.fromEnvironment(["VOLTA_EVAL_JUDGE_KEY": "sk-ant-x"])
        #expect(fromEnvironment?.vendor == .anthropic)
    }
}

// MARK: - Helpers

/// A provider whose answer is a function of the prompt (raw mode only).
struct ScriptedProvider: ModelProvider {
    let identifier = ProviderIdentifier.onDevice
    let privacyLevel = PrivacyLevel.onDevice
    let answer: @Sendable (String) -> String

    init(answer: @escaping @Sendable (String) -> String) { self.answer = answer }

    func availability() async -> ProviderAvailability { .available }
    func respond(to prompt: String, instructions: String?, history: [ChatTurn]) async throws -> String {
        answer(prompt)
    }
}


@Suite("Cross-field mention")
struct MentionsTests {
    @Test("The note must name one of the suggested additions")
    func mentions() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let spec = GraderSpec.mentions(path: "note", of: "completions[].text")
        func grade(_ note: String) -> Bool {
            let value: JSONValue = .object([
                "note": .string(note),
                "completions": .array([.object(["text": .string("a handful of berries")]), .object(["text": .string("some nuts")])]),
            ])
            let metric = Graders.mentions(Metric("m"), spec: spec, value: value)
            if case .failing = metric.value { return false }
            return true
        }
        #expect(grade("Add a few berries for fiber, or nuts for healthy fats."))
        #expect(grade("A few nuts would round it off.") == true)
        #expect(grade("Something with a little more crunch.") == false)
        #expect(grade("A creamy base, now sweetened with promise. What next?") == false)
    }
}

@Suite("Input-conditioned graders")
struct WhenPromptTests {
    @Test("A grader with whenPrompt is ignored when the input does not match")
    func whenPrompt() throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let task = EvalTask(
            id: "t", title: "t", instructions: "i",
            schema: .object(name: "R", properties: [.init("quantities", .array(of: .string()))]),
            graders: [.elementsMatch(path: "quantities", pattern: "\\d").when(promptMatches: "\\d")],
            samples: [
                EvalSample(id: "with", turns: ["200 g flour and 2 eggs"]),
                EvalSample(id: "without", turns: ["a pinch of everything"]),
            ]
        )
        let answer = EvalOutcome(
            turns: [.init(prompt: "", text: "{\"quantities\":[\"some\"]}", value: .object(["quantities": .array([.string("some")])]))],
            tier: "t", mode: "raw"
        )
        func failing(_ metrics: [Metric], _ name: String) -> Bool {
            guard let metric = metrics.first(where: { $0.name == name }) else { return false }
            if case .failing = metric.value { return true }
            return false
        }
        let with = Graders.grade(task: task, sample: task.samples[0], outcome: answer)
        let without = Graders.grade(task: task, sample: task.samples[1], outcome: answer)
        #expect(failing(with, "pass"))
        #expect(!failing(without, "pass"))
        #expect(without.first { $0.name == "elements-match:quantities" }?.rationale?.contains("whenPrompt") == true)
    }
}

/// A provider whose answer closure may throw, for infrastructure failures.
struct FlakyProvider: ModelProvider {
    let identifier = ProviderIdentifier.onDevice
    let privacyLevel = PrivacyLevel.onDevice
    let answer: @Sendable (String) throws -> String

    init(answer: @escaping @Sendable (String) throws -> String) { self.answer = answer }

    func availability() async -> ProviderAvailability { .available }
    func respond(to prompt: String, instructions: String?, history: [ChatTurn]) async throws -> String {
        try answer(prompt)
    }
}

// MARK: - Task format: typed graders, validation, loader errors

@Suite("Task format")
struct TaskFormatTests {

    @Test("Typed grader constructors produce the documented JSON")
    func typedGraders() throws {
        let typed: [GraderSpec] = [
            .jsonOnly(), .schema(), .required(paths: ["title", "items:1"]),
            .forbiddenFields(paths: ["items"], name: "no-items"), .expectFields(), .expectContains(), .expectShape(),
            .language(path: "note"), .forbiddenPatterns(path: "note", patterns: ["\\d"]),
            .elementsMatch(path: "ingredients", pattern: "\\d", minFraction: 0.6),
            .mentions(path: "note", of: "completions[].text"),
            .claimedAction(field: "add", patterns: ["added"]),
            .retention(keepItems: "items[].name", keepStates: "states", from: "present", notTo: "missing"),
        ]
        #expect(typed.map(\.kind) == GraderSpec.knownKinds)
        #expect(typed[2] == GraderSpec(kind: "required", params: ["paths": ["title", "items:1"]]))
        #expect(typed[3] == GraderSpec(kind: "forbidden-fields", params: ["paths": ["items"], "name": "no-items"]))
        #expect(typed[7] == GraderSpec(kind: "language", params: ["path": "note"]))
        #expect(typed[9] == GraderSpec(kind: "elements-match", params: ["path": "ingredients", "pattern": "\\d", "minFraction": 0.6]))
        // Round-trip through JSON: the typed form IS the file form.
        let data = try JSONEncoder().encode(typed)
        #expect(try JSONDecoder().decode([GraderSpec].self, from: data) == typed)
    }

    @Test("The example tasks validate clean")
    func examplesValidate() throws {
        for task in try EvalTask.examples {
            #expect(task.validate().isEmpty, "\(task.id): \(task.validate())")
        }
    }

    @Test("Validation names each problem with its path")
    func validation() throws {
        var task = try EvalTask.example("example.city-facts")
        task.graders = [
            GraderSpec(kind: "langauge"),
            GraderSpec(kind: "required"),
            .retention(keepStates: "states"),
        ]
        task.samples[1].id = task.samples[0].id
        task.samples[2].turns = []
        task.samples[3].expect = EvalExpectation(shape: "Record")
        task.carry = CarryTemplate(template: "{{prompt}}")
        let problems = task.validate().map(\.description)
        #expect(problems.contains { $0.hasPrefix("graders[0].kind: unknown grader \"langauge\"") })
        #expect(problems.contains("graders[1].params.paths: required needs \"paths\""))
        #expect(problems.contains("graders[2].params: retention with \"keepStates\" needs \"from\" and \"notTo\""))
        #expect(problems.contains("samples[1].id: duplicate id \"c-01\""))
        #expect(problems.contains("samples[2].turns: needs one or more non-empty turns"))
        #expect(problems.contains("samples[3].expect.shape: the task schema is not an anyOf, so a shape cannot be expected"))
        #expect(problems.contains("carry: a carry template needs at least one multi-turn sample"))
    }

    @Test("A malformed file throws a readable error, never a DecodingError")
    func loaderErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("volta-evals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missingField = directory.appendingPathComponent("missing.json")
        try Data(#"{"id":"t","title":"t","schemaVersion":"v1","graders":[],"samples":[]}"#.utf8).write(to: missingField)
        #expect {
            try EvalTask.load(from: missingField)
        } throws: { error in
            guard case EvalEngineError.invalidTask(let file, let problems) = error else { return false }
            return file == "missing.json" && problems.first?.contains("missing required field \"instructions\"") == true
        }
        let wrongType = directory.appendingPathComponent("type.json")
        try Data(#"{"id":"t","title":"t","schemaVersion":"v1","instructions":"x","graders":[{"kind":"schema"}],"samples":[{"id":"s","turns":"not an array"}]}"#.utf8).write(to: wrongType)
        #expect {
            try EvalTask.load(from: wrongType)
        } throws: { error in
            guard case EvalEngineError.invalidTask(_, let problems) = error else { return false }
            return problems.first?.hasPrefix("samples[0].turns: expected") == true
        }
    }
}

// MARK: - Mid-conversation handoff (Q12/Q13)

@Suite("Handoff between providers mid-conversation")
struct HandoffTests {
    @Test("Turns after the handoff go to the second provider with the history carried over")
    func handoff() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let task = try EvalTask.example("example.packing-list")
        let seenByB = Mutex<[(prompt: String, historyCount: Int)]>([])
        let a = ScriptedProvider { prompt in
            let word = prompt.split(separator: " ").last!.lowercased()
            return "{\"items\":[\"\(word)\"],\"note\":\"Noted.\"}"
        }
        let b = MockProvider(identifier: .privateCloudCompute, privacyLevel: .appleCloud,
                             outcome: .success("{\"items\":[\"towel\",\"sunscreen\",\"passport\",\"charger\",\"books\",\"headphones\",\"flip flops\",\"tickets\",\"sunglasses\",\"hat\",\"raincoat\",\"boots\",\"camera\",\"tripod\"],\"note\":\"Kept.\"}")) { prompt, _, history in
            seenByB.withLock { $0.append((prompt, history.count)) }
        }
        let evaluation = TaskEvaluation(task: task, provider: a, mode: .raw, handoff: .init(afterTurn: 1, to: b))
        #expect(evaluation.tier == "on-device>private-cloud-compute")
        let result = try await evaluation.run()
        let calls = seenByB.withLock { $0 }
        #expect(calls.count == task.samples.count)                       // every second turn went to B
        #expect(calls.allSatisfy { $0.historyCount == 2 })               // with turn 1 as history
        #expect(calls.first?.prompt.hasPrefix("List so far: [") == true) // and the carry template applied
        #expect(result.aggregateValue(.mean(of: Metric("retention"))) == 1.0)
        let outcome = try #require(result.detailed[evaluation.responseColumn.name, ModelSubject<EvalOutcome>.self].first??.value)
        #expect(outcome.turns.map(\.provider) == ["on-device", "private-cloud-compute"])
    }

    @Test("The long-context examples validate and grow as intended")
    func longContextExamples() throws {
        let tasks = try EvalTask.examples.filter { $0.id.hasPrefix("example.long-context") }
        #expect(tasks.count == 5)
        for task in tasks { #expect(task.validate().isEmpty, "\(task.id): \(task.validate())") }
        let lengths = tasks.map { $0.samples[0].turns[0].count }.sorted()
        #expect(lengths.first! < 2100 && lengths.last! > 16000)
    }
}
