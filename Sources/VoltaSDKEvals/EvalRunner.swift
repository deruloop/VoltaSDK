//
//  EvalRunner.swift
//  VoltaSDKEvals
//
//  Runs a set of task files across the tiers this process can reach, in
//  the requested modes, and folds each run into the capability map.
//  Everything is environment-driven so the same code runs under
//  `swift test` on the Mac and inside a hosted test bundle on a device.
//
//  Environment:
//    VOLTA_EVAL_LIVE=1              opt in to real-model runs
//    VOLTA_EVAL_TASKS=<path>        a task file or a directory of *.json tasks
//    VOLTA_EVAL_TIERS=on-device,pcc,cloud-gemini   (default: all reachable)
//    VOLTA_EVAL_MODES=raw,structured,structured+repair   (default: raw)
//    VOLTA_EVAL_LIMIT=<n>           samples per task (quick runs)
//    VOLTA_EVAL_HANDOFF_TO=<tier>   also run multi-turn tasks with later turns on that tier (Q12/Q13)
//    VOLTA_EVAL_RESULTS=<dir>       where the map + run files go
//    VOLTA_EVAL_HOST=<label>        how this machine is named in the map
//    VOLTA_EVAL_<VENDOR>_KEY/_MODEL cloud tiers; VOLTA_EVAL_JUDGE_* the judge
//    VOLTA_EVAL_HUMAN_RATINGS=<path> human ratings for judge agreement
//

import Evaluations
import Foundation
import TabularData
import VoltaSDK

