import Foundation
import FoundationModels
import NaturalLanguage

/// Decides how attached PDFs reach the model:
///  • full      – the whole text fits the target model's context window
///  • summary   – too long, and the user wants a summary: Apple's model summarizes it section by section
///                (map-reduce, cached per document), then the final answer is written from those summaries
///  • retrieval – too long for anything else: the most relevant passages (BM25), with page numbers
enum DocumentContext {
    struct Failure: LocalizedError { let errorDescription: String? }

    typealias Emit = ([String: Any]) async throws -> Void

    static let sectionTokens = 2_800       // fits Apple's 8K window with room for instructions + output
    static let passageTokens = 450
    static let maxSummarySections = 80     // ~220K tokens; beyond this, fall back to retrieval

    /// The augmented conversation plus what the answer can be checked against.
    struct Prepared {
        var messages: [ChatMessage]
        var docs: [StoredDocument] = []
        var strategy = ""            // "full" | "summary" | "retrieval"
        var context = ""             // exactly what the model was shown
        var earlier: [StoredDocument] = []   // PDFs from earlier turns that this turn did not re-read
    }

    static func prepare(messages: [ChatMessage], mode: String, profile: QwenProfile, emit: Emit) async throws -> Prepared {
        var seen = Set<String>()
        let ids = messages.flatMap(\.documents).filter { seen.insert($0).inserted }
        guard !ids.isEmpty, let lastIdx = messages.lastIndex(where: { $0.role == "user" }) else { return Prepared(messages: messages) }
        let question = messages[lastIdx].content

        // Only the most recent attachment is read for this turn. Earlier PDFs were already read when they were
        // attached (the replies in the history cover them), so they're re-read only when the question asks for
        // them: by file name, or with wording like "compare", "both", "the first document".
        let latestIDs = messages.last(where: { $0.role == "user" && !$0.documents.isEmpty })?.documents ?? []
        var focus = Set(latestIDs)
        // Decide this before loading. If a requested older PDF has disappeared from the store,
        // it must produce an error rather than silently comparing only the files that remain.
        if asksAboutSeveralDocuments(question) { focus.formUnion(ids) }

        var all: [StoredDocument] = []
        for id in ids {
            guard let d = await DocumentStore.shared.get(id) else {
                if focus.contains(id) {
                    throw Failure(errorDescription: "A PDF in this conversation is no longer stored on this Mac. Attach it again.")
                }
                continue   // an older PDF that's gone doesn't block questions about the newer one
            }
            all.append(d)
        }
        for d in referencedEarlier(question, among: all.filter { !focus.contains($0.id) }) { focus.insert(d.id) }
        let docs = all.filter { focus.contains($0.id) }
        let earlier = all.filter { !focus.contains($0.id) }
        guard !docs.isEmpty else {
            throw Failure(errorDescription: "A PDF in this conversation is no longer stored on this Mac. Attach it again.")
        }
        let history = messages.reduce(0) { $0 + estimateTokens($1.content) }
        let ratio = ProcessInfo.processInfo.environment["LI_APPLE_BUDGET"].flatMap(Double.init) ?? 0.7
        let appleBudget = max(1_200, Int(Double(AppleModel.model.contextSize) * ratio) - history - 400)
        let qwenBudget = max(2_000, profile.contextTokens - 3_000 - history)
        let appleOK = AppleModel.isAvailable
        // In Auto mode, size for Qwen; the router then sends it to Apple only if it also fits Apple's window.
        let budget = (mode == "apple" && appleOK) ? appleBudget : qwenBudget

        let full = docs.map { render($0, body: numbered($0)) }.joined(separator: "\n\n")
        let context: String
        let note: String
        let strategy: String

        if estimateTokens(full) <= budget {
            context = full
            strategy = "full"
            note = "Read " + docs.map { "all \($0.pages.count) page\($0.pages.count == 1 ? "" : "s") of \($0.name)" }.joined(separator: " and ")
        } else if isSummaryRequest(question), appleOK, mode != "qwen",
                  let summarized = try await summarize(docs, finalBudget: mode == "qwen" ? qwenBudget : appleBudget,
                                                       profile: profile, emit: emit) {
            context = summarized.text
            note = summarized.note
            strategy = "summary"
        } else {
            let r = retrieve(docs, question: question, budget: budget)
            context = r.text
            note = r.note
            strategy = "retrieval"
        }

        let earlierNote = earlier.isEmpty ? "" :
            ". " + earlier.map(\.name).joined(separator: ", ") + " (attached earlier) wasn't read again"
        try await emit(["type": "context", "text": note + earlierNote])
        var out = messages
        out[lastIdx].documentContext = citationRules(docs, earlier: earlier) + "\n\n" + context
        return Prepared(messages: out, docs: docs, strategy: strategy, context: context, earlier: earlier)
    }

