import Foundation
import QuailServerCore
import QuailServerLlama

/// Per format, the chat engine, or for a model that doesn't chat the embedding engine (ADR D-072).
let engines: [ModelKind: EngineFactory] = [
    .gguf: { $0.task == .chat ? LlamaEngine(parallel: $0.parallel ?? 1) as any Engine : LlamaEmbeddingEngine() },
    .mlx: { $0.task == .chat ? MLXEngine(parallel: $0.parallel ?? 1) as any Engine : MLXEmbeddingEngine() },
]
await exit(QuailServerApp.run(arguments: Array(CommandLine.arguments.dropFirst()), engines: engines))
