import XCTest
@testable import Nightstand

final class FontImportTests: XCTestCase {
    /// Fonts usually arrive zipped, often with macOS's __MACOSX clutter; only the real font files are kept.
    func testImportsFontsFromZip() throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "font-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let source = work.appending(path: "Source")
        try fm.createDirectory(at: source.appending(path: "__MACOSX"), withIntermediateDirectories: true)
        for name in ["Test-Regular.ttf", "Test-Bold.ttf", "TestBlack-Regular.otf", "readme.txt", "__MACOSX/._Test-Regular.ttf"] {
            try Data("x".utf8).write(to: source.appending(path: name))
        }
        let zip = work.appending(path: "Test-fonts.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", source.path, zip.path]
        try process.run()
        process.waitUntilExit()

        let library = work.appending(path: "Fonts")
        let added = try FontLibrary.importFiles([zip], into: library)
        XCTAssertEqual(Set(added), ["Test", "Test Black"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path).sorted(),
                       ["Test-Bold.ttf", "Test-Regular.ttf", "TestBlack-Regular.otf"])
        XCTAssertEqual(try FontLibrary.importFiles([source.appending(path: "readme.txt")], into: library), [])
    }
}
