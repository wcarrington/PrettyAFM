import XCTest
@testable import PrettyAFM

final class PrettyAFMTests: XCTestCase {
    func testContentLengthValidation() throws {
        XCTAssertEqual(try HTTPConnection.contentLength(nil), 0)
        XCTAssertEqual(try HTTPConnection.contentLength("0"), 0)
        XCTAssertEqual(try HTTPConnection.contentLength("42"), 42)
        XCTAssertThrowsError(try HTTPConnection.contentLength("-1"))
        XCTAssertThrowsError(try HTTPConnection.contentLength("12x"))
        XCTAssertThrowsError(try HTTPConnection.contentLength(""))
        XCTAssertThrowsError(try HTTPConnection.contentLength(String(HTTPConnection.maxBody + 1))) { error in
            guard case HTTPError.tooLarge = error else {
                return XCTFail("Expected tooLarge, got \(error)")
            }
        }
    }

    func testDocumentIDsRejectTraversalAndUppercase() {
        XCTAssertTrue(DocumentStore.isValidID(String(repeating: "a", count: 64)))
        XCTAssertFalse(DocumentStore.isValidID(String(repeating: "A", count: 64)))
        XCTAssertFalse(DocumentStore.isValidID("../" + String(repeating: "a", count: 61)))
    }

    func testCitationPageExpansion() {
        XCTAssertEqual(CitationCheck.expand("2–4, 7 and 9-10"), [2, 3, 4, 7, 9, 10])
    }

    func testPDFTextCleanup() {
        XCTAssertEqual(PDFExtractor.clean("hy-\nphen   words\n\n\nnext"), "hyphen words\n\nnext")
    }

    func testCollectiveDocumentReferencesAreDetectedBeforeLoading() {
        XCTAssertTrue(DocumentContext.asksAboutSeveralDocuments("Compare both PDFs"))
        XCTAssertTrue(DocumentContext.asksAboutSeveralDocuments("What changed in the second document?"))
        XCTAssertTrue(DocumentContext.asksAboutSeveralDocuments("Review all the files I attached"))
        XCTAssertFalse(DocumentContext.asksAboutSeveralDocuments("Summarize this document"))
    }

    func testEarlierDocumentCanBeSelectedByFilename() {
        let memo = StoredDocument(id: String(repeating: "a", count: 64), name: "Q3 Memo.pdf",
                                  pages: ["text"], ocrPages: 0)
        XCTAssertEqual(DocumentContext.referencedEarlier("What does Q3 Memo say?", among: [memo]).map(\.id), [memo.id])
        XCTAssertTrue(DocumentContext.referencedEarlier("Summarize the current attachment", among: [memo]).isEmpty)
    }

    func testShortEarlierFilenameDoesNotMatchUnrelatedCitationPrefix() {
        let current = StoredDocument(id: String(repeating: "a", count: 64), name: "current.pdf",
                                     pages: ["Revenue data rose sharply."], ocrPages: 0)
        let earlier = StoredDocument(id: String(repeating: "b", count: 64), name: "a.pdf",
                                     pages: ["Unrelated text."], ocrPages: 0)
        let result = CitationCheck.check("Revenue data rose sharply (data, p. 99).", docs: [current], earlier: [earlier])
        XCTAssertFalse(result.text.contains("p. 99"))
    }
}
