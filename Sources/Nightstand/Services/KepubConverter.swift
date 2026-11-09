import Foundation

/// Turns an EPUB chapter into a KEPUB chapter.
///
/// Kobo's KEPUB renderer needs every sentence wrapped in a `koboSpan` with a stable id (used for reading
/// position, highlights and statistics) and the body wrapped in two container divs.
enum KepubConverter {
    private static let skipped: Set<String> = ["script", "style", "pre", "audio", "video", "svg", "math"]
    private static let blocks: Set<String> = ["p", "ol", "ul", "table", "h1", "h2", "h3", "h4", "h5", "h6"]

    /// Returns the converted document, or nil when it is already converted or cannot be parsed as XHTML.
    static func convert(_ data: Data) -> Data? {
        guard let source = String(data: data, encoding: .utf8), !source.contains("koboSpan") else { return nil }
        guard let doc = try? XMLDocument(xmlString: replaceNamedEntities(source),
                                         options: [.nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]),
              let html = doc.rootElement(),
              let body = html.elementChildren.first(where: { $0.localName?.lowercased() == "body" })
        else { return nil }

        var paragraph = 0
        var segment = 0

        func walk(_ element: XMLElement) {
            let name = element.localName?.lowercased() ?? ""
            if skipped.contains(name) { return }
            if blocks.contains(name) {
                paragraph += 1
                segment = 0
            }
            for node in element.children ?? [] {
                if let child = node as? XMLElement {
                    walk(child)
                } else if node.kind == .text, let text = node.stringValue,
                          !text.allSatisfy(\.isWhitespace) {
                    if paragraph == 0 { paragraph = 1 }
                    var index = node.index
                    element.removeChild(at: index)
                    for sentence in sentences(in: text) {
                        segment += 1
                        let span = XMLElement(name: "span")
                        span.setAttr("class", "koboSpan")
                        span.setAttr("id", "kobo.\(paragraph).\(segment)")
                        span.addChild(XMLNode.text(withStringValue: sentence) as! XMLNode)
                        element.insertChild(span, at: index)
                        index += 1
                    }
                }
            }
        }
        walk(body)

        let content = body.children ?? []
        content.forEach { $0.detach() }
        let inner = XMLElement(name: "div")
        inner.setAttr("id", "book-inner")
        inner.setChildren(content)
        let columns = XMLElement(name: "div")
        columns.setAttr("id", "book-columns")
        columns.addChild(inner)
        body.addChild(columns)

        if let head = html.elementChildren.first(where: { $0.localName?.lowercased() == "head" }) {
            let style = XMLElement(name: "style", stringValue: "div#book-inner { margin-top: 0; margin-bottom: 0; }")
            style.setAttr("type", "text/css")
            style.setAttr("id", "kobo-style")
            head.addChild(style)
        }
        return doc.xmlData(options: [.nodePreserveWhitespace])
    }

    /// Splits text into sentences, keeping trailing whitespace with the sentence it follows.
    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        var current = ""
        var i = 0
        while i < characters.count {
            let character = characters[i]
            current.append(character)
            i += 1
            guard ".!?…:".contains(character) else { continue }
            while i < characters.count, "'\"”’“)]".contains(characters[i]) {
                current.append(characters[i])
                i += 1
            }
            guard i < characters.count, characters[i].isWhitespace else { continue }
            while i < characters.count, characters[i].isWhitespace {
                current.append(characters[i])
                i += 1
            }
            result.append(current)
            current = ""
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// XHTML allows HTML's named entities, but an XML parser without the DTD does not know them.
    static func replaceNamedEntities(_ source: String) -> String {
        guard source.contains("&") else { return source }
        let regex = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);")
        let result = NSMutableString(string: source)
        for match in regex.matches(in: source, range: NSRange(location: 0, length: result.length)).reversed() {
            let name = result.substring(with: match.range(at: 1))
            if let code = entities[name] {
                result.replaceCharacters(in: match.range, with: "&#\(code);")
            }
        }
        return result as String
    }

    private static let entities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165, "brvbar": 166,
        "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171, "not": 172, "shy": 173, "reg": 174,
        "macr": 175, "deg": 176, "plusmn": 177, "sup2": 178, "sup3": 179, "acute": 180, "micro": 181,
        "para": 182, "middot": 183, "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188,
        "frac12": 189, "frac34": 190, "iquest": 191, "Agrave": 192, "Aacute": 193, "Acirc": 194,
        "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199, "Egrave": 200, "Eacute": 201,
        "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205, "Icirc": 206, "Iuml": 207, "ETH": 208,
        "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214, "times": 215,
        "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "Yacute": 221, "THORN": 222,
        "szlig": 223, "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
        "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236,
        "iacute": 237, "icirc": 238, "iuml": 239, "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243,
        "ocirc": 244, "otilde": 245, "ouml": 246, "divide": 247, "oslash": 248, "ugrave": 249, "uacute": 250,
        "ucirc": 251, "uuml": 252, "yacute": 253, "thorn": 254, "yuml": 255, "OElig": 338, "oelig": 339,
        "Scaron": 352, "scaron": 353, "Yuml": 376, "circ": 710, "tilde": 732, "ensp": 8194, "emsp": 8195,
        "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212,
        "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
        "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
        "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "euro": 8364, "trade": 8482, "larr": 8592,
        "uarr": 8593, "rarr": 8594, "darr": 8595, "minus": 8722, "ne": 8800, "le": 8804, "ge": 8805,
    ]
}
