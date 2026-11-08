import Foundation
import FoundationModels

/// Categories the on-device model sorts requests into. Apple documents its ~3B on-device model as
/// strong at summarization, extraction, classification, rewriting, short creative text and dialog,
/// and not designed for world knowledge, advanced reasoning, math or code.
@Generable
enum TaskKind: String, CaseIterable {
    case summarize, rewrite, extract, classify, shortCreative, casualChat, brainstorm, simpleQuestion
    case code, math, reasoning, factualKnowledge, longForm, translation, technical

    var backend: Backend {
        switch self {
        case .summarize, .rewrite, .extract, .classify, .shortCreative, .casualChat, .brainstorm, .simpleQuestion: .apple
        case .code, .math, .reasoning, .factualKnowledge, .longForm, .translation, .technical: .qwen
        }
    }

    var label: String {
        switch self {
        case .summarize: "Summarizing"; case .rewrite: "Rewriting"; case .extract: "Extraction"
        case .classify: "Classification"; case .shortCreative: "Short creative writing"
        case .casualChat: "Conversation"; case .brainstorm: "Brainstorming"; case .simpleQuestion: "Simple question"
        case .code: "Code"; case .math: "Math"; case .reasoning: "Multi-step reasoning"
        case .factualKnowledge: "Factual knowledge"; case .longForm: "Long-form writing"
        case .translation: "Translation"; case .technical: "Technical explanation"
        }
    }
}

@Generable
struct Triage {
    @Guide(description: "The single category that best describes what the user's latest message asks for")
    let kind: TaskKind
}

struct RouteDecision {
    let backend: Backend
    let reason: String
    let category: String?
    let method: String   // "manual" | "rule" | "classifier"

    var json: [String: Any] {
        var o: [String: Any] = ["backend": backend.rawValue, "reason": reason, "method": method]
        if let category { o["category"] = category }
        return o
    }
}

enum Router {
    static let triageInstructions = """
    You route requests between two local AI models. Classify the user's request into exactly one category.
    summarize: condense provided text. rewrite: proofread, change tone, shorten, or rephrase provided text.
    extract: pull names, dates, items, or fields out of provided text. classify: label, tag, or judge sentiment.
    shortCreative: a short poem, caption, title, slogan, or message. casualChat: greetings, small talk, personal advice.
    brainstorm: list ideas. simpleQuestion: an everyday question answerable in a few sentences without specialist facts.
    code: writing, explaining, or debugging code, shell commands, regex, or SQL. math: calculations, equations, proofs.
    reasoning: logic puzzles, planning with constraints, comparing tradeoffs in depth.
    factualKnowledge: history, science, geography, people, products, statistics, or anything where exact facts matter.
    longForm: essays, reports, stories, or articles longer than a few paragraphs. translation: translating text.
    technical: in-depth explanations of technical, medical, legal, or financial topics.
    """

