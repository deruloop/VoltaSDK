//
//  LiveEvaluations.swift
//  VoltaSDKEvalsTests
//
//  The real runs (opt-in: VOLTA_EVAL_LIVE=1). Two entry points:
//
//  - Phase 0 — does the on-device model accept the task's language at all?
//    Reads the framework's declared support and, for a task file, counts
//    `unsupportedLanguage` rejections over its samples.
//  - The capability map — every configured task × reachable tier × mode,
//    folded into docs/evals/results/capability-map.{json,md}.
//
//  Run from the package root, e.g.
//    VOLTA_EVAL_LIVE=1 VOLTA_EVAL_TASKS=docs/evals/raviolo/tasks \
//    VOLTA_EVAL_MODES=raw,structured,structured+repair \
//    swift test --filter LiveEvaluations
//
//  A plain `swift test` process reaches on-device (this Mac's Apple
//  Intelligence) and any cloud tier with a key; PCC needs the hosted
//  bundle inside the signed demo app (see Examples/macOSDemo), and a real
//  iPhone needs the hosted bundle inside the iOS demo run on the device.
//

import Foundation
import FoundationModels
import Testing
import VoltaSDK
import VoltaSDKEvals

/// Anchors `Bundle(for:)` to THIS test bundle, so a hosted run finds the
/// task files copied into it.
private final class TestBundleMarker {}

@Suite("LiveEvaluations")
struct LiveEvaluations {
    let runner = EvalRunner(resourceBundles: [Bundle(for: TestBundleMarker.self), .main])

    @Test("Phase 0: language acceptance on the on-device model")
    func phase0LanguageAcceptance() async throws {
        guard runner.isLive else { return }
        guard #available(iOS 27.0, macOS 27.0, *) else { return }

        // The framework's own word first.
        let model = SystemLanguageModel.default
        print("[phase0] on-device availability: \(model.availability)")
        let declared = model.supportedLanguages.map(\.minimalIdentifier).sorted()
        print("[phase0] declared languages: \(declared)")

        let tasks = try runner.taskURLs().map(EvalTask.load(from:))
        for task in tasks {
            let language = task.language ?? "en"
            let supported = model.supportsLocale(Locale(identifier: language))
            print("[phase0] \(task.id): language \(language) declared supported = \(supported)")
        }

        // Then the measured number: run the first task in raw mode on-device
        // and read the language-accepted rate.
        guard let task = tasks.first else {
            print("[phase0] no task configured (VOLTA_EVAL_TASKS); declared support only")
            return
        }
        guard case .success(let provider) = EvalTier.onDevice.makeProvider() else { return }
        let entry = try await runner.run(task: task, tier: .onDevice, provider: provider, mode: .raw, judge: nil)
        print("[phase0] \(task.id) on-device: language accepted \(CapabilityMap.percent(entry.languageAcceptedRate)) over \(entry.samples) samples; pass \(entry.passed)/\(entry.scored)")
        var map = CapabilityMap.load(from: runner.capabilityMapURL)
        map.upsert(entry)
        try map.save(to: runner.capabilityMapURL)
    }

    @Test("Capability map: every task × reachable tier × mode")
    func capabilityMap() async throws {
        guard runner.isLive else {
            let visible = ProcessInfo.processInfo.environment.keys.filter { $0.contains("VOLTA") }.sorted()
            print("[evals] not live (VOLTA_EVAL_LIVE != 1); VOLTA* variables visible to this process: \(visible)")
            return
        }
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        let report = try await runner.runAll()
        for line in report.log { print("[evals] \(line)") }
        print("[evals] capability map: \(runner.capabilityMapURL.path)")
        #expect(!report.entries.isEmpty, "nothing ran — check VOLTA_EVAL_TASKS and the tier reasons above")
    }
}
