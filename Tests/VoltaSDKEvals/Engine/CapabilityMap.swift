//
//  CapabilityMap.swift
//  VoltaSDKEvals
//
//  The artifact the evaluations exist to produce: task × tier × mode →
//  pass rate, as a JSON file an app (or the SDK, later) can read to gate a
//  feature honestly, plus a Markdown rendering for humans. Runs merge into
//  the existing file by key, so the map accumulates across machines and
//  sessions (the Mac's on-device row today, the iPhone's tomorrow).
//

import Evaluations
import Foundation
import TabularData

struct CapabilityMap: Codable {
    var generatedAt: Date
    var entries: [Entry]

    struct Entry: Codable, Identifiable {
        var task: String
        var taskTitle: String
        var schemaVersion: String
        var tier: String
        var tierLabel: String
        var mode: String
        /// Where the run happened (the Mac stands in for a device only when
        /// it says so here).
        var host: String
        var runAt: Date
        var samples: Int
        /// Samples the model actually answered (infrastructure failures
        /// excluded).
        var scored: Int
        var passed: Int
        var passRate: Double
        /// Phase 0: fraction of samples the model accepted at all.
        var availabilityRate: Double
        var languageAcceptedRate: Double
        /// Per-grader pass rates.
        var graders: [String: Double]
        /// Judge dimensions (means) when a judge ran, and its agreement with
        /// human ratings when those were supplied.
        var judge: JudgeSummary?
        /// A few failure rationales, for the article and for debugging.
        var failureSamples: [String]
        var meanLatencySeconds: Double?

        var id: String { "\(task)|\(tier)|\(mode)" }
    }

    struct JudgeSummary: Codable {
        var vendor: String
        var dimensions: [String: Double]
        var agreement: JudgeAgreement?
    }

    // MARK: Building an entry from a framework result

