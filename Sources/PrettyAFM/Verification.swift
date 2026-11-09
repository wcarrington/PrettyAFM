import Foundation
import FoundationModels

// MARK: - Deterministic citation check (always on, no model calls)

/// Checks every "(p. N)" citation in an answer against the document's real pages.
/// Impossible pages (beyond the last page) are corrected to the page whose text best matches
/// the cited sentence, or removed. Valid citations are changed only when another page is a far better match.
enum CitationCheck {
    struct Result {
        var text: String
        var corrected = 0
        var removed = 0
        var changed: Bool { corrected + removed > 0 }
    }

    // A parenthetical that contains p./pp./page(s) followed by numbers, e.g. (p. 3), (pp. 2–3), (memo.pdf, p. 1), (page 2).
    static let citation = try! NSRegularExpression(
        pattern: #"\s?\(([^()\n]{0,80}?)\b(?:pp?\.|pages?)\s*(\d+(?:\s*(?:[–—-]|,|and|&)\s*\d+)*)\s*\)"#,
        options: [.caseInsensitive])

    static let debug = ProcessInfo.processInfo.environment["LI_DEBUG_CITATIONS"] != nil

    /// `earlier` are PDFs from previous turns that weren't shown this turn; citations naming them are left as they are.
    static func check(_ answer: String, docs: [StoredDocument], earlier: [StoredDocument] = []) -> Result {
        guard !docs.isEmpty else { return Result(text: answer) }
        let pageTerms: [[Set<String>]] = docs.map { $0.pages.map { Set(DocumentContext.terms($0)) } }
        let ns = answer as NSString
        var result = Result(text: answer)
        var out = ""
        var cursor = 0
        var sentenceStart = 0

        for m in citation.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let original = ns.substring(with: m.range)
            let prefix = ns.substring(with: m.range(at: 1))
            let numbers = ns.substring(with: m.range(at: 2))

            let names = { (d: StoredDocument) in
                let stem = (d.name as NSString).deletingPathExtension
                return prefix.localizedCaseInsensitiveContains(d.name)
                    || (stem.count >= 3 && prefix.localizedCaseInsensitiveContains(stem))
            }
            if earlier.contains(where: names), !docs.contains(where: names) {
                out += original; sentenceStart = cursor; continue
            }
            // Which document? Named in the citation, else the only one.
            let docIndex = docs.firstIndex(where: names)
                ?? (docs.count == 1 ? 0 : nil)

            // The claim: text from the previous sentence boundary (or citation) up to this citation.
            let claimRange = NSRange(location: sentenceStart, length: m.range.location - sentenceStart)
            var claim = ns.substring(with: claimRange)
            if let lastBreak = claim.range(of: #"[.!?\n](?=[^.!?\n]{12,}$)"#, options: .regularExpression) {
                claim = String(claim[lastBreak.upperBound...])
            }
            sentenceStart = cursor
            // Heading-style citations ("**Fees** (p. 1): $40/day…") put the claim after the citation.
            if DocumentContext.terms(claim).count < 4 {
                let rest = ns.substring(from: cursor)
                let end = rest.range(of: #"\n|\((?:[^()]*?)\b(?:pp?\.|pages?)\s*\d"#, options: [.regularExpression, .caseInsensitive])?.lowerBound ?? rest.endIndex
                claim += " " + String(rest[..<end].prefix(300))
            }

            guard let d = docIndex else { out += original; continue }   // ambiguous with several docs: leave it
            let pageCount = docs[d].pages.count
            let cited = expand(numbers)
            let claimTerms = Set(DocumentContext.terms(claim))
            func score(_ p: Int) -> Double {
                guard (1...pageCount).contains(p), !claimTerms.isEmpty else { return 0 }
                return Double(claimTerms.intersection(pageTerms[d][p - 1]).count) / Double(claimTerms.count)
            }
            let invalid = cited.filter { !(1...pageCount).contains($0) }
            let best = (1...pageCount).max { score($0) < score($1) } ?? 1
            let bestScore = score(best)
            let citedScore = cited.map(score).max() ?? 0
            let docLabel = docs.count > 1 ? "\(docs[d].name), " : ""

            let before = out.count
            defer {
                if debug {
                    let decision = out.count == before ? "REMOVED" : String(out.dropFirst(before)) == original ? "kept" : "-> " + String(out.dropFirst(before))
                    FileHandle.standardError.write(Data((String(format: "[citations] %@ cited %@ best p.%d (%.2f vs %.2f) | %@", decision, cited.description, best, bestScore, citedScore,
                                 String(claim.prefix(110)).replacingOccurrences(of: "\n", with: " ")) + "\n").utf8))
                }
            }
            if invalid.isEmpty, citedScore + 0.25 >= bestScore || claimTerms.count < 3 {
                out += original                                   // plausible: keep
            } else if bestScore >= 0.3 {
                out += " (\(docLabel)p. \(best))"                  // a clearly better page exists
                result.corrected += 1
            } else {
                let valid = cited.filter { (1...pageCount).contains($0) }
                if valid.isEmpty {
                    result.removed += 1                            // impossible and no good match: drop it
                } else {
                    out += " (\(docLabel)p. \(valid.map(String.init).joined(separator: ", ")))"
                    result.corrected += 1
                }
            }
        }
        out += ns.substring(from: cursor)
        result.text = out
        return result
    }

