//
//  TaskEvaluation.swift
//  VoltaSDKEvals
//
//  One (task, tier, mode) run under Apple's Evaluations framework. The
//  subject drives VoltaSDK exactly as an app would — instructions verbatim,
//  app-owned history (D12), one provider in the chain — turn by turn, with
//  the task's carry template building later prompts from earlier answers.
//  The graders then score the outcome; an optional model judge (session
//  335) adds its dimensions.
//

import Evaluations
import Foundation
import VoltaSDK

@available(iOS 27.0, macOS 27.0, *)
public struct TaskEvaluation: Evaluation {
    public typealias Sample = FrameworkSample
    public typealias Subject = ModelSubject<EvalOutcome>

    public let task: EvalTask
    /// The provider under test — ONE provider, so provenance is exact.
    public let provider: any ModelProvider
    public let mode: EvalMode
    /// The row key in the capability map (a tier name such as "on-device",
    /// or whatever the adopter calls this provider) and its display label.
    public let tier: String
    public let tierLabel: String
    /// A judge evaluator, when a cloud judge from another vendor is configured.
    public let judgeEvaluator: (any EvaluatorProtocol<FrameworkSample, ModelSubject<EvalOutcome>>)?
    /// Cap on samples per run (quick iterations); nil = the whole dataset.
    public let limit: Int?

    /// The adopter's entry point: a task against one provider, in one mode.
    ///
    /// ```swift
    /// let evaluation = TaskEvaluation(task: task, provider: OnDeviceProvider(), mode: .structured)
    /// let result = try await evaluation.run()
    /// #expect(result.passRate >= 0.8)
    /// ```
    public init(
        task: EvalTask,
        provider: any ModelProvider,
        mode: EvalMode = .raw,
        tierLabel: String? = nil,
        judge: JudgeConfiguration? = nil,
        limit: Int? = nil
    ) {
        self.task = task
        self.provider = provider
        self.mode = mode
        self.tier = tierLabel ?? provider.identifier.rawValue
        self.tierLabel = self.tier
        self.judgeEvaluator = judge?.makeEvaluator(for: task, vendorUnderTest: (provider as? CloudVendorIdentifying)?.cloudVendor)
        self.limit = limit
    }

    /// The sweep's entry point: a named tier (see `EvalTier`).
    public init(
        task: EvalTask,
        tier: EvalTier,
        mode: EvalMode,
        provider: any ModelProvider,
        judgeEvaluator: (any EvaluatorProtocol<FrameworkSample, ModelSubject<EvalOutcome>>)? = nil,
        limit: Int? = nil
    ) {
        self.task = task
        self.provider = provider
        self.mode = mode
        self.tier = tier.rawValue
        self.tierLabel = tier.label()
        self.judgeEvaluator = judgeEvaluator
        self.limit = limit
    }

    public var name: String { "\(task.id) @ \(tierLabel) [\(mode)]" }

    public var dataset: ArrayLoader<FrameworkSample> {
        var samples = task.samples
        if let limit { samples = Array(samples.prefix(limit)) }
        // The evaluators (and the judge prompt) see the instructions the
        // model saw.
        return ArrayLoader(samples: samples.map { FrameworkSample(sample: $0, instructions: task.instructions) })
    }

    public func subject(from framework: FrameworkSample) async throws -> ModelSubject<EvalOutcome> {
        let sample = framework.sample
        let kit = AIOrchestrator(providers: [provider])
        var turns: [EvalOutcome.TurnOutcome] = []
        var history: [ChatTurn] = []
        var previousValue: JSONValue? = nil
        var previousRaw: String? = nil

        for (index, typed) in sample.turns.enumerated() {
            // Later turns go through the carry template, if the task has one.
            var prompt = typed
            var carriedFromCanonical: Bool? = nil
            if index > 0, let carry = task.carry {
                if previousValue != nil {
                    prompt = carry.render(prompt: typed, previous: previousValue, previousRaw: previousRaw)
                    carriedFromCanonical = false
                } else if let canonical = sample.canonicalState {
                    prompt = carry.render(prompt: typed, previous: canonical, previousRaw: previousRaw)
                    carriedFromCanonical = true
                }
            }

            var turn = EvalOutcome.TurnOutcome(prompt: prompt, carriedFromCanonicalState: carriedFromCanonical)
            let started = Date()
            do {
                switch mode {
                case .raw:
                    let response = try await kit.respondDetailed(
                        to: prompt, instructions: task.instructions, history: history
                    )
                    turn.text = response.text
                    turn.provider = response.provider.rawValue
                    turn.value = (try? JSONValue.extractObject(from: response.text))?.value
                case .structured(let repair):
                    guard let schema = task.schema else {
                        throw EvalEngineError.taskHasNoSchema(task.id)
                    }
                    let response = try await kit.respondStructured(
                        to: prompt, instructions: task.instructions, history: history,
                        schema: schema, repair: repair
                    )
                    turn.text = response.text
                    turn.value = response.value
                    turn.provider = response.provider.rawValue
                    turn.repaired = response.repaired
                    turn.nativeSchema = response.nativeSchema
                }
            } catch let error as ProviderError {
                turn.error = String(describing: error)
                turn.errorKind = Self.kind(of: error)
                if case .malformedStructuredOutput(_, let raw) = error {
                    // Model output, just not conforming: keep it for the graders.
                    turn.text = raw
                    turn.value = (try? JSONValue.extractObject(from: raw))?.value
                    turn.provider = provider.identifier.rawValue
                }
            } catch {
                turn.error = String(describing: error)
                turn.errorKind = "other"
            }
            turn.latencySeconds = Date().timeIntervalSince(started)
            turns.append(turn)

            // Stop the conversation at the first failed turn.
            guard let text = turn.text, turn.error == nil || turn.errorKind == "malformedStructuredOutput" else { break }
            history += [.user(prompt), .assistant(text)]
            previousValue = turn.value
            previousRaw = text
        }

        return ModelSubject(value: EvalOutcome(turns: turns, tier: tier, mode: mode.description))
    }

