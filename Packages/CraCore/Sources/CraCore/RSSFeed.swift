import Foundation

/// A parsed RSS 2.0, RSS 1.0/RDF, or Atom feed and helpers for HTML feed auto-discovery
/// and conditional HTTP caching (`ETag` / `Last-Modified`).
public struct RSSFeed: Equatable, Sendable {
    public var title: String?
    public var siteURL: String?
    public var items: [RSSFeedItem]

    public init(title: String? = nil, siteURL: String? = nil, items: [RSSFeedItem] = []) {
        self.title = title
        self.siteURL = siteURL
        self.items = items
    }

    public static func normalizeAddress(_ input: String) -> String? {
        LiveFolderPluginConfiguration.normalizedAddress(input, allowQuery: true)
    }

    /// Builds `If-None-Match` and `If-Modified-Since` request headers from stored validators.
    public static func conditionalHeaders(etag: String?, lastModified: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if let etag = etag?.trimmingCharacters(in: .whitespacesAndNewlines), !etag.isEmpty {
            headers["If-None-Match"] = etag
        }
        if let lastModified = lastModified?.trimmingCharacters(in: .whitespacesAndNewlines), !lastModified.isEmpty {
            headers["If-Modified-Since"] = lastModified
        }
        return headers
    }

    /// Extracts `ETag` and `Last-Modified` case-insensitively from HTTP response headers.
    public static func cacheValidators(from headers: [String: String]) -> (etag: String?, lastModified: String?) {
        var etag: String?
        var lastModified: String?
        for (key, value) in headers {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            switch key.lowercased() {
            case "etag": etag = normalized
            case "last-modified": lastModified = normalized
            default: break
            }
        }
        return (etag, lastModified)
    }

    public static func parse(_ xml: String, baseURL: URL? = nil, limit: Int = 100) -> RSSFeed? {
        guard let data = xml.data(using: .utf8) else { return nil }
        return parse(data, baseURL: baseURL, limit: limit)
    }

