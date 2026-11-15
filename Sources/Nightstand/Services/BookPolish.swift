import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Tidying applied to the copy of a book that is sent or exported, like Calibre's "Polish books": typographic
/// punctuation, no empty paragraphs, smaller images and a table of contents when the book lacks one. The
/// library copy is never changed.
enum TextTidy {
    private static let skipped: Set<String> = ["script", "style", "pre", "code", "svg", "math", "kbd", "samp"]
    /// Elements that start a new line of text, where a quote always opens.
    private static let blocks: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote",
                                              "br", "td", "th", "dd", "dt", "section", "article", "figcaption"]

    /// Curly quotes, real dashes and ellipses in place of typewriter ones. `previous` is the character before
    /// this text in the document, so a quote at the start of a node still opens or closes correctly; it is
    /// updated to the last character written.
    static func smarten(_ text: String, after previous: inout Character?) -> String {
        guard text.contains(where: { "\"'-.".contains($0) }) else {
            if let last = text.last { previous = last }
            return text
        }
        let characters = Array(text)
        var out = ""
        var i = 0
        func opens(_ before: Character?) -> Bool {
            guard let before else { return true }
            return before.isWhitespace || "([{\u{2014}\u{2013}-\u{201C}\u{2018}/".contains(before)
        }
        while i < characters.count {
            let character = characters[i]
            let before = out.last ?? previous
            let after: Character? = i + 1 < characters.count ? characters[i + 1] : nil
            switch character {
            case "\"":
                out.append(opens(before) ? "\u{201C}" : "\u{201D}")
            case "'":
                // An opening single quote only before a word; otherwise it's an apostrophe or a closing quote.
                let wordFollows = after.map { $0.isLetter || $0.isNumber } ?? false
                out.append(opens(before) && wordFollows ? "\u{2018}" : "\u{2019}")
            case "-" where after == "-":
                var length = 1
                while i + length < characters.count, characters[i + length] == "-" { length += 1 }
                out.append("\u{2014}")
                i += length
                continue
            case "." where i + 2 < characters.count && characters[i + 1] == "." && characters[i + 2] == ".":
                out.append("\u{2026}")
                i += 3
                continue
            default:
                out.append(character)
            }
            i += 1
        }
        if let last = out.last { previous = last }
        return out
    }

    /// True for a paragraph with nothing in it but spaces or line breaks.
    static func isBlank(_ element: XMLElement) -> Bool {
        guard element.localName?.lowercased() == "p" else { return false }
        let text = (element.stringValue ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
        guard text.allSatisfy(\.isWhitespace) else { return false }
        // Pictures and other content count as something.
        func onlyBreaks(_ node: XMLElement) -> Bool {
            node.elementChildren.allSatisfy { child in
                let name = child.localName?.lowercased() ?? ""
                return (name == "br" || name == "span" || name == "b" || name == "i" || name == "em"
                        || name == "strong" || name == "a") && onlyBreaks(child)
            }
        }
        return onlyBreaks(element)
    }

    /// Applies the tidying to one chapter. Nil when nothing changed or the chapter can't be parsed.
    static func tidy(_ data: Data, smartPunctuation: Bool, removeBlankParagraphs: Bool) -> Data? {
        guard let source = String(data: data, encoding: .utf8),
              let doc = try? XMLDocument(xmlString: KepubConverter.replaceNamedEntities(source),
                                         options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]),
              let html = doc.rootElement(),
              let body = html.elementChildren.first(where: { $0.localName?.lowercased() == "body" })
        else { return nil }
        var changed = false
        var previous: Character?

        func walk(_ element: XMLElement) {
            if skipped.contains(element.localName?.lowercased() ?? "") { return }
            for node in element.children ?? [] {
                if let child = node as? XMLElement {
                    if removeBlankParagraphs, isBlank(child) {
                        child.detach()
                        changed = true
                        continue
                    }
                    if blocks.contains(child.localName?.lowercased() ?? "") { previous = nil }
                    walk(child)
                } else if smartPunctuation, node.kind == .text, let text = node.stringValue {
                    let smart = smarten(text, after: &previous)
                    if smart != text {
                        node.stringValue = smart
                        changed = true
                    }
                }
            }
        }
        walk(body)
        return changed ? doc.xmlData(options: [.nodePreserveWhitespace]) : nil
    }
}