    public var evaluators: [any EvaluatorProtocol<FrameworkSample, ModelSubject<EvalOutcome>>] {
        GraderEvaluator(task: task)
        if let judgeEvaluator { judgeEvaluator }
    }

    public func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        for metric in Graders.metrics(for: task) {
            aggregator.computeMean(of: metric)
        }
        if let judge = task.judge, judgeEvaluator != nil {
            for dimension in judge.dimensions {
                aggregator.computeMean(of: Metric(dimension.name))
            }
        }
    }

    /// The `ProviderError` case name, for the graders' infrastructure rule.
    public static func kind(of error: ProviderError) -> String {
        switch error {
        case .rateLimited: return "rateLimited"
        case .unauthorized: return "unauthorized"
        case .network: return "network"
        case .emptyResponse: return "emptyResponse"
        case .encoding: return "encoding"
        case .decoding: return "decoding"
        case .api: return "api"
        case .contextWindowExceeded: return "contextWindowExceeded"
        case .guardrailViolation: return "guardrailViolation"
        case .unsupportedLanguage: return "unsupportedLanguage"
        case .generation: return "generation"
        case .noProviderAvailable: return "noProviderAvailable"
        case .privacyRestricted: return "privacyRestricted"
        case .cancelled: return "cancelled"
        case .malformedStructuredOutput: return "malformedStructuredOutput"
        }
    }
}

/// All deterministic graders of a task, as one framework evaluator that
/// returns every metric at once (the `Evaluator` helper returns one).
@available(iOS 27.0, macOS 27.0, *)
public struct GraderEvaluator: EvaluatorProtocol {
    public typealias Input = FrameworkSample
    public typealias Subject = ModelSubject<EvalOutcome>

    public let task: EvalTask

    public func metrics(subject: ModelSubject<EvalOutcome>, input: FrameworkSample) async throws -> [Metric] {
        Graders.grade(task: task, sample: input.sample, outcome: subject.value)
    }
}

public enum EvalEngineError: Error, CustomStringConvertible {
    case taskHasNoSchema(String)
    case taskNotFound(String)
    case tierUnreachable(EvalTier, String)
    /// A task file that decodes or validates with problems; each entry is
    /// "path: reason" (see docs/evals/TASK-FORMAT.md).
    case invalidTask(file: String, problems: [String])

    public var description: String {
        switch self {
        case .taskHasNoSchema(let id): return "task \(id) has no schema; structured mode needs one"
        case .taskNotFound(let id): return "no example task named \(id)"
        case .invalidTask(let file, let problems): return "invalid task \(file):\n  " + problems.joined(separator: "\n  ")
        case .tierUnreachable(let tier, let reason): return "\(tier.rawValue) unreachable: \(reason)"
        }
    }
}

// MARK: - Reading a result

@available(iOS 27.0, macOS 27.0, *)
extension EvaluationResult {
    /// Passed / scored, where scored excludes infrastructure failures
    /// (unsupported language, unavailability, rate limits): the number an
    /// adopter asserts on.
    public var passRate: Double {
        let tally = CapabilityMap.tally(detailed, metric: Graders.passMetric)
        return tally.scored > 0 ? Double(tally.passed) / Double(tally.scored) : 0
    }

    /// Fraction of samples the model actually answered.
    public var availabilityRate: Double {
        let tally = CapabilityMap.tally(detailed, metric: Graders.availabilityMetric)
        return tally.total > 0 ? Double(tally.passed) / Double(tally.total) : 0
    }

    /// The rationales behind the failed samples, for a failing test's message.
    public var failureReasons: [String] {
        CapabilityMap.tally(detailed, metric: Graders.passMetric).rationales
    }
}

/// A provider that can say which cloud vendor it speaks to — used only to
/// keep a judge from scoring its own vendor.
public protocol CloudVendorIdentifying {
    var cloudVendor: CloudVendor? { get }
}
