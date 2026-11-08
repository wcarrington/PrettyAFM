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
}