    public static func parse(_ data: Data, baseURL: URL? = nil, limit: Int = 100) -> RSSFeed? {
        guard !data.isEmpty, limit > 0 else { return nil }
        let delegate = FeedXMLDelegate(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.recognizedFeed else { return nil }

        var seen = Set<String>()
        var unique: [RSSFeedItem] = []
        for item in delegate.items {
            let key = item.url.lowercased()
            if seen.insert(key).inserted {
                unique.append(item)
            }
        }
        let indexed = unique.enumerated().sorted { left, right in
            switch (left.element.publishedAt, right.element.publishedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return left.offset < right.offset
            }
        }
        return RSSFeed(
            title: delegate.feedTitle,
            siteURL: delegate.siteURL,
            items: Array(indexed.map(\.element).prefix(limit))
        )
    }

    /// Discovers RSS and Atom feed links declared via `<link rel="alternate" ...>` in HTML.
    public static func discoverFeedURLs(in html: String, baseURL: URL) -> [RSSDiscoveredFeed] {
        let stripped = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b([^>]*)>", options: [.caseInsensitive]) else {
            return []
        }
        let nsHTML = stripped as NSString
        let matches = linkRegex.matches(in: stripped, range: NSRange(location: 0, length: nsHTML.length))

        var primary: [RSSDiscoveredFeed] = []
        var secondary: [RSSDiscoveredFeed] = []
        var seen = Set<String>()

        for match in matches {
            let rawAttrs = nsHTML.substring(with: match.range(at: 1))
            let attrs = parseHTMLAttributes(rawAttrs)
            guard let rel = attrs["rel"]?.lowercased().split(whereSeparator: \.isWhitespace).map(String.init),
                  rel.contains("alternate"),
                  let rawHref = attrs["href"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawHref.isEmpty else { continue }

            let mediaType = (attrs["type"] ?? "")
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            let title = attrs["title"].map { cleanText($0) }.flatMap { $0.isEmpty ? nil : $0 }

            let kind: RSSDiscoveredFeed.Kind
            let isPrimary: Bool
            switch mediaType {
            case "application/rss+xml":
                kind = .rss
                isPrimary = true
            case "application/atom+xml":
                kind = .atom
                isPrimary = true
            case "application/xml", "text/xml", "application/rdf+xml":
                let hint = "\(rawHref) \(title ?? "")".lowercased()
                guard hint.contains("rss") || hint.contains("atom") || hint.contains("feed") else { continue }
                kind = .xml
                isPrimary = false
            default:
                continue
            }

            guard let resolved = resolveHTTPURL(rawHref, relativeTo: baseURL),
                  seen.insert(resolved.lowercased()).inserted else { continue }
            let entry = RSSDiscoveredFeed(url: resolved, title: title, kind: kind)
            if isPrimary { primary.append(entry) } else { secondary.append(entry) }
        }
        return primary + secondary
    }

    static func parseFeedDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = parseISO8601(trimmed) { return date }
        return parseRFC822(trimmed)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(
            of: "([+-]\\d{2})(\\d{2})$",
            with: "$1:$2",
            options: .regularExpression
        )
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: normalized) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: normalized)
    }

    private static func parseRFC822(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm Z",
            "EEE, dd MMM yy HH:mm:ss Z",
            "dd MMM yy HH:mm:ss Z",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    fileprivate static func resolveHTTPURL(_ raw: String, relativeTo baseURL: URL?) -> String? {
        let trimmed = decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return nil
        }
        return resolved.absoluteString
    }

    fileprivate static func cleanText(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    fileprivate static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = [
            "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
            "rdquo": "”", "ldquo": "“", "hellip": "…"
        ]
        var result = text
        if let namedRegex = try? NSRegularExpression(pattern: "&(lt|gt|quot|apos|nbsp|mdash|ndash|rsquo|lsquo|rdquo|ldquo|hellip);") {
            let ns = result as NSString
            let matches = namedRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let key = ns.substring(with: match.range(at: 1))
                if let replacement = named[key] {
                    result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
                }
            }
        }
        if let numericRegex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            let matches = numericRegex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let isHex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10),
                   !(0xD800...0xDFFF).contains(code),
                   let scalar = UnicodeScalar(code) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func parseHTMLAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(
            pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        ) else { return result }
        let ns = raw as NSString
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let valueRange = [2, 3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }
            if let valueRange {
                result[name] = decodeEntities(ns.substring(with: valueRange))
            }
        }
        return result
    }
}

public struct RSSFeedItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var url: String
    public var title: String
    public var author: String?
    public var publishedAt: Date?

    public init(id: String, url: String, title: String, author: String? = nil, publishedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
    }
}

