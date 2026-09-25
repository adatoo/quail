import Foundation
import QuailServerCore
import QuailServerLlama

let engines: [ModelKind: EngineFactory] = [
    .gguf: { LlamaEngine(parallel: $0.parallel ?? 1) },
    .mlx: { _ in MLXEngine() },
]
await exit(QuailServerApp.run(arguments: Array(CommandLine.arguments.dropFirst()), engines: engines))