    /// Earlier PDFs the question explicitly asks about: named by file name, or referred to collectively.
    static func referencedEarlier(_ question: String, among earlier: [StoredDocument]) -> [StoredDocument] {
        guard !earlier.isEmpty else { return [] }
        if asksAboutSeveralDocuments(question) { return earlier }
        let q = question.lowercased()
        return earlier.filter { d in
            let stem = (d.name as NSString).deletingPathExtension.lowercased()
            return q.contains(d.name.lowercased()) || (stem.count >= 3 && q.contains(stem))
        }
    }

    static func asksAboutSeveralDocuments(_ question: String) -> Bool {
        let pattern = #"(?i)\b(compar\w*|both|versus|vs\.?|differen\w*|contrast|previous|earlier|prior|other (one|document|file|pdf)s?|(?:first|second|third|\d+(?:st|nd|rd|th)) (one|document|file|pdf)|all (the |of the |these |those )?(documents|files|pdfs)|each (document|file|pdf)|(documents|files|pdfs) (i|we) (attached|uploaded|shared))\b"#
        return question.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Rendering

    static func render(_ doc: StoredDocument, body: String) -> String {
        let name = doc.name.replacingOccurrences(of: "\"", with: "'")
        return "<document name=\"\(name)\" pages=\"\(doc.pages.count)\">\n\(body)\n</document>"
    }

    static func pageMarker(_ n: Int, of total: Int) -> String { "=== PAGE \(n) OF \(total) ===" }

    /// Citation instructions. No example page number: small models copy examples literally.
    static func citationRules(_ docs: [StoredDocument], earlier: [StoredDocument] = []) -> String {
        var rules = "The user attached the document(s) below. Base your answer on them.\n"
        rules += "Page citations: put the page number in parentheses after the sentence it supports, as (p. N). "
        rules += "Pages are marked with lines like \"=== PAGE N OF M ===\". Use only those page numbers. "
        rules += "Section, clause, or item numbers inside the text are NOT page numbers. If unsure of the page, give no citation.\n"
        for d in docs {
            rules += "• \(d.name) has exactly \(d.pages.count) page\(d.pages.count == 1 ? "" : "s"); valid citations are p. 1"
            rules += d.pages.count > 1 ? " to p. \(d.pages.count).\n" : " only.\n"
        }
        if docs.count > 1 { rules += "With several documents, name the file in the citation: (\(docs[0].name), p. N).\n" }
        if !earlier.isEmpty {
            rules += "Earlier in this conversation the user also attached " + earlier.map(\.name).joined(separator: ", ")
            rules += ". Its text is not included here; answer about it only from your earlier replies, and don't cite its pages.\n"
        }
        return rules
    }

    static func numbered(_ doc: StoredDocument) -> String {
        doc.pages.enumerated().filter { !$0.element.isEmpty }
            .map { "\(pageMarker($0.offset + 1, of: doc.pages.count))\n\($0.element)" }.joined(separator: "\n\n")
    }

    static func isSummaryRequest(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        return t.range(of: #"(?i)\b(summar\w*|overview|tl;?dr|recap|gist|outline|synopsis|key (points|takeaways|findings|ideas)|main (points|ideas|arguments?|themes?)|highlights|what('?s| is) (this|it) about)\b"#,
                       options: .regularExpression) != nil
    }

    static func pageList(_ pages: [Int]) -> String {
        let sorted = Array(Set(pages)).sorted()
        var ranges: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            ranges.append(i == j ? "\(sorted[i])" : "\(sorted[i])–\(sorted[j])")
            i = j + 1
        }
        return ranges.joined(separator: ", ")
    }

    // MARK: Chunking

    struct Chunk {
        let doc: Int
        let index: Int
        let firstPage: Int
        let lastPage: Int
        let text: String
        var pages: ClosedRange<Int> { firstPage...lastPage }
        var label: String { firstPage == lastPage ? "page \(firstPage)" : "pages \(firstPage)–\(lastPage)" }
    }

    /// Splits a document into chunks of roughly `target` tokens, never crossing paragraph boundaries
    /// unless a paragraph alone is too big. Page markers are kept inside the chunk text.
    static func chunks(_ doc: StoredDocument, docIndex: Int, target: Int) -> [Chunk] {
        var out: [Chunk] = []
        var buf = "", bufTokens = 0, start = 0, end = 0, markedPage = 0

        func flush() {
            if !buf.isEmpty { out.append(Chunk(doc: docIndex, index: out.count, firstPage: start, lastPage: end, text: buf)) }
            buf = ""; bufTokens = 0; markedPage = 0
        }

        for (i, page) in doc.pages.enumerated() where !page.isEmpty {
            let pageNo = i + 1
            for para in page.components(separatedBy: "\n\n") {
                for piece in split(para, target: target) {
                    let t = estimateTokens(piece)
                    if bufTokens + t > target, !buf.isEmpty { flush() }
                    if buf.isEmpty { start = pageNo }
                    if markedPage != pageNo {
                        buf += (buf.isEmpty ? "" : "\n\n") + pageMarker(pageNo, of: doc.pages.count) + "\n"
                        markedPage = pageNo
                    } else {
                        buf += "\n\n"
                    }
                    buf += piece
                    bufTokens += t
                    end = pageNo
                }
            }
        }
        flush()
        return out
    }

