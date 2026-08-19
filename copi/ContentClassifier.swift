import Foundation
import JavaScriptCore
import SQLite3

// MARK: - Tuning

/// Measured against real samples: prose peaks around 0.03, source code starts
/// around 0.08.
private let codeSymbolDensityThreshold = 0.05

/// Density alone makes a single colon enough in a very short line, so some
/// absolute evidence is required too.
private let codeMinSymbolCount = 4

// MARK: - highlight.js

/// Names the language of a snippet. highlight.js costs 11-65 ms per call
/// depending on length, so it is deliberately kept out of classification and
/// used only for the one item on screen in the preview panel.
///
/// Bundled as a resource, so improving it means dropping in a newer JavaScript
/// file rather than editing keyword lists.
final class CodeDetector {
    static let shared = CodeDetector()

    /// Detection quality plateaus well before this, and cost grows with length.
    private let inspectionLimit = 2000

    private let lock = NSLock()
    private var hljs: JSValue?
    private var didLoad = false
    private var cache: [UUID: String?] = [:]

    private func engine() -> JSValue? {
        if didLoad { return hljs }
        didLoad = true
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(source)
        hljs = context.objectForKeyedSubscript("hljs")
        return hljs
    }

    /// Parsing the bundled JavaScript costs about 76 ms, so it happens off the
    /// main thread before the first preview needs it.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            self.lock.lock()
            _ = self.engine()
            self.lock.unlock()
        }
    }

    func language(for id: UUID, text: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let value = detectLocked(String(text.prefix(inspectionLimit)))
        cache[id] = value
        return value
    }

    private func detectLocked(_ text: String) -> String? {
        guard let hljs = engine(),
              let result = hljs.invokeMethod("highlightAuto", withArguments: [text]),
              !result.isUndefined, !result.isNull,
              let language = result.objectForKeyedSubscript("language")?.toString(),
              !language.isEmpty, language != "undefined" else { return nil }
        return language
    }

    /// highlight.js reports identifiers, not display names.
    static func displayName(for language: String) -> String {
        switch language {
        case "javascript": "JavaScript"
        case "typescript": "TypeScript"
        case "csharp": "C#"
        case "cpp": "C++"
        case "objectivec": "Objective-C"
        case "php": "PHP"
        case "css", "scss", "json", "xml", "yaml", "sql", "ini": language.uppercased()
        default: language.capitalized
        }
    }
}

// MARK: - SQL

/// SQLite ships with macOS, so SQL is verified with a real parser instead of
/// keyword counting.
private final class SQLParser {
    static let shared = SQLParser()

    private let lock = NSLock()
    private var db: OpaquePointer?

    private init() {
        sqlite3_open(":memory:", &db)
    }

    /// True when the grammar matched. An empty database reports missing tables
    /// and columns, which means the statement itself parsed cleanly.
    ///
    /// History stores a truncated preview, so a statement cut mid-expression
    /// reports "incomplete input": every token so far was valid SQL. Prose cut
    /// at the same point reports a syntax error instead.
    func parses(_ text: String, allowingIncompleteInput: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, text, -1, &statement, nil)
        sqlite3_finalize(statement)
        if code == SQLITE_OK { return true }
        guard let raw = sqlite3_errmsg(db) else { return false }
        let message = String(cString: raw)
        if allowingIncompleteInput, message == "incomplete input" { return true }
        return Self.namingErrors.contains { message.hasPrefix($0) }
    }

    /// Errors raised after a successful parse, when names are resolved against
    /// the empty schema.
    private static let namingErrors = [
        "no such", "ambiguous column", "too many", "table ", "unknown database"
    ]
}

/// A stored preview is cut at a fixed character count, usually mid-word, which
/// the parser reports as a syntax error rather than an unfinished statement.
private func droppingPartialLastLine(_ text: String) -> String {
    guard let lastNewline = text.lastIndex(of: "\n") else { return text }
    return String(text[..<lastNewline])
}