extension ExtractedEPUB {
    private var manifestItems: [XMLElement] { package?.child("manifest")?.children(named: "item") ?? [] }

    private func url(of item: XMLElement) -> URL? {
        item.attr("href").map { root.appending(path: OPF.resolve($0, relativeTo: opfPath)) }
    }

    // MARK: Text

    func tidyText(smartPunctuation: Bool, removeBlankParagraphs: Bool) {
        for document in contentDocuments {
            guard let data = try? Data(contentsOf: document.url),
                  let tidied = TextTidy.tidy(data, smartPunctuation: smartPunctuation,
                                             removeBlankParagraphs: removeBlankParagraphs) else { continue }
            try? tidied.write(to: document.url)
        }
    }

    // MARK: Size

    /// Scales down images larger than an e-reader screen and recompresses them, keeping each one's name and
    /// type so nothing that points at it breaks. An image is only replaced when the new one is smaller.
    /// Returns the bytes saved.
    @discardableResult
    func shrinkImages(maxPixel: Int = 1600) -> Int {
        var saved = 0
        for item in manifestItems {
            let type = item.attr("media-type") ?? ""
            let utType: UTType? = switch type {
            case "image/jpeg": .jpeg
            case "image/png": .png
            default: nil
            }
            guard let utType, let url = url(of: item), let data = try? Data(contentsOf: url) else { continue }
            let pixels: Int = {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else { return 0 }
                return max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                           properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
            }()
            guard pixels > maxPixel || data.count > 300_000,
                  let smaller = ImageTools.encode(data, as: utType, maxPixel: min(maxPixel, max(pixels, 1)),
                                                  quality: 0.75),
                  smaller.count < data.count else { continue }
            try? smaller.write(to: url)
            saved += data.count - smaller.count
        }
        return saved
    }

