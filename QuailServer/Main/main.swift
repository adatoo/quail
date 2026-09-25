import Foundation
import QuailServerCore
import QuailServerLlama

let engines: [ModelKind: EngineFactory] = [
    .gguf: { _ in LlamaEngine() },
    .mlx: { _ in MLXEngine() },
]
await exit(QuailServerApp.run(arguments: Array(CommandLine.arguments.dropFirst()), engines: engines))