    static func expand(_ s: String) -> [Int] {
        var pages: [Int] = []
        for part in s.components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap({ $0.components(separatedBy: "and") }) {
            let bounds = part.components(separatedBy: CharacterSet(charactersIn: "–—-")).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 50 { pages += Array(bounds[0]...bounds[1]) }
            else if let first = bounds.first { pages.append(first) }
        }
        return pages
    }
}

// MARK: - Cross-model double-check (Accuracy: Checked / Deep)

@Generable
enum Verdict: String { case supported, partlySupported, notSupported }

@Generable
struct CheckedClaim {
    @Guide(description: "One factual claim from the answer, restated briefly")
    let claim: String
    @Guide(description: "Whether the document states this claim")
    let verdict: Verdict
    @Guide(description: "The page number where the document supports the claim, taken from the PAGE markers; 0 if not found")
    let page: Int
    @Guide(description: "An exact quote of at most 20 words copied from that page that supports the claim; empty if none")
    let evidence: String
}

@Generable
struct ClaimReport {
    @Guide(description: "Every factual claim in the answer, in order", .maximumCount(15))
    let claims: [CheckedClaim]
}

enum Verifier {
    struct Claim: Codable {
        let claim: String
        let verdict: String
        var page: Int
        let evidence: String
        var evidenceFound = false

        enum CodingKeys: String, CodingKey { case claim, verdict, page, evidence }
    }

    struct Review {
        var claims: [Claim]
        var checker: Backend
        var revisedText: String?
        var revisedBy: Backend?

        var supported: Int { claims.filter { $0.verdict == "supported" && $0.evidenceFound }.count }
        var problems: [Claim] { claims.filter { $0.verdict != "supported" } }

        var json: [String: Any] {
            ["checked": claims.count, "supported": supported, "problems": problems.count,
             "unconfirmed": claims.filter { $0.verdict == "supported" && !$0.evidenceFound }.count,
             "checker": checker.rawValue, "revised": revisedText != nil]
        }
    }

    static let checkInstructions = """
    You are a meticulous fact-checker. Compare an answer against the source document. \
    For each factual claim in the answer, decide whether the document supports it, give the page number \
    from the "=== PAGE N OF M ===" markers, and copy a short exact quote from that page as evidence. \
    Judge only against the document, not general knowledge. Ignore opinions, advice and formatting.
    """

