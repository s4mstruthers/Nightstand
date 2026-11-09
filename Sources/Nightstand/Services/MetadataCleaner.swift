import Foundation

/// Tidies titles, authors and series using only what is already in the library — no network.
///
/// It fixes the usual mess in e-book metadata: "Wong, Tao" beside "Tao Wong", series hidden in titles such as
/// "Rebel Star: A LitRPG Space Opera (System Apocalypse Book 8)", and the same series or author spelled
/// several ways. Nothing is applied here; callers show the proposals for review first.
enum MetadataCleaner {
    struct Change: Identifiable {
        var id: String { label }
        let label: String
        let old: String
        let new: String
    }

    struct Proposal: Identifiable {
        var id: UUID { before.id }
        let before: Book
        let after: Book

        var changes: [Change] {
            var list: [Change] = []
            if before.title != after.title {
                list.append(Change(label: "Title", old: before.title, new: after.title))
            }
            if before.authors != after.authors {
                list.append(Change(label: "Author", old: before.authors.joined(separator: " · "),
                                   new: after.authors.joined(separator: " · ")))
            }
            if before.seriesText != after.seriesText {
                list.append(Change(label: "Series", old: before.seriesText.isEmpty ? "None" : before.seriesText,
                                   new: after.seriesText))
            }
            return list
        }
    }

