import Foundation

/// One run of a fixed benchmark suite on one model, on one Mac (ADR D-023).
///
/// Everything needed to compare it with another run — hardware, model file,
/// engine build, conditions — travels with the numbers, because this is
/// also the format later sharing (Phase 2b step 6) will upload. Shared by
/// the app (which runs it and stores it) and the `quail` CLI (which prints
/// it). Add fields only as optionals; bump `schemaVersion` for anything
/// else.
struct BenchmarkResult: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = .init()
    /// Which fixed suite produced it — see `BenchmarkSuite.id`. Results
    /// from different suites aren't comparable.
    var suite: String
    var date: Date
    var quailVersion: String
    var hardware: Hardware
    var model: Model
    var engine: Engine
    var conditions: Conditions
    var measurements: Measurements
    /// What Quail's bandwidth-based estimate said generation would run at,
    /// for estimate-vs-measured.
    var estimatedTokensPerSecond: Double?

    struct Hardware: Codable, Sendable, Equatable {
        var chip: String?
        var marketingName: String?
        var modelIdentifier: String?
        var performanceCores: Int?
        var efficiencyCores: Int?
        var gpuCores: Int?
        var memoryBytes: Int64?
        var gpuWorkingSetBytes: Int64?
        var osVersion: String?
    }

    struct Model: Codable, Sendable, Equatable {
        /// The id the server lists it by (its filename stem).
        var id: String
        var format: String
        var sourceRepo: String?
        var quant: String?
        var params: String?
        var bytes: Int64
        var sha256: String?
        var architecture: String?
        var trainedContext: Int?
    }

    struct Engine: Codable, Sendable, Equatable {
        /// "llama.cpp" or "Quail server"
        var runtime: String
        /// The runtime's own build id, e.g. "b11081-161755f29".
        var build: String?
        /// The context the model was loaded with (per slot).
        var contextSize: Int?
        var slots: Int?
    }

    struct Conditions: Codable, Sendable, Equatable {
        /// "nominal" | "fair" | "serious" | "critical"
        var thermalState: String
        var lowPowerMode: Bool
        /// `nil` when it couldn't be read (e.g. a desktop Mac).
        var onBattery: Bool?
        /// Other models the server had loaded when the run began.
        var otherModelsLoaded: [String]

        /// Anything that makes this run less comparable, in words.
        var warnings: [String] {
            var warnings: [String] = []
            if thermalState != "nominal" {
                warnings.append("thermal state was \(thermalState)")
            }
            if lowPowerMode {
                warnings.append("Low Power Mode was on")
            }
            if onBattery == true {
                warnings.append("ran on battery")
            }
            if !otherModelsLoaded.isEmpty {
                warnings.append("other models were loaded: \(otherModelsLoaded.joined(separator: ", "))")
            }
            return warnings
        }
    }

    /// Median, min and max over a step's measured runs.
    struct Stat: Codable, Sendable, Equatable {
        var median: Double
        var min: Double
        var max: Double
        var samples: Int

        /// `nil` for no samples.
        static func of(_ values: [Double]) -> Stat? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let mid = sorted.count / 2
            let median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
            return Stat(median: median, min: sorted[0], max: sorted[sorted.count - 1], samples: sorted.count)
        }
    }

    struct Measurements: Codable, Sendable, Equatable {
        /// Seconds from asking the server to load the model until it
        /// reports it loaded.
        var loadSeconds: Stat?
        /// Prompt processing, tokens/s, for a 512- and a 4096-token prompt.
        var prompt512: Stat?
        /// `nil` when the model's context is too small (see `skipped`).
        var prompt4096: Stat?
        /// Generation, tokens/s, over 256 tokens.
        var generation256: Stat?
        /// Time to first token for the 512-token prompt, milliseconds.
        var timeToFirstTokenMs: Stat?
        /// Steps not run, and why.
        var skipped: [String] = []
    }
}

extension BenchmarkResult {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A human-readable one-machine summary, e.g. for pasting into an issue.
    var markdown: String {
        func stat(_ stat: Stat?, _ unit: String, digits: Int = 1) -> String {
            guard let stat else { return "—" }
            return String(format: "%.\(digits)f \(unit) (%.\(digits)f–%.\(digits)f)", stat.median, stat.min, stat.max)
        }
        let hardwareLine = [
            hardware.marketingName ?? hardware.chip,
            hardware.chip.flatMap { $0 == hardware.marketingName ? nil : $0 },
            hardware.gpuCores.map { "\($0)-core GPU" },
            hardware.memoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) },
            hardware.osVersion.map { "macOS \($0)" },
        ].compactMap(\.self).joined(separator: " · ")
        var lines = [
            "### \(model.id) — \(suite)",
            "",
            "- **Mac:** \(hardwareLine)",
            "- **Engine:** \(engine.runtime) \(engine.build ?? "")\(engine.contextSize.map { ", \($0) ctx" } ?? "")",
            "- **Model:** \([model.quant, model.params, ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)].compactMap(\.self).joined(separator: " · "))",
            "",
            "| Test | Result (median, min–max) |",
            "|---|---|",
            "| Prompt 512 | \(stat(measurements.prompt512, "tok/s")) |",
            "| Prompt 4096 | \(stat(measurements.prompt4096, "tok/s")) |",
            "| Generate 256 | \(stat(measurements.generation256, "tok/s")) |",
            "| Time to first token | \(stat(measurements.timeToFirstTokenMs, "ms", digits: 0)) |",
            "| Load | \(stat(measurements.loadSeconds, "s", digits: 2)) |",
        ]
        let notes = conditions.warnings + measurements.skipped
        if !notes.isEmpty {
            lines += ["", "Notes: " + notes.joined(separator: "; ")]
        }
        lines += ["", "_\(date.formatted(date: .abbreviated, time: .standard)) · Quail \(quailVersion)_"]
        return lines.joined(separator: "\n")
    }
}
