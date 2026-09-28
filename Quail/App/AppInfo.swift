import Foundation

/// Static app metadata, shown on the About page (`AboutPage`).
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// "0.5.0 (8)" — the same shape `quail --version` prints.
    static var displayVersion: String {
        "\(version) (\(build))"
    }

    /// How this copy was distributed: Developer ID, as a DMG or through Homebrew (the Mac App Store build is
    /// gone, D-053).
    static var distribution: String {
        "Direct download"
    }

    /// The bundled llama.cpp release tag ("b11081"). `task embed:llama`
    /// copies `Vendor/llama.version` — the pin `task vendor:llama` downloads —
    /// into the app's Resources, so what's shown is what was vendored. `nil`
    /// if the file isn't there (an app built before the vendor step ran).
    static func llamaCppTag(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "llama", withExtension: "version"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        let tag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.isEmpty ? nil : tag
    }

    /// The notices file (`task notices`, ADR D-044): every bundled library's licence text.
    static func thirdPartyNotices(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// A bundled component's version as the notices file's table lists it ("mlx-swift-lm" → "3.31.4"), read once.
    static func componentVersion(_ name: String, in bundle: Bundle = .main) -> String? {
        if bundle == .main {
            return mainComponentVersions[name]
        }
        return componentVersions(in: thirdPartyNotices(in: bundle) ?? "")[name]
    }

    private static let mainComponentVersions = componentVersions(in: thirdPartyNotices() ?? "")

    /// The notices file's component table: `| Component | Version | Licence | Shipped in |` rows.
    static func componentVersions(in notices: String) -> [String: String] {
        var versions: [String: String] = [:]
        for line in notices.split(separator: "\n") where line.hasPrefix("| ") {
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, cells[0] != "Component", !cells[0].hasPrefix("---") else { continue }
            versions[cells[0]] = cells[1]
        }
        return versions
    }

    /// llama.cpp's licence text, which its MIT licence requires to travel with
    /// the app; `task embed:llama` copies it into Resources.
    static func llamaCppLicence(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "LICENSE-llama.cpp", withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// What the About page shows, gathered once so the rows and the
/// "copy for a bug report" text can't disagree.
struct AboutFacts: Equatable {
    var version: String
    var build: String
    var distribution: String
    var llamaCppTag: String?
    var catalogRevision: Int
    var catalogAsOf: String?
    var macOS: String
    /// The MLX engine's pins: mlx-swift-lm and the mlx-swift under it (from the notices file).
    var mlxSwiftLM: String?
    var mlxSwift: String?

    static func current(catalog: Catalog, bundle: Bundle = .main) -> AboutFacts {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AboutFacts(
            version: AppInfo.version,
            build: AppInfo.build,
            distribution: AppInfo.distribution,
            llamaCppTag: AppInfo.llamaCppTag(in: bundle),
            catalogRevision: catalog.revision,
            catalogAsOf: catalog.asOf,
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            mlxSwiftLM: AppInfo.componentVersion("mlx-swift-lm", in: bundle),
            mlxSwift: AppInfo.componentVersion("mlx-swift", in: bundle)
        )
    }

    var versionLine: String {
        "\(version) (\(build))"
    }

    var llamaCppLine: String {
        llamaCppTag ?? "—"
    }

    /// "mlx-swift-lm 3.31.4 (mlx-swift 0.31.6)", or a dash.
    var mlxLine: String {
        guard let mlxSwiftLM else { return "—" }
        return "mlx-swift-lm \(mlxSwiftLM)" + (mlxSwift.map { " (mlx-swift \($0))" } ?? "")
    }

    var catalogLine: String {
        catalogAsOf.map { "revision \(catalogRevision) · \($0)" } ?? "revision \(catalogRevision)"
    }

    /// Plain text for pasting into a bug report.
    var summary: String {
        var lines = ["Quail \(versionLine), \(distribution)"]
        lines.append("llama.cpp \(llamaCppLine)")
        if mlxSwiftLM != nil {
            lines.append("MLX: \(mlxLine)")
        }
        lines.append("Catalog \(catalogLine)")
        lines.append("macOS \(macOS)")
        return lines.joined(separator: "\n")
    }
}