    /// Fact-checks `answer` against the document text with the model that did NOT write it, when it fits;
    /// verifies the checker's quotes deterministically; and revises the answer with Qwen if problems are found.
    static func review(answer: String, question: String, prepared: DocumentContext.Prepared, drafter: Backend,
                       profile: QwenProfile, status: (String) async throws -> Void,
                       onRevisionStart: () async throws -> Void,
                       onRevisionDelta: (String) async throws -> Void) async throws -> Review? {
        let source = prepared.context
        let request = "Source document:\n\(source)\n\nQuestion asked: \(question)\n\nAnswer to check:\n\(answer)"

        // Prefer the other model as the checker. Apple can only check if everything fits its window.
        let appleFits = AppleModel.isAvailable &&
            estimateTokens(checkInstructions + request) + 900 < AppleModel.model.contextSize
        let checker: Backend = (drafter == .qwen && appleFits) ? .apple : .qwen
        try await status("Double-checking against the document with \(checker == .apple ? "Apple's model" : profile.displayName)…")

        var claims: [Claim]
        if checker == .apple {
            let session = LanguageModelSession(instructions: checkInstructions)
            guard let r = try? await session.respond(to: request, generating: ClaimReport.self,
                                                     options: GenerationOptions(samplingMode: .greedy)) else { return nil }
            claims = r.content.claims.map { Claim(claim: $0.claim, verdict: $0.verdict.rawValue, page: $0.page, evidence: $0.evidence) }
        } else {
            guard let c = try? await qwenCheck(request: request, profile: profile) else { return nil }
            claims = c
        }
        guard !claims.isEmpty else { return nil }

        // Don't trust the checker blindly either: its quote must really appear in the document.
        for i in claims.indices {
            if let page = locate(claims[i].evidence, in: prepared.docs) {
                claims[i].evidenceFound = true
                claims[i].page = page
            }
        }

        var review = Review(claims: claims, checker: checker)
        guard !review.problems.isEmpty else { return review }

        // Revise with Qwen (the stronger writer), streaming the replacement.
        try await status("Revising: \(review.problems.count) claim\(review.problems.count == 1 ? "" : "s") not supported by the document…")
        let findings = claims.map { c -> String in
            let tag = c.verdict == "supported" ? "SUPPORTED" : c.verdict == "partlySupported" ? "ONLY PARTLY SUPPORTED" : "NOT SUPPORTED"
            let page = c.page > 0 && c.evidenceFound ? ", p. \(c.page)" : ""
            return "- [\(tag)\(page)] \(c.claim)" + (c.evidenceFound ? " — evidence: \"\(c.evidence)\"" : "")
        }.joined(separator: "\n")
        var msg = ChatMessage(role: "user", content: """
        Question: \(question)

        Draft answer:
        \(answer)

        Fact-check of the draft against the document:
        \(findings)

        Rewrite the draft so that it keeps everything supported, removes or clearly qualifies anything not supported \
        or only partly supported, and uses the page numbers given in the fact-check. Do not add information that \
        isn't in the document. Keep the draft's format and tone. Output only the revised answer.
        """)
        msg.documentContext = DocumentContext.citationRules(prepared.docs) + "\n\n" + source
        try await onRevisionStart()
        var revised = ""
        _ = try await Ollama.chat(profile: profile, messages: [msg], think: false,
                                  onThinking: { _ in }, onDelta: { revised += $0; try await onRevisionDelta($0) })
        review.revisedText = revised
        review.revisedBy = .qwen
        return review
    }

    /// Qwen with Ollama structured outputs (JSON schema), so the result always parses.
    static func qwenCheck(request: String, profile: QwenProfile) async throws -> [Claim] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["claims": ["type": "array", "maxItems": 15, "items": [
                "type": "object",
                "properties": [
                    "claim": ["type": "string"],
                    "verdict": ["type": "string", "enum": ["supported", "partlySupported", "notSupported"]],
                    "page": ["type": "integer"],
                    "evidence": ["type": "string"],
                ],
                "required": ["claim", "verdict", "page", "evidence"],
            ]]],
            "required": ["claims"],
        ]
        let body: [String: Any] = [
            "model": profile.model, "stream": false, "think": false, "format": schema,
            "messages": [["role": "system", "content": checkInstructions], ["role": "user", "content": request]],
            "options": ["num_ctx": profile.contextTokens, "temperature": 0],
        ]
        var content = ""
        try await Ollama.streamLines(path: "api/chat", body: body) { obj in
            content += (obj["message"] as? [String: Any])?["content"] as? String ?? ""
        }
        struct Report: Codable { let claims: [Claim] }
        return try JSONDecoder().decode(Report.self, from: Data(content.utf8)).claims
    }

    /// Finds the page containing `quote`, tolerating whitespace, case and punctuation differences.
    static func locate(_ quote: String, in docs: [StoredDocument]) -> Int? {
        let q = normalize(quote)
        guard q.count >= 12 else { return nil }
        for d in docs {
            for (i, page) in d.pages.enumerated() where normalize(page).contains(q) { return i + 1 }
        }
        // Fallback: 80% of the quote's words appear on one page, in a short window.
        let words = q.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return nil }
        for d in docs {
            for (i, page) in d.pages.enumerated() {
                let pw = Set(normalize(page).split(separator: " ").map(String.init))
                if Double(words.filter(pw.contains).count) / Double(words.count) >= 0.8 { return i + 1 }
            }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}$%.]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
