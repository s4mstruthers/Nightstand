import XCTest
@testable import Nightstand

/// Live lookups, so they only run when asked: `NIGHTSTAND_LIVE=1 swift test --filter CoverLookup`
final class CoverLookupTests: XCTestCase {
    func testSuggestionsGetCovers() async throws {
        guard ProcessInfo.processInfo.environment["NIGHTSTAND_LIVE"] != nil else {
            throw XCTSkip("Set NIGHTSTAND_LIVE to look covers up online.")
        }
        for (title, author) in [("Thinking, Fast and Slow", "Daniel Kahneman"), ("Kallocain", "Karin Boye"),
                                ("The Leopard", "Giuseppe Tomasi di Lampedusa"), ("We", "Yevgeny Zamyatin")] {
            let goodreads = try? await GoodreadsLookup.find(title: title, authors: [author])
            let catalogue = await DiscoverView.catalogueCover(title: title, authors: [author])
            print("COVER \(title): goodreads \(goodreads?.coverURL?.absoluteString ?? "none") | catalogue \(catalogue?.absoluteString ?? "none")")
            XCTAssertNotNil(goodreads?.coverURL ?? catalogue, title)
        }
    }
}
