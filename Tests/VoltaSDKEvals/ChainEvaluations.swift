//
//  ChainEvaluations.swift
//  VoltaSDKEvals
//
//  First contact with Apple's Evaluations framework (WWDC 2026, sessions
//  298/299/335) — D20. This file holds the HARNESS smoke evaluation: the
//  framework drives VoltaSDK's chain end to end over a mock provider, no
//  network and no real model, proving that the eval machinery links and
//  runs under `swift test`. The real suites (provider parity on fallback,
//  the on-device long-context threshold) build on this harness and gate
//  themselves on environment variables, because they need real models.
//
//  Note on integration style: the framework offers a Swift Testing trait
//  (`.evaluates(...)`), but Swift Testing rejects `@available` on `@Test`
//  and the trait's symbols are OS 27-only while the package floor is 18 —
//  so evaluations run through the equally supported manual `run()` inside
//  availability-guarded tests, and results are asserted via
//  `aggregateValue(_:)`.
//

import Evaluations
import Testing
import VoltaSDK

/// The chain answering under the Evaluations framework, mock-backed.
@available(iOS 27.0, macOS 27.0, *)
struct ChainEchoEvaluation: Evaluation {

    var dataset: ArrayLoader<ModelSample<String>> {
        ArrayLoader(samples: [
            ModelSample(prompt: "ping", expected: "pong"),
            ModelSample(prompt: "anything at all", expected: "pong"),
        ])
    }

    func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
        let kit = AIOrchestrator(providers: [
            MockProvider(identifier: .onDevice, outcome: .success("pong"))
        ])
        let answer = try await kit.respond(to: sample.promptDescription)
        return ModelSubject(value: answer)
    }

    var evaluators: [any EvaluatorProtocol<ModelSample<String>, ModelSubject<String>>] {
        Evaluator<ModelSample<String>> { sample, subject in
            let exactMatch = Metric("exact-match")
            guard let expected = sample.expected else {
                return exactMatch.ignore(rationale: "no expected value")
            }
            return subject.value == expected
                ? exactMatch.passing()
                : exactMatch.failing(rationale: "got \(subject.value)")
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: Metric("exact-match"))
    }
}

@Suite("Evaluations harness (D20)")
struct EvaluationsHarnessTests {

    @Test("The chain runs end to end under the Evaluations framework")
    func harnessSmoke() async throws {
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let result = try await ChainEchoEvaluation().run()
        #expect(result.aggregateValue(.mean(of: Metric("exact-match"))) == 1.0)
    }
}
