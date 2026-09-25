import Foundation

/// The whole server, start to signal. The `quail-server` tool is one line that
/// calls this; it's public because the tool is a separate module. The engines are handed in by
/// the tool, so this module links no model runtime and the tests never load one.
public enum QuailServerApp {
    /// - Parameter engines: how to make the engine for each model format this build can serve.
    public static func run(arguments: [String], engines: [ModelKind: EngineFactory] = [:]) async -> Int32 {
        let command: ServerCommand
        do {
            command = try ServerArguments.parse(arguments)
        } catch {
            FileHandle.standardError
                .write(Data("quail-server: \(error.localizedDescription)\n\n\(ServerArguments.usage)\n".utf8))
            return 2
        }
        switch command {
        case .help:
            print(ServerArguments.usage)
            return 0
        case .version:
            print("quail-server \(version)")
            return 0
        case let .run(arguments):
            return await serve(arguments, engines: engines)
        }
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static func engineFactory(
        for choice: ServerArguments.EngineChoice,
        engines: [ModelKind: EngineFactory] = [:]
    ) -> EngineFactory {
        #if DEBUG
            if choice == .echo {
                return { _ in EchoEngine() }
            }
        #endif
        // A format with no engine in this build says so, instead of pretending.
        return { entry in
            guard let make = engines[entry.kind] else { throw EngineError.noEngine(entry.kind) }
            return try make(entry)
        }
    }

    private static func serve(_ arguments: ServerArguments, engines: [ModelKind: EngineFactory]) async -> Int32 {
        let log = ServerLog(fileURL: arguments.logFile)
        let presets = arguments.presetsFile.map(PresetsFile.load) ?? []
        let entries = ModelDiscovery.discover(
            modelsDirectory: arguments.modelsDirectory,
            mlxDirectory: arguments.mlxDirectory,
            presets: presets
        )
        log.log(.info, "quail-server \(version): \(entries.count) model(s)")
        for entry in entries where !entry.ignoredPresetKeys.isEmpty {
            log.log(.warn, "\(entry.id): ignoring preset keys \(entry.ignoredPresetKeys.joined(separator: ", "))")
        }

        let router = ModelRouter(
            entries: entries,
            modelsMax: arguments.modelsMax,
            makeEngine: engineFactory(for: arguments.engine, engines: engines),
            log: log
        )
        let routes = ServerRoutes(
            router: router,
            apiKey: arguments.apiKey,
            log: log,
            requestGuard: RequestGuard(bindHost: arguments.host, allowedOrigins: arguments.allowedOrigins),
            buildLabel: "quail-server \(version)",
            webUI: arguments.webUI
        )
        let server = HTTPServer(host: arguments.host, port: arguments.port, log: log)

        let port: Int
        do {
            port = try await server.start { await routes.handle($0) }
        } catch {
            log.log(.error, error.localizedDescription)
            return 1
        }
        log.log(.info, "listening on http://\(arguments.host):\(port)")
        await router.startAutoloads()

        let signal = await SignalWaiter().wait(for: [SIGTERM, SIGINT])
        log.log(.info, "signal \(signal): shutting down")
        server.stop()
        await router.shutdown()
        return 0
    }
}

/// Waits for the first of a set of signals. Dispatch sources rather than a C
/// handler, so shutdown runs as ordinary async code.
final class SignalWaiter: @unchecked Sendable {
    private var sources: [any DispatchSourceSignal] = []

    func wait(for signals: [Int32]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let once = OnceFlag()
            for number in signals {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler {
                    if once.claim() {
                        continuation.resume(returning: number)
                    }
                }
                source.resume()
                sources.append(source)
            }
        }
    }
}
