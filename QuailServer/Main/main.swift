import Foundation
import QuailServerCore
import QuailServerLlama

let engines: [ModelKind: EngineFactory] = [
    .gguf: { _ in LlamaEngine() },
]
await exit(QuailServerApp.run(arguments: Array(CommandLine.arguments.dropFirst()), engines: engines))