    @available(iOS 27.0, macOS 27.0, *)
    static func entry(
        from result: EvaluationResult,
        evaluation: TaskEvaluation,
        host: String,
        judge: JudgeSummary?
    ) -> Entry {
        let detailed = result.detailed
        let passes = Self.tally(detailed, metric: Graders.passMetric)
        let availability = Self.tally(detailed, metric: Graders.availabilityMetric)
        let language = Self.tally(detailed, metric: Graders.languageAcceptedMetric)

        var graders: [String: Double] = [:]
        for spec in evaluation.task.graders {
            let name = Graders.name(of: spec)
            let tally = Self.tally(detailed, metric: Metric(name))
            if tally.scored > 0 { graders[name] = Double(tally.passed) / Double(tally.scored) }
        }

        // The framework's generic `subscript(column:)` does not resolve
        // against this SDK's TabularData (the Int overload wins); the
        // column NAME + type form does the same job.
        let responses = detailed[evaluation.responseColumn.name, ModelSubject<EvalOutcome>.self]
        let outcomes: [EvalOutcome] = responses.compactMap { $0?.value }
        let latencies: [Double] = outcomes.flatMap { outcome in outcome.turns.compactMap { $0.latencySeconds } }

        return Entry(
            task: evaluation.task.id,
            taskTitle: evaluation.task.title,
            schemaVersion: evaluation.task.schemaVersion,
            tier: evaluation.tier.rawValue,
            tierLabel: evaluation.tier.label(),
            mode: evaluation.mode.description,
            host: host,
            runAt: result.endTime,
            samples: passes.total,
            scored: passes.scored,
            passed: passes.passed,
            passRate: passes.scored > 0 ? Double(passes.passed) / Double(passes.scored) : 0,
            availabilityRate: availability.total > 0 ? Double(availability.passed) / Double(availability.total) : 0,
            languageAcceptedRate: language.total > 0 ? Double(language.passed) / Double(language.total) : 0,
            graders: graders,
            judge: judge,
            failureSamples: Array(passes.rationales.prefix(6)),
            meanLatencySeconds: latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count)
        )
    }

    struct Tally {
        var total = 0
        var scored = 0
        var passed = 0
        var rationales: [String] = []
    }

    @available(iOS 27.0, macOS 27.0, *)
    static func tally(_ frame: DataFrame, metric: Metric) -> Tally {
        var tally = Tally()
        guard frame.containsColumn(metric.name) else { return tally }
        for value in frame[metric: metric] {
            tally.total += 1
            guard let value else { continue }
            switch value.value {
            case .passing:
                tally.scored += 1
                tally.passed += 1
            case .failing:
                tally.scored += 1
                if let rationale = value.rationale { tally.rationales.append(rationale) }
            case .scoring(let score):
                tally.scored += 1
                if score >= 1 { tally.passed += 1 }
            case .ignore:
                break
            @unknown default:
                break
            }
        }
        return tally
    }

    // MARK: Persistence

    static func load(from url: URL) -> CapabilityMap {
        guard let data = try? Data(contentsOf: url),
              let map = try? Self.decoder.decode(CapabilityMap.self, from: data) else {
            return CapabilityMap(generatedAt: Date(), entries: [])
        }
        return map
    }

    mutating func upsert(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { ($0.task, $0.tier, $0.mode) < ($1.task, $1.tier, $1.mode) }
        generatedAt = Date()
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url)
        try markdown.write(to: url.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Compact, one-line encoding for log output.
    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Markdown rendering

    /// One table per task: rows = tiers, columns = modes. Cells show the
    /// pass rate over scored samples, with the availability rate when it
    /// is below 100%.
    var markdown: String {
        var text = "# Capability map\n\nGenerated \(Self.dateFormatter.string(from: generatedAt)). Pass rate = passed / scored; scored excludes infrastructure failures (unsupported language, unavailability, rate limits), which show as availability.\n"
        let tasks = Dictionary(grouping: entries, by: \.task).sorted { $0.key < $1.key }
        for (task, rows) in tasks {
            let title = rows.first?.taskTitle ?? task
            let version = rows.first?.schemaVersion ?? ""
            let modes = Array(Set(rows.map(\.mode))).sorted(by: Self.modeOrder)
            text += "\n## \(title) (`\(task)`, schema \(version))\n\n"
            text += "| Tier | Host | " + modes.joined(separator: " | ") + " |\n"
            text += "|---|---|" + modes.map { _ in "---" }.joined(separator: "|") + "|\n"
            let tiers = Dictionary(grouping: rows, by: \.tier).sorted { $0.key < $1.key }
            for (tier, tierRows) in tiers {
                let host = tierRows.first?.host ?? ""
                let label = tierRows.first?.tierLabel ?? tier
                let cells = modes.map { mode -> String in
                    guard let row = tierRows.first(where: { $0.mode == mode }) else { return "—" }
                    var cell = "\(Self.percent(row.passRate)) (\(row.passed)/\(row.scored))"
                    if row.availabilityRate < 1 { cell += " · avail \(Self.percent(row.availabilityRate))" }
                    if let judge = row.judge {
                        let dims = judge.dimensions.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.percent($0.value))" }
                        cell += " · judge " + dims.joined(separator: ", ")
                        if let agreement = judge.agreement { cell += " (κ \(String(format: "%.2f", agreement.kappa)), n=\(agreement.overlap))" }
                    }
                    return cell
                }
                text += "| \(label) | \(host) | " + cells.joined(separator: " | ") + " |\n"
            }
            // Grader breakdown for the raw mode, the most diagnostic one.
            if let raw = rows.first(where: { $0.mode == "raw" }) ?? rows.first {
                let breakdown = raw.graders.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.percent($0.value))" }
                if !breakdown.isEmpty {
                    text += "\nGraders (\(raw.tier), \(raw.mode)): " + breakdown.joined(separator: " · ") + "\n"
                }
            }
        }
        return text
    }

    static func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

    static func modeOrder(_ a: String, _ b: String) -> Bool {
        let order = ["raw", "structured", "structured+repair"]
        return (order.firstIndex(of: a) ?? 99) < (order.firstIndex(of: b) ?? 99)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

