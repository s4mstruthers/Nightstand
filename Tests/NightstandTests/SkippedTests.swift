import XCTest
@testable import Nightstand

final class SkippedTests: XCTestCase {
    func testSkippedBooksLeaveTheirListAndSurviveSaving() throws {
        var book = Book(title: "Rebel Star", format: .epub)
        book.status = .finished
        var companion = Companion()
        XCTAssertTrue(companion.needs(.unrated, book))

        companion.skipped[Insights.Issue.unrated.rawValue, default: []].insert(book.id)
        XCTAssertFalse(companion.needs(.unrated, book))
        // Skipping one list leaves the others alone.
        XCTAssertTrue(companion.needs(.noThoughts, book))

        let saved = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(companion))
        XCTAssertFalse(saved.needs(.unrated, book))

        // Files written before skipping existed still load.
        let old = try JSONDecoder().decode(Companion.self, from: Data(#"{"taste":"","recommendations":[]}"#.utf8))
        XCTAssertTrue(old.skipped.isEmpty)
    }
}
