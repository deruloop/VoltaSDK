//
//  Judge.swift
//  VoltaSDKEvals
//
//  The model-as-judge layer (session 335). The judge is a CLOUD model from
//  a vendor that is NOT the tier under test, reached through VoltaSDK's own
//  iOS 27 front door: `CloudAccountLanguageModel` is a native
//  `LanguageModel`, which is exactly what `ModelJudgeEvaluator` takes.
//  A judge is not trusted until its agreement with human ratings has been
//  measured (Cohen's kappa over the samples both rated).
//

import Evaluations
import Foundation
import FoundationModels
import VoltaSDK

public struct JudgeConfiguration: Sendable {
    public let vendor: CloudVendor
    public let apiKey: String
    public let model: String?

    /// `VOLTA_EVAL_JUDGE_VENDOR` (openai | anthropic | gemini) +
    /// `VOLTA_EVAL_JUDGE_KEY` (+ optional `VOLTA_EVAL_JUDGE_MODEL`).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> JudgeConfiguration? {
        guard let key = environment["VOLTA_EVAL_JUDGE_KEY"], !key.isEmpty else { return nil }
        let vendor = environment["VOLTA_EVAL_JUDGE_VENDOR"].flatMap(CloudVendor.init(rawValue:))
            ?? CloudVendor.detect(fromKey: key)
        guard let vendor else { return nil }
        return JudgeConfiguration(vendor: vendor, apiKey: key, model: environment["VOLTA_EVAL_JUDGE_MODEL"])
    }

    public init(vendor: CloudVendor, apiKey: String, model: String? = nil) {
        self.vendor = vendor
        self.apiKey = apiKey
        self.model = model
    }

    /// The rule: never let a vendor judge itself.
    public func mayJudge(_ tier: EvalTier) -> Bool {
        tier.vendor != vendor
    }

    public func mayJudge(vendorUnderTest: CloudVendor?) -> Bool {
        vendorUnderTest != vendor
    }

    /// The judge evaluator for a task, or nil when the task declares no
    /// dimensions or the tier is the judge's own vendor.
    @available(iOS 27.0, macOS 27.0, *)
    public func makeEvaluator(for task: EvalTask, tier: EvalTier) -> (any EvaluatorProtocol<FrameworkSample, ModelSubject<EvalOutcome>>)? {
        makeEvaluator(for: task, vendorUnderTest: tier.vendor)
    }

    @available(iOS 27.0, macOS 27.0, *)
    public func makeEvaluator(for task: EvalTask, vendorUnderTest: CloudVendor?) -> (any EvaluatorProtocol<FrameworkSample, ModelSubject<EvalOutcome>>)? {
        guard let spec = task.judge, !spec.dimensions.isEmpty, mayJudge(vendorUnderTest: vendorUnderTest) else { return nil }
        let model = CloudAccountLanguageModel(vendor: vendor, apiKey: apiKey, model: model)
        let dimensions = spec.dimensions.map { dimension -> ScoreDimension in
            ScoreDimension(dimension.name, description: dimension.description, scale: Self.scale(for: dimension))
        }
        let prompt = ModelJudgePrompt<FrameworkSample>(
            instructions: spec.instructions ?? ModelJudgePrompt<FrameworkSample>.defaultInstructions,
            evaluationTarget: { outcome in
                outcome.last?.text ?? outcome.last?.error ?? "<no answer>"
            },
            reference: { framework, outcome in
                let sample = framework.sample
                var reference: [String: String] = [:]
                if outcome.turns.count > 1 {
                    reference["conversation"] = outcome.turns.enumerated().map { index, turn in
                        "User \(index + 1): \(turn.prompt)\nAssistant \(index + 1): \(turn.text ?? turn.error ?? "")"
                    }.joined(separator: "\n")
                }
                if let expect = sample.expect,
                   let data = try? JSONEncoder().encode(expect),
                   let text = String(data: data, encoding: .utf8) {
                    reference["expectations"] = text
                }
                if let notes = sample.notes { reference["notes"] = notes }
                return reference
            }
        )
        return ModelJudgeEvaluator<FrameworkSample>(judge: model, dimensions: dimensions, prompt: prompt)
    }

    @available(iOS 27.0, macOS 27.0, *)
    public static func scale(for dimension: JudgeSpec.Dimension) -> ScoringScale {
        guard let scale = dimension.scale, !scale.isEmpty else {
            return .passFail(passDescription: "meets the criterion", failDescription: "does not meet the criterion")
        }
        var numeric: [Double: String] = [:]
        for (key, label) in scale { if let value = Double(key) { numeric[value] = label } }
        return .numeric(numeric)
    }
}

// MARK: - Agreement with human ratings

/// Human ratings for a task, consumed by path (`VOLTA_EVAL_HUMAN_RATINGS`,
/// a directory of `<task id>.json` files or a single file):
/// `{"task":"…","ratings":{"<sample id>":{"<dimension>":1}}}` on the same
/// scale as the judge's dimension.
public struct HumanRatings: Codable {
    public var task: String
    public var ratings: [String: [String: Double]]

    public init(task: String, ratings: [String: [String: Double]]) {
        self.task = task
        self.ratings = ratings
    }

    public static func load(for taskID: String, from path: String) -> HumanRatings? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = isDirectory.boolValue
            ? URL(fileURLWithPath: path).appendingPathComponent("\(taskID).json")
            : URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let ratings = try? JSONDecoder().decode(HumanRatings.self, from: data),
              ratings.task == taskID else { return nil }
        return ratings
    }
}

public struct JudgeAgreement: Codable {
    /// Cohen's kappa over the overlapping samples (all dimensions pooled).
    public var kappa: Double
    /// Raw agreement (fraction of identical scores).
    public var rawAgreement: Double
    public var overlap: Int

    public init(kappa: Double, rawAgreement: Double, overlap: Int) {
        self.kappa = kappa
        self.rawAgreement = rawAgreement
        self.overlap = overlap
    }

    /// Cohen's kappa between two raters over paired categorical scores.
    public static func cohensKappa(_ pairs: [(Double, Double)]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let n = Double(pairs.count)
        let categories = Set(pairs.flatMap { [$0.0, $0.1] })
        let observed = Double(pairs.filter { $0.0 == $0.1 }.count) / n
        var expected = 0.0
        for category in categories {
            let a = Double(pairs.filter { $0.0 == category }.count) / n
            let b = Double(pairs.filter { $0.1 == category }.count) / n
            expected += a * b
        }
        if expected == 1 { return observed == 1 ? 1 : 0 }
        return (observed - expected) / (1 - expected)
    }

    public static func measure(judge: [String: [String: Double]], human: HumanRatings) -> JudgeAgreement? {
        var pairs: [(Double, Double)] = []
        for (sampleID, dimensions) in judge {
            guard let humanScores = human.ratings[sampleID] else { continue }
            for (dimension, score) in dimensions {
                if let humanScore = humanScores[dimension] { pairs.append((score, humanScore)) }
            }
        }
        guard !pairs.isEmpty else { return nil }
        return JudgeAgreement(
            kappa: cohensKappa(pairs),
            rawAgreement: Double(pairs.filter { $0.0 == $0.1 }.count) / Double(pairs.count),
            overlap: pairs.count
        )
    }
}