    static func decide(messages: [ChatMessage], mode: String, think: Bool) async -> RouteDecision {
        let appleOK = AppleModel.isAvailable
        switch mode {
        case "apple":
            if appleOK { return .init(backend: .apple, reason: "You chose Apple's on-device model.", category: nil, method: "manual") }
            return .init(backend: .qwen, reason: "Apple's model isn't available on this Mac, so Qwen answered.", category: nil, method: "rule")
        case "qwen":
            return .init(backend: .qwen, reason: "You chose Qwen.", category: nil, method: "manual")
        default: break
        }

        guard appleOK else {
            return .init(backend: .qwen, reason: "Apple's model isn't available on this Mac.", category: nil, method: "rule")
        }
        if think {
            return .init(backend: .qwen, reason: "Think mode needs a reasoning model.", category: "Reasoning", method: "rule")
        }

        let last = messages.last(where: { $0.role == "user" })
        let text = last?.content ?? ""

        if messages.contains(where: { !$0.images.isEmpty }) {
            return .init(backend: .qwen, reason: "Images need a vision model. Apple's on-device model accepts text only.", category: "Vision", method: "rule")
        }

        // Keep well inside the on-device window: prompt + history + room for the reply.
        let ratio = ProcessInfo.processInfo.environment["LI_APPLE_BUDGET"].flatMap(Double.init) ?? 0.7
        let budget = Int(Double(AppleModel.model.contextSize) * ratio)
        let used = messages.reduce(0) { $0 + estimateTokens($1.fullContent) }
        if used > budget {
            return .init(backend: .qwen, reason: "About \(used.formatted()) tokens is too long for the on-device model's \(AppleModel.model.contextSize.formatted())-token window.", category: "Long context", method: "rule")
        }

        let hasDocs = !(last?.documentContext.isEmpty ?? true)
        if hasDocs, DocumentContext.isSummaryRequest(text) {
            return .init(backend: .apple, reason: "Summarizing a document is a core strength of Apple's on-device model.", category: TaskKind.summarize.label, method: "rule")
        }
        if looksLikeCode(text) {
            return .init(backend: .qwen, reason: "The message contains code.", category: TaskKind.code.label, method: "rule")
        }
        if looksLikeMath(text) {
            return .init(backend: .qwen, reason: "The message contains math.", category: TaskKind.math.label, method: "rule")
        }

        if text.range(of: #"(?i)^\W*(hi|hey|hello|yo|howdy|thanks|thank you|thx|good (morning|afternoon|evening|night)|ok|okay|cool|great)\b[\s\W\w]{0,20}$"#, options: .regularExpression) != nil, words(text) <= 4 {
            return .init(backend: .apple, reason: "Apple's on-device model handles this well.", category: TaskKind.casualChat.label, method: "rule")
        }

        // Short follow-ups ("shorter", "why?", "another one") stay with whichever model answered last.
        if words(text) <= 8, last?.documents.isEmpty ?? true, let prev = messages.last(where: { $0.role == "assistant" })?.backend {
            return .init(backend: prev, reason: "A short follow-up stays with the model that answered last.", category: nil, method: "rule")
        }

        if let kind = await classify(text) {
            let who = kind.backend == .apple ? "Apple's on-device model handles this well." : "Qwen is stronger at this."
            return .init(backend: kind.backend, reason: who, category: kind.label, method: "classifier")
        }
        return .init(backend: .apple, reason: "Couldn't classify the request, so the faster on-device model answered.", category: nil, method: "rule")
    }

    /// Asks the on-device model to classify the request with guided generation. Returns nil on error or after 5 seconds.
    static func classify(_ text: String) async -> TaskKind? {
        let snippet = String(text.prefix(2_000))
        return await withTaskGroup(of: TaskKind?.self) { group in
            group.addTask {
                let session = await TriagePool.shared.take()
                let result = try? await session.respond(
                    to: "Request:\n\"\"\"\n\(snippet)\n\"\"\"",
                    generating: Triage.self,
                    options: GenerationOptions(samplingMode: .greedy))
                return result?.content.kind
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func words(_ t: String) -> Int { t.split(whereSeparator: \.isWhitespace).count }

    static func looksLikeCode(_ t: String) -> Bool {
        if t.contains("```") { return true }
        let patterns = [
            #"(?m)^\s*(def|class|func|fn|import|from|#include|public|private|const|let|var|SELECT|CREATE)\s"#,
            #"(?m)[;{}]\s*$"#,
            #"Traceback \(most recent call last\)|at [\w.$]+\([\w.]+:\d+\)|error\[E\d+\]|Exception:"#,
            #"(?i)\b(python|javascript|typescript|swift|rust|golang|kotlin|java|c\+\+|sql|regex|bash|zsh|powershell)\b.*\b(code|script|function|query|program|snippet|write|fix|debug)\b"#,
            #"(?i)\b(write|fix|debug|refactor|implement)\b.*\b(code|function|script|class|method|algorithm|program)\b"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    static func looksLikeMath(_ t: String) -> Bool {
        let patterns = [
            #"\d+(\.\d+)?\s*[\^×÷*/]\s*\d"#,
            #"\d+\s*[+\-]\s*\d+\s*[*/^=]"#,
            #"(?i)\b(integral|derivative|differentiate|integrate|solve for|equation|prove that|theorem|matrix|eigen|probability that)\b"#,
            #"[∫∑√π∂≤≥]"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }
}

/// Keeps one pre-warmed triage session ready so routing doesn't pay the model's load cost.
actor TriagePool {
    static let shared = TriagePool()
    private var ready: LanguageModelSession?

    private func make() -> LanguageModelSession {
        let s = LanguageModelSession(instructions: Router.triageInstructions)
        s.prewarm(promptPrefix: Prompt("Request:\n\"\"\"\n"))
        return s
    }

    func warm() { if ready == nil, AppleModel.isAvailable { ready = make() } }

    func take() -> LanguageModelSession {
        let s = ready ?? make()
        ready = make()
        return s
    }
}
