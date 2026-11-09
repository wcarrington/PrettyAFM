import Foundation
import FoundationModels

enum AppleModel {
    static var model: SystemLanguageModel { .default }

    static var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    static func status() -> [String: Any] {
        var out: [String: Any] = ["contextTokens": model.contextSize]
        switch model.availability {
        case .available:
            out["available"] = true
        case .unavailable(let reason):
            out["available"] = false
            out["reason"] = switch reason {
            case .deviceNotEligible: "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: "Turn on Apple Intelligence in System Settings."
            case .modelNotReady: "Apple's model is still downloading. Try again shortly."
            @unknown default: "Apple's model is unavailable."
            }
        }
        return out
    }

    static let defaultInstructions = """
    You are a helpful, concise assistant running privately on the user's Mac. \
    Format answers with Markdown when it helps readability. \
    If a request needs detailed factual knowledge, code, or multi-step math, say so briefly rather than guessing.
    """

    /// Rebuilds the conversation as a real Transcript so the model sees proper turns,
    /// including turns that Qwen answered earlier in a mixed conversation.
    static func makeSession(history: [ChatMessage]) -> LanguageModelSession {
        let system = history.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: [.text(.init(content: system.isEmpty ? defaultInstructions : system))],
                toolDefinitions: []))
        ]
        for m in history where m.role != "system" {
            let seg = Transcript.Segment.text(.init(content: m.fullContent))
            if m.role == "user" {
                entries.append(.prompt(Transcript.Prompt(segments: [seg])))
            } else {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [seg])))
            }
        }
        return LanguageModelSession(transcript: Transcript(entries: entries))
    }

    /// Streams text deltas. Snapshots from FoundationModels are cumulative, so we diff them.
    static func stream(history: [ChatMessage], prompt: String,
                       onText: (_ text: String, _ replaceAll: Bool) async throws -> Void) async throws -> Int {
        let session = makeSession(history: history)
        var sent = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            let text = snapshot.content
            if text.hasPrefix(sent) {
                let delta = String(text.dropFirst(sent.count))
                if !delta.isEmpty { try await onText(delta, false) }
            } else {
                // Rare: the model revised earlier text. Tell the client to replace everything.
                try await onText(text, true)
            }
            sent = text
        }
        return estimateTokens(sent)
    }

    /// Errors that mean "the on-device model can't do this", which are worth retrying on Qwen.
    static func shouldFallBack(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        guard let e = error as? LanguageModelSession.GenerationError else {
            // Other framework errors (e.g. an opaque LanguageModelError -1) are transient model failures: let Qwen answer.
            return String(reflecting: type(of: error)).hasPrefix("FoundationModels.")
                ? "The on-device model hit an internal error." : nil
        }
        switch e {
        case .exceededContextWindowSize: return "The conversation outgrew the on-device model's context window."
        case .guardrailViolation: return "The on-device model's safety guardrails declined this request."
        case .unsupportedLanguageOrLocale: return "The on-device model doesn't support this language."
        case .refusal: return "The on-device model declined this request."
        case .assetsUnavailable: return "Apple's model assets are unavailable right now."
        default: return nil
        }
    }
}