    static func split(_ text: String, target: Int) -> [String] {
        let t = estimateTokens(text)
        guard t > target else { return [text] }
        let chars = max(200, text.count * target / t)
        var out: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var cut = rest.index(rest.startIndex, offsetBy: chars, limitedBy: rest.endIndex) ?? rest.endIndex
            if cut < rest.endIndex, let space = rest[..<cut].lastIndex(where: { $0 == " " || $0 == "\n" }),
               rest.distance(from: rest.startIndex, to: space) > chars / 2 {
                cut = space
            }
            out.append(String(rest[..<cut]))
            rest = rest[cut...].drop(while: { $0 == " " || $0 == "\n" })
        }
        return out
    }

    // MARK: Retrieval (BM25)

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "were", "be", "it", "this",
        "that", "with", "as", "at", "by", "from", "what", "which", "who", "how", "why", "when", "where", "does", "do",
        "did", "can", "could", "should", "would", "about", "document", "pdf", "file", "page", "pages", "please", "tell",
        "me", "my", "you", "your", "i", "we", "they", "there", "their", "its", "into", "than", "then", "so", "if", "not",
        "no", "any", "all", "some", "say", "says", "said", "explain", "describe", "give", "list", "according",
    ]

    static func terms(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        let lower = text.lowercased()
        tokenizer.string = lower
        var out: [String] = []
        tokenizer.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            let w = String(lower[range])
            if w.count >= 2 || w.unicodeScalars.contains(where: { !$0.isASCII }), !stopwords.contains(w) { out.append(w) }
            return true
        }
        return out
    }

    static func retrieve(_ docs: [StoredDocument], question: String, budget: Int) -> (text: String, note: String) {
        let all = docs.enumerated().flatMap { chunks($0.element, docIndex: $0.offset, target: passageTokens) }
        let docTerms: [[String]] = all.map { terms($0.text) }
        let query = Set(terms(question))

        // BM25 scoring
        let n = Double(all.count)
        let avg = max(1, Double(docTerms.reduce(0) { $0 + $1.count }) / max(1, n))
        var df: [String: Int] = [:]
        for t in docTerms { for w in Set(t) where query.contains(w) { df[w, default: 0] += 1 } }
        func bm25(_ words: [String]) -> Double {
            var tf: [String: Int] = [:]
            for w in words where query.contains(w) { tf[w, default: 0] += 1 }
            let lengthNorm: Double = 0.25 + 0.75 * Double(words.count) / avg
            var score = 0.0
            for (term, count) in tf {
                let d = Double(df[term] ?? 1)
                let idf: Double = log(1 + (n - d + 0.5) / (d + 0.5))
                let f = Double(count)
                score += idf * f * 2.2 / (f + 1.2 * lengthNorm)
            }
            return score
        }
        let scores: [Double] = docTerms.map(bm25)

        // Always keep each document's opening (title, abstract, table of contents), then the best-scoring passages.
        var chosen = Set<Int>()
        var used = 0
        func take(_ i: Int) {
            let t = estimateTokens(all[i].text)
            if used + t <= budget { chosen.insert(i); used += t }
        }
        for d in docs.indices { if let first = all.firstIndex(where: { $0.doc == d }) { take(first) } }
        let ranked = all.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        let hasSignal = scores.contains { $0 > 0 }
        for i in (hasSignal ? ranked : Array(all.indices)) where !chosen.contains(i) {
            if hasSignal, scores[i] <= 0 { break }
            take(i)
            if used >= budget - 200 { break }
        }
        // Neighbors of strong hits add context when there's room.
        if hasSignal {
            for i in ranked.prefix(6) where scores[i] > 0 {
                for j in [i - 1, i + 1] where all.indices.contains(j) && all[j].doc == all[i].doc && !chosen.contains(j) { take(j) }
            }
        }

        var parts: [String] = []
        var notes: [String] = []
        for (d, doc) in docs.enumerated() {
            let picked = chosen.filter { all[$0].doc == d }.sorted()
            guard !picked.isEmpty else { continue }
            var body = ""
            var prev = -2
            for i in picked {
                if !body.isEmpty { body += i == prev + 1 ? "\n\n" : "\n\n[…]\n\n" }
                body += all[i].text
                prev = i
            }
            parts.append(render(doc, body: body))
            let pages = Set(picked.flatMap { Array(all[$0].pages) })
            notes.append("\(pages.count == 1 ? "page" : "pages") \(pageList(Array(pages))) of \(doc.name)")
        }
        return (parts.joined(separator: "\n\n"),
                "Too long to read in full, so it used the most relevant " + notes.joined(separator: " and "))
    }

    // MARK: Summary (map-reduce on Apple's model)

    static let sectionInstructions = """
    You summarize one section of a longer document. Write 4 to 8 concise bullet points that capture the key facts, \
    figures, names, decisions and conclusions. Use only information in the section. Do not add an introduction.
    """

    static func summarize(_ docs: [StoredDocument], finalBudget: Int, profile: QwenProfile,
                          emit: Emit) async throws -> (text: String, note: String)? {
        var parts: [String] = []
        var sectionsTotal = 0
        let plans = docs.enumerated().map { ($0.element, chunks($0.element, docIndex: $0.offset, target: sectionTokens)) }
        guard plans.reduce(0, { $0 + $1.1.count }) <= maxSummarySections else { return nil }

        for (doc, sections) in plans {
            if sections.count <= 1 {
                parts.append(render(doc, body: numbered(doc)))
                continue
            }
            var summaries: [String] = []
            for s in sections {
                let key = "\(sectionTokens):\(s.index)"
                let stored = await DocumentStore.shared.get(doc.id)
                if let cached = stored?.summaries[key] ?? doc.summaries[key] {
                    summaries.append("[\(s.label.capitalized)]\n\(cached)")
                    continue
                }
                try await emit(["type": "progress",
                                "message": "Summarizing \(doc.name), \(s.label) (section \(s.index + 1) of \(sections.count))…",
                                "done": s.index, "total": sections.count])
                let text = await summarizeSection(s.text, header: "Document: \(doc.name), \(s.label)", profile: profile)
                await DocumentStore.shared.setSummary(doc.id, key: key, text)
                summaries.append("[\(s.label.capitalized)]\n\(text)")
            }
            sectionsTotal += sections.count

            // Reduce: if the summaries are still too long for the final answer, summarize groups of them.
            // The combined result is cached per budget, so asking again doesn't redo this.
            var level = summaries
            var round = 0
            let share = max(800, finalBudget / docs.count)
            let reduceKey = "reduce:\(sectionTokens):\(share)"
            if let cached = await DocumentStore.shared.get(doc.id)?.summaries[reduceKey] {
                parts.append(render(doc, body: "Section-by-section summary, generated on device:\n\n" + cached))
                continue
            }
            while estimateTokens(level.joined(separator: "\n\n")) > share, level.count > 1, round < 3 {
                round += 1
                var groups: [[String]] = [[]]
                var size = 0
                for s in level {
                    let t = estimateTokens(s)
                    if size + t > sectionTokens, !groups[groups.count - 1].isEmpty { groups.append([]); size = 0 }
                    groups[groups.count - 1].append(s); size += t
                }
                var next: [String] = []
                for (gi, g) in groups.enumerated() {
                    try await emit(["type": "progress", "message": "Combining summaries of \(doc.name) (\(gi + 1) of \(groups.count))…"])
                    next.append(await summarizeSection(g.joined(separator: "\n\n"), header: "Summaries of consecutive sections of \(doc.name)", profile: profile))
                }
                level = next
            }
            if round > 0 { await DocumentStore.shared.setSummary(doc.id, key: reduceKey, level.joined(separator: "\n\n")) }
            parts.append(render(doc, body: "Section-by-section summary, generated on device:\n\n" + level.joined(separator: "\n\n")))
        }
        let names = docs.map(\.name).joined(separator: " and ")
        return (parts.joined(separator: "\n\n"),
                sectionsTotal > 0 ? "Summarized \(names) in \(sectionsTotal) sections on device, then answered from those summaries"
                                  : "Read all of \(names)")
    }

    /// Apple's model first; if it declines (guardrails, language), Qwen; failing both, a raw excerpt.
    static func summarizeSection(_ text: String, header: String, profile: QwenProfile) async -> String {
        do {
            let session = LanguageModelSession(instructions: sectionInstructions)
            let r = try await session.respond(to: "\(header)\n\n\(text)",
                                              options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 450))
            return r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            var out = ""
            let msgs = [ChatMessage(role: "system", content: sectionInstructions),
                        ChatMessage(role: "user", content: "\(header)\n\n\(text)")]
            if (try? await Ollama.chat(profile: profile, messages: msgs, think: false,
                                       onThinking: { _ in }, onDelta: { out += $0 })) != nil, !out.isEmpty {
                return out
            }
            return "Excerpt: " + String(text.prefix(1_200))
        }
    }
}
