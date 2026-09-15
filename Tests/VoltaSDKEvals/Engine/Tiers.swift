//
//  Tiers.swift
//  VoltaSDKEvals
//
//  The rows of the capability map: which provider answers. Each tier is a
//  SINGLE provider run through its own one-element chain, so provenance is
//  exact and no fallback blurs the measurement (a chain-level eval is a
//  different question, asked with a different tier).
//
//  Reachability is environment-driven and honest about the process:
//  - on-device needs Apple Intelligence on the machine running the tests
//    (`swift test` on the Mac stands in for the iPhone; a hosted bundle on
//    a device measures that device);
//  - PCC needs a process signed with the entitlement — a plain `swift test`
//    process never has it, a hosted test bundle inside the signed demo
//    app does;
//  - cloud needs a developer key in the environment.
//

import Foundation
@testable import VoltaSDK

enum EvalTier: String, CaseIterable, Sendable {
    case onDevice = "on-device"
    case privateCloudCompute = "pcc"
    case cloudOpenAI = "cloud-openai"
    case cloudAnthropic = "cloud-anthropic"
    case cloudGemini = "cloud-gemini"

    /// The vendor behind the tier, when it is a cloud vendor.
    var vendor: CloudVendor? {
        switch self {
        case .cloudOpenAI: return .openAI
        case .cloudAnthropic: return .anthropic
        case .cloudGemini: return .gemini
        default: return nil
        }
    }

    /// Environment variable carrying the developer key for a cloud tier.
    var keyVariable: String? {
        switch self {
        case .cloudOpenAI: return "VOLTA_EVAL_OPENAI_KEY"
        case .cloudAnthropic: return "VOLTA_EVAL_ANTHROPIC_KEY"
        case .cloudGemini: return "VOLTA_EVAL_GEMINI_KEY"
        default: return nil
        }
    }

    /// Optional model override (`VOLTA_EVAL_<VENDOR>_MODEL`).
    var modelVariable: String? {
        keyVariable?.replacingOccurrences(of: "_KEY", with: "_MODEL")
    }

    /// Builds the tier's provider, or explains why it cannot exist in this
    /// process. Availability (model ready, key valid) is checked separately.
    func makeProvider(environment: [String: String] = ProcessInfo.processInfo.environment) -> Result<any ModelProvider, TierUnreachable> {
        switch self {
        case .onDevice:
            if #available(iOS 26.0, macOS 26.0, *) { return .success(OnDeviceProvider()) }
            return .failure(.init("on-device needs OS 26"))
        case .privateCloudCompute:
            if #available(iOS 27.0, macOS 27.0, *) {
                guard PrivateCloudComputeProvider.hasRequiredEntitlement() else {
                    return .failure(.init("process is not signed with \(PrivateCloudComputeProvider.requiredEntitlement) — run the hosted bundle"))
                }
                return .success(PrivateCloudComputeProvider())
            }
            return .failure(.init("PCC needs OS 27"))
        case .cloudOpenAI, .cloudAnthropic, .cloudGemini:
            guard let variable = keyVariable, let key = environment[variable], !key.isEmpty else {
                return .failure(.init("no key in \(keyVariable ?? "")"))
            }
            var config = AIConfiguration()
            config.developerKey = key
            config.developerKeyVendor = vendor
            config.developerKeyModel = modelVariable.flatMap { environment[$0] }
            config.maxTokens = Int(environment["VOLTA_EVAL_MAX_TOKENS"] ?? "") ?? 1500
            guard let provider = AIOrchestrator.buildCloudProvider(from: config) else {
                return .failure(.init("could not build the \(rawValue) provider"))
            }
            return .success(provider)
        }
    }

    /// A human-readable label with the model name where one is configured.
    func label(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let vendor else { return rawValue }
        let model = modelVariable.flatMap { environment[$0] } ?? vendor.defaultModel
        return "\(rawValue) (\(model))"
    }
}

/// Why a tier cannot exist in this process.
struct TierUnreachable: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// How the engine asks the model: the raw prompt as the app sends it, or
/// the SDK's structured path (schema in, validated value out).
enum EvalMode: Sendable, Hashable, CustomStringConvertible {
    /// `respond` with the task instructions verbatim — the raw ceiling.
    case raw
    /// `respondStructured` with the task schema and the given repair policy.
    case structured(repair: RepairPolicy)

    var description: String {
        switch self {
        case .raw: return "raw"
        case .structured(.none): return "structured"
        case .structured(.once): return "structured+repair"
        }
    }

    static func parse(_ text: String) -> EvalMode? {
        switch text {
        case "raw": return .raw
        case "structured": return .structured(repair: .none)
        case "structured+repair": return .structured(repair: .once)
        default: return nil
        }
    }
}
