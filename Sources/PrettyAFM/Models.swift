import Foundation

enum Backend: String { case apple, qwen }

struct ChatMessage {
    let role: String          // "system" | "user" | "assistant"
    let content: String
    let images: [String]      // base64, no data: prefix
    let backend: Backend?     // which model produced an assistant turn
    let documents: [String]   // IDs of PDFs attached to this turn
    /// Document text injected server-side for this turn. Kept apart from `content`
    /// so routing classifies the user's own words, not the PDF.
    var documentContext = ""

    /// What the model actually sees.
    var fullContent: String {
        documentContext.isEmpty ? content : documentContext + "\n\nUser's message:\n" + content
    }

    init(role: String, content: String) {
        self.role = role; self.content = content; self.images = []; self.backend = nil; self.documents = []
    }

    init?(_ json: [String: Any]) {
        guard let role = json["role"] as? String, ["system", "user", "assistant"].contains(role) else { return nil }
        self.role = role
        self.content = json["content"] as? String ?? ""
        self.images = (json["images"] as? [String] ?? []).map { s in
            if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") { return String(s[s.index(after: comma)...]) }
            return s
        }
        self.backend = (json["backend"] as? String).flatMap(Backend.init(rawValue:))
        self.documents = (json["documents"] as? [String] ?? []).filter(DocumentStore.isValidID)
    }
}

/// Picks the Qwen build that fits this Mac's unified memory.
/// Override with `LI_QWEN_MODEL=<ollama tag>` (and optionally `LI_QWEN_CTX=<tokens>`).
struct QwenProfile {
    let model: String
    let displayName: String
    let contextTokens: Int
    let memoryGB: Int
    let note: String

    static func forThisMac() -> QwenProfile {
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let env = ProcessInfo.processInfo.environment
        var p: QwenProfile
        switch gb {
        case ..<30:
            // Qwen 3.8 is 27B-only (≥18 GB) and cannot fit beside macOS + Apple's model on 16–24 GB.
            p = QwenProfile(model: "qwen3.5:9b-q4_K_M", displayName: "Qwen 3.5 9B", contextTokens: 16_384, memoryGB: gb,
                            note: "Qwen 3.8 needs 32 GB or more, so this Mac uses Qwen 3.5 9B (4-bit).")
        case ..<60:
            p = QwenProfile(model: "qwen3.8:27b-q4_K_M", displayName: "Qwen 3.8 27B", contextTokens: 32_768, memoryGB: gb,
                            note: "Qwen 3.8 27B, 4-bit quantized.")
        default:
            p = QwenProfile(model: "qwen3.8:27b-q8_0", displayName: "Qwen 3.8 27B", contextTokens: 65_536, memoryGB: gb,
                            note: "Qwen 3.8 27B, 8-bit quantized.")
        }
        if let m = env["LI_QWEN_MODEL"], !m.isEmpty {
            p = QwenProfile(model: m, displayName: m, contextTokens: p.contextTokens, memoryGB: gb, note: "Set by LI_QWEN_MODEL.")
        }
        if let c = env["LI_QWEN_CTX"].flatMap(Int.init) {
            p = QwenProfile(model: p.model, displayName: p.displayName, contextTokens: c, memoryGB: gb, note: p.note)
        }
        return p
    }
}

/// Rough token estimate: ~4 ASCII characters per token, ~1 token per non-ASCII character
/// (CJK, emoji, accented text tokenize far less efficiently than English).
/// Used only to stay safely below the on-device model's context window.
func estimateTokens(_ text: String) -> Int {
    var ascii = 0, other = 0
    for scalar in text.unicodeScalars { if scalar.isASCII { ascii += 1 } else { other += 1 } }
    return max(1, ascii / 4 + other)
}