public struct EvalRunner {
    public let environment: [String: String]
    /// Bundles searched for a `tasks` (or `EvalTasks`) folder when
    /// `VOLTA_EVAL_TASKS` is unset — a hosted test bundle passes itself.
    public let resourceBundles: [Bundle]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourceBundles: [Bundle] = [.main]
    ) {
        self.environment = environment
        self.resourceBundles = resourceBundles
    }

    public var isLive: Bool { environment["VOLTA_EVAL_LIVE"] == "1" }

    /// The repo root, derived from this file's location: the default place
    /// for results when no directory is configured. Exists only on the
    /// machine that compiled the tests (`swift test`, or a hosted bundle on
    /// the Mac); on a device the bundle's resources stand in.
    public static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoltaSDKEvals
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // package root
    }

    public static var packageRootExists: Bool {
        FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Package.swift").path)
    }


    /// Folders a GUI host cannot read without a TCC prompt (which nobody
    /// answers during an automated run).
    public static func isPrivacyProtected(_ path: String) -> Bool {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].contains { path.hasPrefix(home + "/" + $0) }
        #else
        return false
        #endif
    }

    public var bundledTasksDirectory: URL? {
        for bundle in resourceBundles {
            guard let resources = bundle.resourceURL else { continue }
            for name in ["EvalTasks", "tasks"] {
                let candidate = resources.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// Whether the engine runs inside a hosted bundle (an .app host) rather
    /// than the `swift test` runner. A GUI host must not touch the repo:
    /// on macOS, reading or writing under ~/Desktop or ~/Documents blocks on
    /// the privacy (TCC) prompt and the run hangs; on a device the repo
    /// does not exist at all.
    public static var isHostedInApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    public var resultsDirectory: URL {
        if let configured = environment["VOLTA_EVAL_RESULTS"] { return URL(fileURLWithPath: configured) }
        if !Self.isHostedInApp, Self.packageRootExists {
            return Self.packageRoot.appendingPathComponent("docs/evals/results")
        }
        // Hosted: Application Support on the Mac, the container's Documents
        // on a device; entries are also printed as `[evals-entry]` lines so
        // scripts/evals-merge.py can fold them into the repo's map.
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
        return (base ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("VoltaSDKEvals/results")
    }

    public var capabilityMapURL: URL { resultsDirectory.appendingPathComponent("capability-map.json") }

    public var host: String {
        if let configured = environment["VOLTA_EVAL_HOST"] { return configured }
        #if os(iOS)
        return "iOS device"
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return "Mac (\(version))"
        #endif
    }

    // MARK: Task discovery

    public func taskURLs() -> [URL] {
        let url: URL
        if let path = environment["VOLTA_EVAL_TASKS"], !Self.isHostedInApp || !Self.isPrivacyProtected(path),
           FileManager.default.fileExists(atPath: path) {
            url = URL(fileURLWithPath: path)
        } else if let bundled = bundledTasksDirectory {
            // A hosted bundle carries the task files as a folder reference
            // (see the demo project.yml); Xcode copies the folder under its
            // on-disk name, so both spellings are accepted.
            url = bundled
        } else {
            return []
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [url] }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func modes() -> [EvalMode] {
        let configured = environment["VOLTA_EVAL_MODES"]?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } ?? ["raw"]
        return configured.compactMap(EvalMode.parse)
    }

    public func requestedTiers() -> [EvalTier] {
        guard let configured = environment["VOLTA_EVAL_TIERS"] else { return EvalTier.allCases }
        return configured.split(separator: ",").compactMap { EvalTier(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    public var limit: Int? { environment["VOLTA_EVAL_LIMIT"].flatMap(Int.init) }

    /// Tiers this process can build AND that report available right now,
    /// with the reason for each one it cannot reach.
    public func reachableTiers() async -> (reachable: [(EvalTier, any ModelProvider)], skipped: [(EvalTier, String)]) {
        var reachable: [(EvalTier, any ModelProvider)] = []
        var skipped: [(EvalTier, String)] = []
        for tier in requestedTiers() {
            switch tier.makeProvider(environment: environment) {
            case .failure(let reason):
                skipped.append((tier, reason.description))
            case .success(let provider):
                if case .unavailable(let reason) = await provider.availability() {
                    skipped.append((tier, reason))
                } else {
                    reachable.append((tier, provider))
                }
            }
        }
        return (reachable, skipped)
    }

    // MARK: Running

    public struct RunReport {
        public var entries: [CapabilityMap.Entry] = []
        public var skipped: [(EvalTier, String)] = []
        public var log: [String] = []
    }

    @available(iOS 27.0, macOS 27.0, *)
    public func runAll() async throws -> RunReport {
        var report = RunReport()
        let tasks = try taskURLs().map(EvalTask.load(from:))
        guard !tasks.isEmpty else {
            report.log.append("no tasks: set VOLTA_EVAL_TASKS to a task file or directory")
            return report
        }
        let (tiers, skipped) = await reachableTiers()
        report.skipped = skipped
        for (tier, reason) in skipped { report.log.append("skip \(tier.rawValue): \(reason)") }
        let judge = JudgeConfiguration.fromEnvironment(environment)
        var map = CapabilityMap.load(from: capabilityMapURL)

        // Handoff sweep (Q12/Q13): with VOLTA_EVAL_HANDOFF_TO=<tier>, every
        // multi-turn task also runs with later turns on that tier.
        let handoff: (EvalTier, any ModelProvider)? = {
            guard let name = environment["VOLTA_EVAL_HANDOFF_TO"], let tier = EvalTier(rawValue: name) else { return nil }
            guard let pair = tiers.first(where: { $0.0 == tier }) else {
                report.log.append("handoff tier \(name) unreachable in this process")
                return nil
            }
            return pair
        }()

        for task in tasks {
            for (tier, provider) in tiers {
                for mode in modes() {
                    if case .structured = mode, task.schema == nil {
                        report.log.append("skip \(task.id) @ \(tier.rawValue) [\(mode)]: no schema")
                        continue
                    }
                    if let handoff, handoff.0 != tier, task.samples.contains(where: { $0.turns.count > 1 }) {
                        let entry = try await run(task: task, tier: tier, provider: provider, mode: mode, judge: judge, handoff: handoff)
                        map.upsert(entry)
                        try map.save(to: capabilityMapURL)
                        report.entries.append(entry)
                        report.log.append("\(task.id) @ \(entry.tier) [\(mode)]: \(entry.passed)/\(entry.scored) pass (handoff after turn 1)")
                        if let data = try? CapabilityMap.lineEncoder.encode(entry), let line = String(data: data, encoding: .utf8) {
                            print("[evals-entry] \(line)")
                        }
                    }
                    let entry = try await run(task: task, tier: tier, provider: provider, mode: mode, judge: judge)
                    map.upsert(entry)
                    try map.save(to: capabilityMapURL)
                    report.entries.append(entry)
                    // One line per entry so a device run's log can be merged
                    // into the Mac's map (scripts/evals-merge.py).
                    if let data = try? CapabilityMap.lineEncoder.encode(entry), let line = String(data: data, encoding: .utf8) {
                        print("[evals-entry] \(line)")
                    }
                    report.log.append("\(task.id) @ \(tier.rawValue) [\(mode)]: \(entry.passed)/\(entry.scored) pass, availability \(CapabilityMap.percent(entry.availabilityRate))")
                }
            }
        }
        return report
    }

    @available(iOS 27.0, macOS 27.0, *)
    public func run(
        task: EvalTask,
        tier: EvalTier,
        provider: any ModelProvider,
        mode: EvalMode,
        judge: JudgeConfiguration?,
        handoff: (EvalTier, any ModelProvider)? = nil
    ) async throws -> CapabilityMap.Entry {
        let evaluation: TaskEvaluation
        if let handoff {
            evaluation = TaskEvaluation(
                task: task, tier: tier, mode: mode, provider: provider,
                handoffTier: handoff.0, handoffProvider: handoff.1,
                judgeEvaluator: judge?.makeEvaluator(for: task, tier: tier),
                limit: limit
            )
        } else {
            evaluation = TaskEvaluation(
                task: task, tier: tier, mode: mode, provider: provider,
                judgeEvaluator: judge?.makeEvaluator(for: task, tier: tier),
                limit: limit
            )
        }
        let result = try await evaluation.run(info: [
            "task": task.id, "schemaVersion": task.schemaVersion,
            "tier": tier.rawValue, "mode": mode.description, "host": host
        ])

        // Keep the framework's own record of the run (transcripts included).
        let runsDirectory = resultsDirectory.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        _ = try? result.saveJSON(to: runsDirectory, includeReportMetadata: true, includeTranscripts: true)

        var judgeSummary: CapabilityMap.JudgeSummary? = nil
        if let judge, let spec = task.judge, evaluation.judgeEvaluator != nil {
            var dimensions: [String: Double] = [:]
            var perSample: [String: [String: Double]] = [:]
            let detailed = result.detailed
            let samples = detailed[evaluation.inputColumn.name, FrameworkSample.self]
            for dimension in spec.dimensions {
                let metric = Metric(dimension.name)
                guard result.detailed.containsColumn(metric.name) else { continue }
                var scores: [Double] = []
                for (index, value) in result.detailed[metric: metric].enumerated() {
                    guard let score = value?.doubleValue else { continue }
                    scores.append(score)
                    if let sample = samples[index] { perSample[sample.id, default: [:]][dimension.name] = score }
                }
                if !scores.isEmpty { dimensions[dimension.name] = scores.reduce(0, +) / Double(scores.count) }
            }
            var agreement: JudgeAgreement? = nil
            if let path = environment["VOLTA_EVAL_HUMAN_RATINGS"], let human = HumanRatings.load(for: task.id, from: path) {
                agreement = JudgeAgreement.measure(judge: perSample, human: human)
            }
            judgeSummary = CapabilityMap.JudgeSummary(vendor: judge.vendor.rawValue, dimensions: dimensions, agreement: agreement)
        }

        return CapabilityMap.entry(from: result, evaluation: evaluation, host: host, judge: judgeSummary)
    }
}
