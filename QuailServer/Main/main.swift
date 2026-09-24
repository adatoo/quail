import Foundation
import QuailServerCore

await exit(QuailServerApp.run(arguments: Array(CommandLine.arguments.dropFirst())))