    /// Proposals for `targets`, using the whole `library` to recognise series and preferred spellings.
    static func proposals(for targets: Set<UUID>, in library: [Book]) -> [Proposal] {
        // Pass 1: clean each book on its own.
        var cleaned = library.map { book -> Book in
            var book = book
            book.authors = cleanAuthors(book.authors)
            if let found = seriesInParentheses(book.title) {
                book.title = found.title
                if book.series?.isEmpty != false {
                    book.series = found.series
                    book.seriesIndex = found.index
                }
            }
            return book
        }

        // Pass 2: numbered titles ("Defiance of the Fall 3: …") are a series when the library has the
        // series already or at least two books share the name.
        var known = Set(cleaned.compactMap { $0.series }.filter { !$0.isEmpty }.map(seriesKey))
        var prefixCounts: [String: Int] = [:]
        for book in cleaned {
            if let numbered = numberedTitle(book.title) { prefixCounts[seriesKey(numbered.series), default: 0] += 1 }
        }
        known.formUnion(prefixCounts.filter { $0.value >= 2 }.keys)
        for index in cleaned.indices where cleaned[index].series?.isEmpty != false {
            let title = cleaned[index].title
            if let numbered = numberedTitle(title), known.contains(seriesKey(numbered.series)) {
                cleaned[index].series = numbered.series
                cleaned[index].seriesIndex = numbered.index
            } else {
                // The first book often carries the bare series name: "Defiance of the Fall: A LitRPG Adventure".
                let main = mainTitle(title)
                if (prefixCounts[seriesKey(main)] ?? 0) >= 2 {
                    cleaned[index].series = main
                    cleaned[index].seriesIndex = 1
                } else if let colon = title.firstIndex(of: ":") {
                    // The series as a subtitle, with no number: "Control: Welcome to the Multiverse".
                    let subtitle = title[title.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if known.contains(seriesKey(subtitle)), !main.isEmpty {
                        cleaned[index].series = subtitle
                        cleaned[index].title = main
                    }
                }
            }
        }

        // Pass 3: drop marketing subtitles, then settle on one spelling per series and per author.
        for index in cleaned.indices {
            cleaned[index].title = stripMarketingSubtitle(cleaned[index].title)
        }
        let seriesNames = preferredSpellings(
            current: library.compactMap { $0.series }.filter { !$0.isEmpty },
            proposed: cleaned.compactMap { $0.series }.filter { !$0.isEmpty }, key: seriesKey)
        let authorNames = preferredSpellings(current: [], proposed: cleaned.flatMap(\.authors), key: nameKey)
        for index in cleaned.indices {
            if let series = cleaned[index].series, let preferred = seriesNames[seriesKey(series)] {
                cleaned[index].series = preferred
            }
            var seen = Set<String>()
            cleaned[index].authors = cleaned[index].authors
                .map { authorNames[nameKey($0)] ?? $0 }
                .filter { seen.insert(nameKey($0)).inserted }
        }

        return zip(library, cleaned)
            .filter { targets.contains($0.0.id) && $0.0 != $0.1 }
            .map { Proposal(before: $0.0, after: $0.1) }
            .filter { !$0.changes.isEmpty }
    }

    // MARK: Authors

    private static let particles: Set<String> = ["le", "la", "de", "del", "della", "di", "da", "du", "van", "von",
                                                 "der", "den", "st", "st.", "mc", "mac", "al", "el", "bin", "ibn", "o"]

    private static func isCredential(_ text: String) -> Bool {
        let bare = text.lowercased().filter { $0.isLetter }
        return ["phd", "md", "ms", "rd", "rdn", "ma", "mba", "msc", "bsc", "do", "dds", "esq", "cedrd", "cedrds", "fand"]
            .contains(bare)
    }

    /// Some files carry the site they came from as an extra "author".
    private static func isWebAddress(_ text: String) -> Bool {
        text.range(of: #"^\S+\.(com|net|org|io|co|info|me|cc|ru|xyz)$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "Jon Barwise and John Etchemendy" is two people; "Simon and Schuster" is left alone.
    private static func splitConjunction(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for separator in [" and ", " & "] {
            let sides = trimmed.components(separatedBy: separator).map { $0.trimmingCharacters(in: .whitespaces) }
            if sides.count == 2, sides.allSatisfy({ $0.split(separator: " ").count >= 2 }) { return sides }
        }
        return [trimmed]
    }

    private static func isSuffix(_ text: String) -> Bool {
        ["jr", "sr", "ii", "iii", "iv"].contains(text.lowercased().filter { $0.isLetter })
    }

    private static func looksLikeSurname(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        return words.count == 1 || particles.contains(words[0].lowercased())
    }

    /// "Wong, Tao" → "Tao Wong"; "Graham; Zweig" → two authors; "Robert Cialdini, PhD" → "Robert Cialdini".
    static func cleanAuthors(_ authors: [String]) -> [String] {
        var result: [String] = []
        for raw in authors {
            // Drop bracketed repeats such as "Clear, James [Clear, James]".
            let unbracketed = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ",
                                                       options: .regularExpression)
            for piece in unbracketed.split(separator: ";") {
                var parts: [String] = []
                for part in piece.split(separator: ",").flatMap({ splitConjunction(String($0)) })
                where !part.isEmpty && !isCredential(part) && !isWebAddress(part) {
                    if isSuffix(part), let last = parts.popLast() {
                        parts.append("\(last) \(part)")
                    } else {
                        parts.append(part)
                    }
                }
                if parts.count == 2, looksLikeSurname(parts[0]) {
                    result.append("\(parts[1]) \(parts[0])")
                } else if parts.count >= 4, parts.count.isMultiple(of: 2),
                          parts.allSatisfy({ !$0.contains(" ") }) {
                    // "Voss, Chris, Raz, Tahl": surname and first name pairs.
                    for pair in stride(from: 0, to: parts.count, by: 2) {
                        result.append("\(parts[pair + 1]) \(parts[pair])")
                    }
                } else {
                    result.append(contentsOf: parts)
                }
            }
        }
        var seen = Set<String>()
        let unique = result.filter { seen.insert(nameKey($0)).inserted }
        return unique.isEmpty ? authors : unique
    }

    static func nameKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Series

    static func seriesKey(_ name: String) -> String {
        var key = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key.filter { $0.isLetter || $0.isNumber }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// "Rebel Star (System Apocalypse Book 8)" or "Unsouled (Cradle, #1)".
    static func seriesInParentheses(_ title: String) -> (title: String, series: String, index: Double)? {
        guard let groups = firstMatch(#"^(.+?)\s*\((.+?),?\s+(?:book\s+#?|#|vol\.?\s*|volume\s+)(\d+(?:\.\d+)?)\)\s*$"#,
                                      in: title),
              let index = Double(groups[3]) else { return nil }
        let series = groups[2].trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        guard !series.isEmpty else { return nil }
        return (groups[1].trimmingCharacters(in: .whitespaces), series, index)
    }

    /// "Defiance of the Fall 3: A LitRPG Adventure" or "Shadow Slave Volume 9: Throne of War".
    static func numberedTitle(_ title: String) -> (series: String, index: Double)? {
        guard let groups = firstMatch(#"^(.+?)[\s,]+(?:(?:book|vol\.?|volume)\s+)?#?(\d{1,3})(?:\s*:.*)?$"#, in: title),
              let index = Double(groups[2]) else { return nil }
        let series = groups[1].trimmingCharacters(in: CharacterSet(charactersIn: " ,:-"))
        // A bare number after one short word is usually just a title ("Fahrenheit 451" is caught by the
        // two-book rule; this guards against leading numbers such as "1954 Ray Bradbury").
        guard !series.isEmpty, series.contains(where: \.isLetter) else { return nil }
        return (series, index)
    }

    private static func mainTitle(_ title: String) -> String {
        var main = title
        if let colon = main.firstIndex(of: ":") { main = String(main[..<colon]) }
        return main.trimmingCharacters(in: .whitespaces)
    }

    /// "Project Hail Mary: A Novel" → "Project Hail Mary". Real subtitles are left alone.
    static func stripMarketingSubtitle(_ title: String) -> String {
        let pattern = #"^(.+?)\s*:\s*(?:an?|the)\s+[^:]*\b(?:litrpg|gamelit|novel|space opera|progression fantasy|cultivation)\b[^:]*$"#
        guard let groups = firstMatch(pattern, in: title) else { return title }
        return groups[1].trimmingCharacters(in: .whitespaces)
    }

    /// For each key, the spelling to use: one already used in the library if there is one, otherwise the
    /// most common proposed spelling.
    private static func preferredSpellings(current: [String], proposed: [String],
                                           key: (String) -> String) -> [String: String] {
        func mostCommon(_ names: [String]) -> [String: String] {
            var counts: [String: [String: Int]] = [:]
            for name in names { counts[key(name), default: [:]][name, default: 0] += 1 }
            return counts.mapValues { spellings in
                spellings.max { ($0.value, $0.key.count, $1.key) < ($1.value, $1.key.count, $0.key) }!.key
            }
        }
        return mostCommon(proposed).merging(mostCommon(current)) { _, existing in existing }
    }
}
