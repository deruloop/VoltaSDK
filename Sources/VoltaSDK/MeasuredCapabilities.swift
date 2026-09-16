//
//  MeasuredCapabilities.swift
//  VoltaSDK
//
//  The capability map as a RUNTIME artifact (D22). The evaluation engine
//  (VoltaSDKEvals) measures, per task and per provider, how often a model
//  clears the app's own pass rules, and writes `capability-map.json`. An
//  app bundles that file, hands it to the orchestrator, and names the task
//  on each call; the chain then skips a provider that MEASURED below the
//  app's floor for that task — a per-task judgment instead of the tier
//  heuristics of D7. Unmeasured providers are never skipped: a missing row
//  is absence of evidence, and the rest of the chain (availability, pre-
//  flight, privacy, fallback) still applies.
//
//  The file format is the evaluation engine's own map, decoded tolerantly:
//  only the fields needed at runtime are read, so the same file serves
//  both the report and the gate.
//

import Foundation

// MARK: - The map

/// Pass rates measured per (task, provider, mode), loaded from the
/// evaluation engine's `capability-map.json`.
public struct MeasuredCapabilities: Sendable, Equatable {

    /// How the measured call was made. Matches the evaluation engine's
    /// mode names; the orchestrator picks the row that matches how the
    /// call it is about to make is shaped.
    public enum Mode: String, Sendable, Codable, CaseIterable {
        case raw
        case structured
        case structuredWithRepair = "structured+repair"
    }

    public struct Measurement: Sendable, Equatable, Codable {
        public let task: String
        public let provider: ProviderIdentifier
        public let mode: Mode
        /// Passed / scored (0...1).
        public let passRate: Double
        /// How many samples were scored; a floor over three samples is not a floor.
        public let samples: Int

        public init(task: String, provider: ProviderIdentifier, mode: Mode, passRate: Double, samples: Int) {
            self.task = task
            self.provider = provider
            self.mode = mode
            self.passRate = passRate
            self.samples = samples
        }
    }

    public let measurements: [Measurement]

    public init(measurements: [Measurement]) {
        self.measurements = measurements
    }

    /// Loads the evaluation engine's `capability-map.json`. Rows the file
    /// carries beyond what the runtime needs are ignored; rows without a
    /// recognizable provider are dropped.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let file = try JSONDecoder().decode(MapFile.self, from: data)
        self.measurements = file.entries.compactMap { row in
            guard let mode = Mode(rawValue: row.mode) else { return nil }
            let identifier = row.provider.map(ProviderIdentifier.init) ?? Self.provider(forTier: row.tier)
            guard let identifier else { return nil }
            return Measurement(task: row.task, provider: identifier, mode: mode, passRate: row.passRate, samples: row.scored)
        }
    }

    /// The best row for a task and provider: the exact mode when measured,
    /// otherwise the closest (structured rows stand in for each other,
    /// raw stands alone). `nil` = unmeasured.
    public func measurement(task: String, provider: ProviderIdentifier, mode: Mode) -> Measurement? {
        let rows = measurements.filter { $0.task == task && $0.provider == provider }
        if let exact = rows.first(where: { $0.mode == mode }) { return exact }
        switch mode {
        case .raw:
            return nil
        case .structured, .structuredWithRepair:
            return rows.first { $0.mode == .structured || $0.mode == .structuredWithRepair }
        }
    }

    /// Every task id the map knows.
    public var tasks: [String] {
        Array(Set(measurements.map(\.task))).sorted()
    }

    // MARK: File shape (tolerant subset of the engine's map)

    private struct MapFile: Decodable {
        let entries: [Row]
    }

    private struct Row: Decodable {
        let task: String
        let tier: String
        let provider: String?
        let mode: String
        let passRate: Double
        let scored: Int
    }

    /// Older maps name the tier, not the provider; the evaluation engine's
    /// tier names map onto the built-in identifiers.
    static func provider(forTier tier: String) -> ProviderIdentifier? {
        switch tier {
        case "on-device": return .onDevice
        case "pcc": return .privateCloudCompute
        case "cloud-openai": return .openAI
        case "cloud-anthropic": return .anthropic
        case "cloud-gemini": return .gemini
        default: return ProviderIdentifier(tier)
        }
    }
}

// MARK: - The per-call requirement

/// What a call needs from the capability map: the task it belongs to and
/// the pass rate a provider must have measured for that task to be tried.
public struct TaskRequirement: Sendable, Equatable {
    /// The task id, as written in the task file (`myapp.meal-record`).
    public let id: String
    /// Passed / scored below which a MEASURED provider is skipped. Unmeasured
    /// providers are always tried.
    public let minimumPassRate: Double
    /// Rows scored over fewer samples than this do not count as evidence.
    public let minimumSamples: Int

    public init(_ id: String, minimumPassRate: Double = 0.5, minimumSamples: Int = 5) {
        self.id = id
        self.minimumPassRate = minimumPassRate
        self.minimumSamples = minimumSamples
    }

    /// Whether a provider may be tried for this task, given the map.
    /// `nil` map or no usable row → allowed.
    func admits(_ provider: any ModelProvider, mode: MeasuredCapabilities.Mode, in capabilities: MeasuredCapabilities?) -> Bool {
        guard let capabilities,
              let row = capabilities.measurement(task: id, provider: provider.identifier, mode: mode),
              row.samples >= minimumSamples else { return true }
        return row.passRate >= minimumPassRate
    }
}
