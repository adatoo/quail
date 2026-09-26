import Foundation

/// What a model is good for, shown as chips in the Add Model sheet and the Models list so people
/// can choose knowingly (ADR D-052). Curated per family in `catalog.json`'s `strengths`, except
/// `vision`, which comes from the catalog's own facts: a family shows it only when its GGUF
/// download has a vision projector, because that's the only way Quail can pass it an image today
/// (D-047; the MLX engine is text-only).
enum ModelStrength: String, CaseIterable, Identifiable, Sendable {
    case chat
    case coding
    case agentic
    case reasoning
    case longContext = "long-context"
    case vision
    case multilingual
    case embedding
    case audio

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .chat: "Chat"
        case .coding: "Coding"
        case .agentic: "Agents & tools"
        case .reasoning: "Reasoning"
        case .longContext: "Long context"
        case .vision: "Vision"
        case .multilingual: "Multilingual"
        case .embedding: "Embeddings"
        case .audio: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .agentic: "wrench.and.screwdriver"
        case .reasoning: "brain"
        case .longContext: "doc.text.magnifyingglass"
        case .vision: "eye"
        case .multilingual: "globe"
        case .embedding: "point.3.connected.trianglepath.dotted"
        case .audio: "waveform"
        }
    }

    /// One or two sentences for the ⓘ: what it means and when to want it.
    var explanation: String {
        switch self {
        case .chat:
            "A good everyday assistant: questions, writing, summaries."
        case .coding:
            "Writes, explains and fixes code well for its size."
        case .agentic:
            "Calls tools reliably, so it suits coding agents such as Claude Code, opencode, Codex and Qwen Code."
        case .reasoning:
            "Thinks step by step before answering — better at maths, planning and research questions, and slower to reply. With long context and tools, a good pick for deep research."
        case .longContext:
            "Trained for 128K tokens or more: long documents, big codebases, long agent sessions. The context Quail gives it still depends on this Mac's memory."
        case .vision:
            "Reads images you attach — screenshots, photos, diagrams. Works with the GGUF download, which includes the vision projector; Quail's MLX engine is text-only for now."
        case .multilingual:
            "Strong in many languages, not just English."
        case .embedding:
            "Turns text into vectors for search and retrieval — not a chat model."
        case .audio:
            "Understands speech and sound."
        }
    }

    /// Whether Quail can make use of it today. The model may still have it — the detail pane says so.
    var isUsableInQuail: Bool {
        self != .audio
    }

    /// `family`'s strengths, in display order: the curated ones Quail knows (unknown strings from a
    /// newer remote catalog are skipped), with `vision` decided by the GGUF projector — and dropped
    /// for an installed MLX copy, which Quail can't show images to.
    static func strengths(of family: Catalog.Family, format: ModelFormat? = nil) -> [ModelStrength] {
        var set = Set(family.strengths.compactMap(ModelStrength.init(rawValue:)))
        if family.gguf?.mmproj != nil, format != .mlxSafetensors {
            set.insert(.vision)
        } else {
            set.remove(.vision)
        }
        return allCases.filter(set.contains)
    }

    /// The "Good for" filter's choices.
    static let filterChoices: [ModelStrength] = [.coding, .agentic, .reasoning, .longContext, .vision, .chat]
}