    /// Takes out the publisher's embedded fonts and the rules that load them. Only used when the e-reader's
    /// own font is chosen, as then they're never shown.
    func removeFonts() {
        guard let manifest = package?.child("manifest") else { return }
        let fontExtensions = ["ttf", "otf", "woff", "woff2"]
        for item in manifestItems {
            let type = item.attr("media-type") ?? ""
            let ext = (item.attr("href") ?? "").split(separator: ".").last.map { $0.lowercased() } ?? ""
            guard type.contains("font") || fontExtensions.contains(ext) else { continue }
            if let url = url(of: item) { try? FileManager.default.removeItem(at: url) }
            item.detach()
        }
        _ = manifest
        for item in manifestItems where item.attr("media-type") == "text/css" {
            guard let url = url(of: item), let css = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let stripped = css.replacingOccurrences(of: #"@font-face\s*\{[^}]*\}"#, with: "",
                                                    options: [.regularExpression, .caseInsensitive])
            if stripped != css { try? stripped.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: Table of contents

    /// How many entries the book's own table of contents has, in its NCX or EPUB 3 navigation document.
    var contentsEntries: Int {
        var best = 0
        if let tocID = package?.child("spine")?.attr("toc"),
           let item = manifestItems.first(where: { $0.attr("id") == tocID }),
           let url = url(of: item), let text = try? String(contentsOf: url, encoding: .utf8) {
            best = text.components(separatedBy: "<navPoint").count - 1
        }
        if let nav = manifestItems.first(where: { ($0.attr("properties") ?? "").split(separator: " ").contains("nav") }),
           let url = url(of: nav), let text = try? String(contentsOf: url, encoding: .utf8) {
            best = max(best, text.components(separatedBy: "<a ").count - 1)
        }
        return best
    }

    /// The chapters in reading order, each with its first heading (or its title) as the name.
    func headings() -> [(title: String, href: String)] {
        let spine = package?.child("spine")?.children(named: "itemref").compactMap { $0.attr("idref") } ?? []
        let items = Dictionary(manifestItems.compactMap { item in item.attr("id").map { ($0, item) } },
                               uniquingKeysWith: { first, _ in first })
        var result: [(String, String)] = []
        for id in spine {
            guard let item = items[id], let href = item.attr("href"), let url = url(of: item),
                  let source = try? String(contentsOf: url, encoding: .utf8),
                  let doc = try? XMLDocument(xmlString: KepubConverter.replaceNamedEntities(source),
                                             options: [.nodeLoadExternalEntitiesNever]) else { continue }
            func clean(_ text: String?) -> String? {
                let flat = (text ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return flat.isEmpty || flat.count > 120 ? nil : flat
            }
            let heading = ["h1", "h2", "h3"].lazy.compactMap { name in
                (try? doc.nodes(forXPath: "//*[local-name()='\(name)']"))?.lazy.compactMap { clean($0.stringValue) }.first
            }.first
            if let title = heading { result.append((title, href)) }
        }
        return result
    }

    /// Builds a table of contents from the chapter headings when the book has none, or only one entry.
    /// Returns whether one was written.
    @discardableResult
    func repairContents(title: String) -> Bool {
        guard contentsEntries < 2, let manifest = package?.child("manifest"),
              let spine = package?.child("spine") else { return false }
        let entries = headings()
        guard entries.count >= 2 else { return false }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let itemName = (manifest.prefix?.isEmpty == false) ? "\(manifest.prefix!):item" : "item"
        func addItem(id: String, href: String, type: String, properties: String? = nil) {
            manifest.removeChildren { $0.attr("id") == id }
            let item = XMLElement(name: itemName)
            item.setAttr("id", id)
            item.setAttr("href", href)
            item.setAttr("media-type", type)
            if let properties { item.setAttr("properties", properties) }
            manifest.addChild(item)
        }

        let points = entries.enumerated().map { index, entry in
            "<navPoint id=\"np\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(escape(entry.title))</text></navLabel><content src=\"\(escape(entry.href))\"/></navPoint>"
        }.joined(separator: "\n")
        let ncx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
            <head><meta name="dtb:depth" content="1"/><meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>
            <docTitle><text>\(escape(title))</text></docTitle>
            <navMap>
            \(points)
            </navMap>
            </ncx>
            """
        guard (try? Data(ncx.utf8).write(to: opfDirectory.appending(path: "nightstand-toc.ncx"))) != nil else { return false }
        addItem(id: "nightstand-ncx", href: "nightstand-toc.ncx", type: "application/x-dtbncx+xml")
        spine.setAttr("toc", "nightstand-ncx")

        if isEPUB3 {
            let links = entries.map { "<li><a href=\"\(escape($0.href))\">\(escape($0.title))</a></li>" }
                .joined(separator: "\n")
            let nav = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <head><title>Contents</title></head>
                <body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>
                \(links)
                </ol></nav></body>
                </html>
                """
            if (try? Data(nav.utf8).write(to: opfDirectory.appending(path: "nightstand-nav.xhtml"))) != nil {
                for item in manifestItems {
                    guard let properties = item.attr("properties") else { continue }
                    let kept = properties.split(separator: " ").filter { $0 != "nav" }.joined(separator: " ")
                    if kept.isEmpty { item.removeAttribute(forName: "properties") } else { item.setAttr("properties", kept) }
                }
                addItem(id: "nightstand-nav", href: "nightstand-nav.xhtml", type: "application/xhtml+xml",
                        properties: "nav")
            }
        }
        return true
    }
}
