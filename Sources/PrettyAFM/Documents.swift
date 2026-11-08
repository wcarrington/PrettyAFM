import Foundation
import PDFKit
import Vision
import CryptoKit

/// Extracted text of an uploaded PDF, one string per page.
struct StoredDocument: Codable {
    let id: String            // SHA-256 of the file bytes
    let name: String
    let pages: [String]
    let ocrPages: Int
    /// Cached section summaries for long-document summarization, keyed by "<chunkTokens>:<index>".
    var summaries: [String: String] = [:]

    var tokens: Int { pages.reduce(0) { $0 + estimateTokens($1) } }

    var meta: [String: Any] {
        ["id": id, "name": name, "pages": pages.count, "tokens": tokens, "ocrPages": ocrPages]
    }
}

/// Keeps extracted documents in memory and in ~/Library/Application Support/PrettyAFM/documents,
/// so conversations still work after the server restarts.
actor DocumentStore {
    static let shared = DocumentStore()
    private var cache: [String: StoredDocument] = [:]
    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appending(path: "PrettyAFM/documents", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// IDs are SHA-256 hex digests; anything else is rejected (this also prevents path traversal).
    nonisolated static func isValidID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    func get(_ id: String) -> StoredDocument? {
        guard Self.isValidID(id) else { return nil }
        if let d = cache[id] { return d }
        guard let data = try? Data(contentsOf: dir.appending(path: "\(id).json")),
              let doc = try? JSONDecoder().decode(StoredDocument.self, from: data) else { return nil }
        cache[id] = doc
        return doc
    }

    func put(_ doc: StoredDocument) {
        cache[doc.id] = doc
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: dir.appending(path: "\(doc.id).json"), options: .atomic)
        }
    }

    func setSummary(_ id: String, key: String, _ summary: String) {
        guard var doc = get(id) else { return }
        doc.summaries[key] = summary
        put(doc)
    }
}

enum PDFExtractor {
    struct Failure: LocalizedError { let errorDescription: String? }

    static let maxOCRPages = 300

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts text page by page. Pages without a usable text layer (scans, photos of paper) are OCR'd on device.
    static func extract(data: Data, name: String,
                        progress: (_ page: Int, _ of: Int, _ ocr: Bool) async throws -> Void) async throws -> StoredDocument {
        let id = sha256(data)
        if var existing = await DocumentStore.shared.get(id) {
            if existing.name != name {   // Same file under a new name: keep the cached text, show the new name.
                existing = StoredDocument(id: id, name: name, pages: existing.pages, ocrPages: existing.ocrPages, summaries: existing.summaries)
                await DocumentStore.shared.put(existing)
            }
            return existing
        }

        guard data.starts(with: Data("%PDF".utf8)), let pdf = PDFDocument(data: data) else {
            throw Failure(errorDescription: "That file isn't a readable PDF.")
        }
        if pdf.isLocked {
            throw Failure(errorDescription: "This PDF is password-protected. Remove the password and try again.")
        }

        var pages: [String] = []
        var ocrCount = 0
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { pages.append(""); continue }
            var text = page.string ?? ""
            var usedOCR = false
            if text.filter({ $0.isLetter || $0.isNumber }).count < 25, ocrCount < maxOCRPages {
                try await progress(i + 1, pdf.pageCount, true)
                if let recognized = ocr(page), recognized.count > text.count {
                    text = recognized
                    ocrCount += 1
                    usedOCR = true
                }
            }
            pages.append(clean(text))
            if !usedOCR, i % 10 == 9 || i == pdf.pageCount - 1 { try await progress(i + 1, pdf.pageCount, false) }
        }

        guard pages.contains(where: { !$0.isEmpty }) else {
            throw Failure(errorDescription: "No text could be found in this PDF.")
        }
        let doc = StoredDocument(id: id, name: name, pages: pages, ocrPages: ocrCount)
        await DocumentStore.shared.put(doc)
        return doc
    }

    /// Renders the page and runs Vision's accurate text recognizer on it.
    static func ocr(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(3.0, 2400 / max(bounds.width, bounds.height))
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\u{0}", with: "")
        t = t.replacingOccurrences(of: #"(\w)-\n(\w)"#, with: "$1$2", options: .regularExpression)   // de-hyphenate line breaks
        t = t.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
