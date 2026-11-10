import CoreText
import Foundation

/// The four styles an e-reader uses from a font family.
enum FontStyle: String, CaseIterable, Codable, Sendable {
    case regular, italic, bold, boldItalic

    /// The file-name ending Kobo expects, as in `Lora-BoldItalic.ttf`.
    var suffix: String {
        switch self {
        case .regular: "Regular"
        case .italic: "Italic"
        case .bold: "Bold"
        case .boldItalic: "BoldItalic"
        }
    }

    /// The key Google's catalogue uses for the style.
    var googleKey: String {
        switch self {
        case .regular: "400"
        case .italic: "400i"
        case .bold: "700"
        case .boldItalic: "700i"
        }
    }
}

/// A family in the Google Fonts catalogue. All of them are free and open source.
struct GoogleFont: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    let name: String
    /// Serif, Sans Serif, Display, Handwriting or Monospace.
    let category: String
    /// 1 is the most used.
    let popularity: Int
    /// Which of the four e-reader styles the family has.
    let styles: [FontStyle]
}

/// Reads the Google Fonts catalogue and downloads families. Only a font's name is ever sent.
enum GoogleFonts {
    static let catalogueURL = URL(string: "https://fonts.google.com/metadata/fonts")!

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Google Fonts couldn't be reached. Check your internet connection." }
    }

    static func parseCatalogue(_ data: Data) throws -> [GoogleFont] {
        // The response can start with an anti-JSON-hijacking prefix.
        var data = data
        if let text = String(data: data.prefix(5), encoding: .utf8), text.hasPrefix(")]}'") {
            data = data.dropFirst(5)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["familyMetadataList"] as? [[String: Any]] else { throw Unavailable() }
        return list.compactMap { entry in
            guard let name = entry["family"] as? String, let fonts = entry["fonts"] as? [String: Any],
                  // A family with no upright regular weight isn't usable as a reading font.
                  fonts["400"] != nil else { return nil }
            return GoogleFont(name: name, category: entry["category"] as? String ?? "",
                              popularity: entry["popularity"] as? Int ?? 9999,
                              styles: FontStyle.allCases.filter { fonts[$0.googleKey] != nil })
        }
        .sorted { $0.popularity < $1.popularity }
    }

    /// The catalogue, kept in `cache` for a week so browsing works offline and opens at once.
    static func catalogue(cache: URL) async throws -> [GoogleFont] {
        let file = cache.appending(path: "google-fonts.json")
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 7 * 24 * 3600, let data = try? Data(contentsOf: file),
           let fonts = try? JSONDecoder().decode([GoogleFont].self, from: data), !fonts.isEmpty {
            return fonts
        }
        do {
            var request = URLRequest(url: catalogueURL, timeoutInterval: 25)
            request.setValue("Nightstand", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unavailable() }
            let fonts = try parseCatalogue(data)
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fonts).write(to: file, options: .atomic)
            return fonts
        } catch {
            // An old copy is better than nothing.
            if let data = try? Data(contentsOf: file),
               let fonts = try? JSONDecoder().decode([GoogleFont].self, from: data) { return fonts }
            throw Unavailable()
        }
    }

    /// The stylesheet that lists a family's font files. Asked for without a browser's name, Google answers
    /// with plain TrueType files, which is what e-readers need.
    static func stylesheetURL(for font: GoogleFont, styles: [FontStyle]) -> URL {
        let wanted = styles.filter(font.styles.contains)
        let family = font.name.replacingOccurrences(of: " ", with: "+")
        var spec = ""
        if wanted.contains(where: { $0 == .italic || $0 == .boldItalic }) {
            // Pairs of italic flag and weight, which must be in ascending order.
            let pairs = wanted.map { style -> String in
                switch style {
                case .regular: "0,400"
                case .bold: "0,700"
                case .italic: "1,400"
                case .boldItalic: "1,700"
                }
            }.sorted()
            spec = ":ital,wght@" + pairs.joined(separator: ";")
        } else if wanted.contains(.bold) {
            spec = ":wght@400;700"
        }
        return URL(string: "https://fonts.googleapis.com/css2?family=\(family)\(spec)")!
    }

    /// The font file for each style named in a Google Fonts stylesheet.
    static func parseStylesheet(_ css: String) -> [FontStyle: URL] {
        var files: [FontStyle: URL] = [:]
        for block in css.components(separatedBy: "@font-face").dropFirst() {
            func value(_ pattern: String) -> String? {
                guard let range = block.range(of: pattern, options: .regularExpression) else { return nil }
                return String(block[range])
            }
            let italic = value(#"font-style:\s*italic"#) != nil
            let weight = value(#"font-weight:\s*\d+"#).flatMap { Int($0.filter(\.isNumber)) } ?? 400
            guard let source = value(#"url\([^)]+\)"#),
                  let url = URL(string: String(source.dropFirst(4).dropLast())),
                  url.scheme == "https", url.host == "fonts.gstatic.com" else { continue }
            let style: FontStyle = weight >= 600 ? (italic ? .boldItalic : .bold) : (italic ? .italic : .regular)
            // The latin file comes last when a family is split by script.
            files[style] = url
        }
        return files
    }

    /// A tiny file holding only the letters of the family's name, so a list can show each name in its own
    /// font. Kept in `cache`; a few kilobytes each.
    static func nameSample(_ font: GoogleFont, cache: URL) async throws -> Data {
        let file = cache.appending(path: FontLibrary.fileName(family: font.name, style: .regular, extension: "ttf"))
        if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
        var components = URLComponents(string: "https://fonts.googleapis.com/css2")!
        components.queryItems = [URLQueryItem(name: "family", value: font.name),
                                 URLQueryItem(name: "text", value: font.name)]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Nightstand", forHTTPHeaderField: "User-Agent")
        let (css, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let url = parseStylesheet(String(decoding: css, as: UTF8.self))[.regular] else { throw Unavailable() }
        let (data, fileResponse) = try await URLSession.shared.data(from: url)
        guard (fileResponse as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw Unavailable() }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Downloads the chosen styles into `folder`, named the way Kobo expects. Returns the files written.
    @discardableResult
    static func download(_ font: GoogleFont, styles: [FontStyle] = FontStyle.allCases, to folder: URL) async throws -> [URL] {
        var request = URLRequest(url: stylesheetURL(for: font, styles: styles), timeoutInterval: 25)
        // No browser name: a browser would be sent WOFF2, which e-readers can't use.
        request.setValue("Nightstand", forHTTPHeaderField: "User-Agent")
        let (css, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Unavailable() }
        let files = parseStylesheet(String(decoding: css, as: UTF8.self))
        guard files[.regular] != nil else { throw Unavailable() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        for style in FontStyle.allCases {
            guard let url = files[style] else { continue }
            let (data, fileResponse) = try await URLSession.shared.data(from: url)
            guard (fileResponse as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw Unavailable() }
            let destination = folder.appending(path: FontLibrary.fileName(family: font.name, style: style, extension: url.pathExtension))
            try data.write(to: destination, options: .atomic)
            written.append(destination)
        }
        return written
    }
}

/// A font family as files on disk: in the library's Fonts folder, or on an e-reader.
struct LocalFont: Identifiable, Hashable, Sendable {
    var id: String { name }
    /// The family name, as in the file names ("CrimsonText").
    let name: String
    var files: [URL]

    /// The file to preview with: the regular style, or whatever there is.
    var regular: URL? {
        files.first { $0.deletingPathExtension().lastPathComponent.hasSuffix("-Regular") } ?? files.first
    }

    var styleNames: [String] {
        files.map { $0.deletingPathExtension().lastPathComponent }
            .map { $0.contains("-") ? String($0.split(separator: "-").last ?? "") : "Regular" }
            .sorted()
    }

    /// "CrimsonText" → "Crimson Text", for showing.
    var displayName: String {
        name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
    }
}

/// Fonts kept in the library and installed on e-readers.
enum FontLibrary {
    static let extensions: Set<String> = ["ttf", "otf"]

    static func folder(in root: URL) -> URL { root.appending(path: "Fonts") }

    /// Where a Kobo looks for fonts added by the reader.
    static func deviceFolder(on root: URL) -> URL { root.appending(path: "fonts") }

    static func fileName(family: String, style: FontStyle, extension ext: String) -> String {
        let name = family.filter { !$0.isWhitespace }
        return "\(name)-\(style.suffix).\(ext.isEmpty ? "ttf" : ext.lowercased())"
    }

    /// The families in a folder, grouped by the part of the file name before the style.
    static func fonts(in folder: URL) -> [LocalFont] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
        let groups = Dictionary(grouping: files) { url -> String in
            let name = url.deletingPathExtension().lastPathComponent
            return name.contains("-") ? String(name[..<name.lastIndex(of: "-")!]) : name
        }
        return groups.map { LocalFont(name: $0.key, files: $0.value.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Copies a family's files into `folder`, replacing files of the same name.
    static func copy(_ font: LocalFont, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in font.files {
            let destination = folder.appending(path: file.lastPathComponent)
            try? fm.removeItem(at: destination)
            try fm.copyContents(of: file, to: destination)
        }
    }

    static func remove(_ font: LocalFont) {
        for file in font.files { try? FileManager.default.removeItem(at: file) }
    }

    /// A font to draw with straight from its file's bytes, without registering it with the system, so a
    /// partial sample can't be mistaken for the full font elsewhere in the app.
    static func font(from data: Data, size: CGFloat) -> CTFont? {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return nil }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Makes a font file usable for drawing in this app and returns the name to ask for it by.
    static func register(_ url: URL) -> String? {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }
}