public struct RSSDiscoveredFeed: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case rss, atom, xml
    }

    public var url: String
    public var title: String?
    public var kind: Kind

    public init(url: String, title: String? = nil, kind: Kind) {
        self.url = url
        self.title = title
        self.kind = kind
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    private enum Format { case rss, atom }
    private struct DraftItem {
        var title = ""
        var link = ""
        var fallbackLink = ""
        var guid = ""
        var author = ""
        var date = ""
    }

    private let baseURL: URL?
    private(set) var recognizedFeed = false
    private(set) var feedTitle: String?
    private(set) var siteURL: String?
    private(set) var items: [RSSFeedItem] = []

    private var format: Format?
    private var stack: [String] = []
    private var textBuffer = ""
    private var inChannel = false
    private var inItem = false
    private var inAuthor = false
    private var draft = DraftItem()
    private var channelTitleBuffer = ""
    private var channelLinkBuffer = ""

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        stack.append(name)
        textBuffer = ""

        if stack.count == 1 {
            if name == "rss" || name == "rdf" {
                format = .rss
                recognizedFeed = true
            } else if name == "feed" {
                format = .atom
                recognizedFeed = true
            }
            return
        }

        switch format {
        case .rss:
            if name == "channel" { inChannel = true }
            if name == "item", inChannel || stack.dropLast().last == "rdf" {
                inItem = true
                draft = DraftItem()
            }
        case .atom:
            if name == "entry", stack.count == 2 {
                inItem = true
                draft = DraftItem()
            } else if name == "author", inItem {
                inAuthor = true
            } else if name == "link", let href = attributeDict["href"] {
                let rel = (attributeDict["rel"] ?? "alternate").lowercased()
                if inItem {
                    if rel == "alternate" && draft.link.isEmpty {
                        draft.link = href
                    } else if rel != "enclosure" && rel != "self" && draft.fallbackLink.isEmpty {
                        draft.fallbackLink = href
                    }
                } else if stack.count == 2 {
                    if rel == "alternate" && siteURL == nil {
                        siteURL = RSSFeed.resolveHTTPURL(href, relativeTo: baseURL)
                    }
                }
            }
        case .none:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let str = String(data: CDATABlock, encoding: .utf8) {
            textBuffer += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let fullName = elementName.lowercased()
        let text = textBuffer
        textBuffer = ""

        switch format {
        case .rss:
            if inItem {
                switch fullName {
                case "title":
                    if draft.title.isEmpty { draft.title = text }
                case "link":
                    if draft.link.isEmpty { draft.link = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                case "guid":
                    if draft.guid.isEmpty { draft.guid = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                case "pubdate", "dc:date":
                    if draft.date.isEmpty { draft.date = text }
                case "dc:creator", "author":
                    if draft.author.isEmpty { draft.author = text }
                default:
                    break
                }
                if name == "item" {
                    finalizeItem()
                    inItem = false
                }
            } else if inChannel && stack.count == 3 {
                if name == "title", feedTitle == nil {
                    channelTitleBuffer = RSSFeed.cleanText(text)
                    if !channelTitleBuffer.isEmpty { feedTitle = channelTitleBuffer }
                } else if name == "link", siteURL == nil {
                    channelLinkBuffer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    siteURL = RSSFeed.resolveHTTPURL(channelLinkBuffer, relativeTo: baseURL)
                }
            }
            if name == "channel" { inChannel = false }

        case .atom:
            if inItem {
                if inAuthor && name == "name" {
                    if draft.author.isEmpty { draft.author = text }
                } else if name == "author" {
                    inAuthor = false
                } else if !inAuthor && stack.count == 3 {
                    switch name {
                    case "title":
                        if draft.title.isEmpty { draft.title = text }
                    case "id":
                        if draft.guid.isEmpty { draft.guid = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    case "published":
                        draft.date = text
                    case "updated":
                        if draft.date.isEmpty { draft.date = text }
                    default:
                        break
                    }
                }
                if name == "entry" && stack.count == 2 {
                    finalizeItem()
                    inItem = false
                }
            } else if stack.count == 2 && name == "title", feedTitle == nil {
                let cleaned = RSSFeed.cleanText(text)
                if !cleaned.isEmpty { feedTitle = cleaned }
            }

        case .none:
            break
        }
        if !stack.isEmpty { stack.removeLast() }
    }

    private func finalizeItem() {
        let candidateLink = !draft.link.isEmpty ? draft.link : (!draft.fallbackLink.isEmpty ? draft.fallbackLink : draft.guid)
        guard let resolvedURL = RSSFeed.resolveHTTPURL(candidateLink, relativeTo: baseURL) else { return }
        let cleanedTitle = RSSFeed.cleanText(draft.title)
        let title = cleanedTitle.isEmpty ? resolvedURL : cleanedTitle
        let cleanedAuthor = RSSFeed.cleanText(draft.author)
        let id = draft.guid.isEmpty ? resolvedURL : draft.guid
        items.append(RSSFeedItem(
            id: id,
            url: resolvedURL,
            title: title,
            author: cleanedAuthor.isEmpty ? nil : cleanedAuthor,
            publishedAt: RSSFeed.parseFeedDate(draft.date)
        ))
    }

    private func localName(_ elementName: String) -> String {
        let lower = elementName.lowercased()
        if let colon = lower.lastIndex(of: ":") {
            return String(lower[lower.index(after: colon)...])
        }
        return lower
    }
}