/// SQLite covers standard SQL but rejects other dialects outright, so the few
/// constructs that differ are rewritten before parsing.
private func normalizedForSQLite(_ text: String) -> String {
    var sql = text
    // T-SQL and Oracle object redefinition
    sql = sql.replacingOccurrences(
        of: #"(?i)\bCREATE\s+OR\s+(ALTER|REPLACE)\b"#, with: "CREATE", options: .regularExpression)
    // T-SQL row limiting: SELECT TOP 10 / TOP (1) / TOP 50 PERCENT
    sql = sql.replacingOccurrences(
        of: #"(?i)\bTOP\s*\(?\s*\d+\s*\)?(\s+PERCENT)?"#, with: "", options: .regularExpression)
    // T-SQL bracket-quoted identifiers
    sql = sql.replacingOccurrences(
        of: #"\[([^\[\]]+)\]"#, with: "\"$1\"", options: .regularExpression)
    // T-SQL unicode string literals
    sql = sql.replacingOccurrences(
        of: #"(?i)\bN'"#, with: "'", options: .regularExpression)
    // ISNULL collides with SQLite's postfix operator of the same name.
    sql = sql.replacingOccurrences(
        of: #"(?i)\bISNULL\s*\("#, with: "IFNULL(", options: .regularExpression)
    return sql
}

private let sqlStatementPattern =
    #"^[ \t]*(select|insert|update|delete|with|create|alter|drop|truncate|merge|explain|declare|exec|execute|begin|call|grant|revoke|use|set)\b"#

/// Queries are usually pasted under a title or a `--` comment banner, and a file
/// may hold several statements, so every statement opening in the first half of
/// the text is offered as a parse candidate. A statement starting past the
/// halfway mark means the text is mostly something else that mentions a query.
private func sqlStatementCandidates(in text: String) -> [String] {
    let halfway = text.count / 2
    var offset = 0
    var candidates: [String] = []
    for line in text.components(separatedBy: .newlines) {
        if offset > halfway || candidates.count >= 5 { break }
        if line.range(
            of: sqlStatementPattern, options: [.regularExpression, .caseInsensitive]
        ) != nil {
            candidates.append(String(text.dropFirst(offset)))
        }
        offset += line.count + 1
    }
    return candidates
}

/// T-SQL procedural scripts build queries with variables and dynamic SQL, which
/// SQLite cannot parse at all. The syntax is unambiguous though: prose never
/// contains `DECLARE @name` or `SET @name =`.
private let tsqlProceduralPattern =
    #"(?i)\b(declare\s+@\w+|set\s+@\w+\s*=|exec(ute)?\s+[@\w\[]|begin\s+(try|transaction)\b)"#

private func looksLikeTSQLScript(_ text: String) -> Bool {
    text.range(of: tsqlProceduralPattern, options: .regularExpression) != nil
}

/// SQLite has no PROCEDURE, FUNCTION or SCHEMA, rejects NONCLUSTERED and #temp
/// tables, and will not qualify an index target, so DDL is recognised by shape
/// instead. A verb followed by an object type is unambiguous: "CREATE TABLE" is
/// SQL where "Create a summary" is not.
private let sqlDDLPattern =
    #"^[ \t]*(create|alter|drop|truncate)\s+(or\s+(alter|replace)\s+)?"#
    + #"((unique|clustered|nonclustered|columnstore|temporary|temp|global|materialized|external)\s+)*"#
    + #"(table|view|index|procedure|proc|function|schema|trigger|sequence|database|type|synonym)\b"#

private func isSQLDataDefinition(_ text: String) -> Bool {
    text.range(of: sqlDDLPattern, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - Structure

private let codeSymbols: Set<Character> = Set(#"{}[]()<>;=+*/%&|^~\:#$"#)

/// Punctuation density separates code from prose far more reliably than
/// keywords, which are ordinary English words.
private func codeSymbolStats(_ text: String) -> (count: Int, density: Double) {
    guard !text.isEmpty else { return (0, 0) }
    let hits = text.reduce(into: 0) { total, character in
        if codeSymbols.contains(character) { total += 1 }
    }
    return (hits, Double(hits) / Double(text.count))
}

private func looksLikeJSON(_ text: String) -> Bool {
    guard let first = text.first, first == "{" || first == "[" else { return false }
    if let data = text.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data)) != nil {
        return true
    }
    // Stored previews are truncated mid-structure, so fall back to shape.
    return text.contains("\":") || text.contains("\" :")
}

private func looksLikeXML(_ text: String) -> Bool {
    if text.hasPrefix("<?xml") || text.hasPrefix("<!DOCTYPE") { return true }
    guard text.hasPrefix("<") else { return false }
    return text.contains("</") || text.contains("/>")
}

private func looksLikeMarkdown(_ text: String) -> Bool {
    // Bullets and bold alone are just a formatted email, so a structural marker
    // is required before the weaker hints count.
    let structural = [
        #"(?m)^#{1,6}\s"#,
        #"```"#,
        #"\[[^\]]+\]\([^)]+\)"#,
        #"(?m)^\|.+\|[ \t]*$"#
    ]
    let hints = [
        #"(?m)^\s*[-*+]\s"#,
        #"(?m)^\s*\d+\.\s"#,
        #"\*\*[^*\n]+\*\*"#,
        #"(?m)^>\s"#
    ]
    let matches: (String) -> Bool = { text.range(of: $0, options: .regularExpression) != nil }
    let structuralHits = structural.filter(matches).count
    guard structuralHits > 0 else { return false }
    return structuralHits + hints.filter(matches).count >= 2
}

private func looksLikeFilePath(_ text: String) -> Bool {
    // Every line has to be a path, so the first one decides whether it is worth
    // touching the file system at all.
    guard text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("file://") else {
        return false
    }
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard !lines.isEmpty, lines.count <= 20 else { return false }
    return lines.allSatisfy { line in
        if line.hasPrefix("file://") { return true }
        guard line.hasPrefix("/") || line.hasPrefix("~/") else { return false }
        return FileManager.default.fileExists(atPath: (line as NSString).expandingTildeInPath)
    }
}

/// NSDataDetector replaces hand-written address and URL regexes. Only a match
/// spanning the whole string counts, so prose containing a link stays prose.
private func wholeStringLink(in text: String) -> URL? {
    // A match covering the whole string rules out whitespace, and the detector
    // is costly on long text.
    guard !text.contains(where: \.isWhitespace) else { return nil }
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let matches = detector.matches(in: text, range: range)
    guard matches.count == 1, matches[0].range == range else { return nil }
    return matches[0].url
}

/// Avoids rebuilding the whole string just to test long text that cannot be a
/// number anyway.
private func numericValue(of text: String) -> Double? {
    guard text.count <= 40, let first = text.first,
          first.isNumber || first == "-" || first == "+" else { return nil }
    return Double(text.replacingOccurrences(of: ",", with: ""))
}

// MARK: - Classification

func classifyClipboardContent(
    text: String,
    isImage: Bool,
    isTruncated: Bool = false
) -> ContentKind {
    if isImage { return .image }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .text }

    if clipboardTableRows(in: trimmed) != nil { return .table }
    if looksLikeFilePath(trimmed) { return .file }
    if looksLikeJSON(trimmed) { return .json }
    if looksLikeXML(trimmed) { return .xml }

    if let url = wholeStringLink(in: trimmed) {
        return url.scheme == "mailto" ? .email : .link
    }
    if numericValue(of: trimmed) != nil {
        return .number
    }

    let candidates = sqlStatementCandidates(in: trimmed)
    if !candidates.isEmpty {
        if looksLikeTSQLScript(trimmed) { return .sql }
        for candidate in candidates {
            if isSQLDataDefinition(candidate) { return .sql }
            let body = isTruncated ? droppingPartialLastLine(candidate) : candidate
            if SQLParser.shared.parses(
                normalizedForSQLite(body), allowingIncompleteInput: isTruncated) {
                return .sql
            }
        }
    }

    if looksLikeMarkdown(trimmed) { return .markdown }

    let symbols = codeSymbolStats(trimmed)
    return symbols.count >= codeMinSymbolCount
        && symbols.density >= codeSymbolDensityThreshold ? .code : .text
}
