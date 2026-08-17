import Foundation
import AppKit
import Carbon.HIToolbox

private let maxRichPasteboardPayloadBytes = 512 * 1024
private let maxStoredHistoryRichPayloadBytes = 2 * 1024 * 1024
private let maxStoredTextPayloadBytes = 10 * 1024 * 1024
private let maxStoredHistoryTextPayloadBytes = 50 * 1024 * 1024
private let maxStoredImagePayloadBytes = 4 * 1024 * 1024
private let maxStoredHistoryImagePayloadBytes = 32 * 1024 * 1024
private let maxInMemoryTextPreviewCharacters = 512
private let maxCurrentPasteboardPreviewCharacters = 256
private let pasteboardPollInterval: TimeInterval = 0.25

private func payloadSignature(for data: Data) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in data {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return "\(data.count)-\(String(hash, radix: 16))"
}

/// Tab-separated grid parsed from plain text, or nil when the text isn't tabular.
/// Shared so the overlay's grid preview and the content classifier always agree.
func clipboardTableRows(in text: String) -> [[String]]? {
    guard text.contains("\t") else { return nil }
    let lines = text
        .components(separatedBy: .newlines)
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }

    let split = lines.map { $0.components(separatedBy: "\t") }
    let columnCount = split[0].count
    guard columnCount >= 2 else { return nil }
    // Stray tabs in prose produce ragged counts; a real table is consistent.
    let consistent = split.filter { $0.count == columnCount }.count
    guard consistent * 2 >= split.count else { return nil }
    return split
}

/// Coarse content class, derived rather than stored so history needs no migration.
enum ContentKind: String, CaseIterable {
    case image = "Image"
    case file = "File Path"
    case table = "Table"
    case json = "JSON"
    case xml = "XML"
    case markdown = "Markdown"
    case email = "Email"
    case link = "Link"
    case number = "Number"
    case code = "Code"
    case text = "Text"
}

private func clipboardLooksLikeJSON(_ text: String) -> Bool {
    guard let first = text.first, first == "{" || first == "[" else { return false }
    if let data = text.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data)) != nil {
        return true
    }
    // Stored previews are truncated mid-structure, so fall back to shape.
    return text.contains("\":") || text.contains("\" :")
}

private func clipboardLooksLikeXML(_ text: String) -> Bool {
    if text.hasPrefix("<?xml") || text.hasPrefix("<!DOCTYPE") { return true }
    guard text.hasPrefix("<") else { return false }
    return text.contains("</") || text.contains("/>")
}

private func clipboardLooksLikeMarkdown(_ text: String) -> Bool {
    var score = 0
    if text.range(of: #"(?m)^#{1,6}\s"#, options: .regularExpression) != nil { score += 2 }
    if text.contains("```") { score += 2 }
    if text.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil { score += 2 }
    if text.range(of: #"(?m)^\s*[-*+]\s"#, options: .regularExpression) != nil { score += 1 }
    if text.range(of: #"(?m)^\s*\d+\.\s"#, options: .regularExpression) != nil { score += 1 }
    if text.range(of: #"\*\*[^*\n]+\*\*"#, options: .regularExpression) != nil { score += 1 }
    if text.range(of: #"(?m)^>\s"#, options: .regularExpression) != nil { score += 1 }
    return score >= 2
}

private func clipboardLooksLikeEmail(_ text: String) -> Bool {
    guard !text.contains(" "), !text.contains("\n") else { return false }
    let candidate = text.hasPrefix("mailto:") ? String(text.dropFirst(7)) : text
    return candidate.range(
        of: #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#,
        options: [.regularExpression, .caseInsensitive]
    ) != nil
}

private func clipboardLooksLikeCode(_ text: String) -> Bool {
    var score = 0
    let keywords = [
        "func ", "def ", "class ", "import ", "return ", "const ", "var ", "let ",
        "public ", "private ", "if (", "for (", "while (", "=>", "#include", "package ",
        "SELECT ", "INSERT ", "struct ", "enum "
    ]
    score += keywords.filter { text.contains($0) }.count
    if text.contains("{") && text.contains("}") { score += 1 }
    if text.contains(";") { score += 1 }
    if text.range(of: #"(?m)^\s{2,}\S"#, options: .regularExpression) != nil { score += 1 }
    return score >= 2
}

private func clipboardLooksLikeFilePath(_ text: String) -> Bool {
    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    guard !lines.isEmpty, lines.count <= 20 else { return false }
    return lines.allSatisfy { line in
        if line.hasPrefix("file://") { return true }
        guard line.hasPrefix("/") || line.hasPrefix("~/") else { return false }
        return FileManager.default.fileExists(atPath: (line as NSString).expandingTildeInPath)
    }
}

func clipboardContentKind(text: String, isImage: Bool) -> ContentKind {
    if isImage { return .image }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .text }

    if clipboardTableRows(in: trimmed) != nil { return .table }
    if clipboardLooksLikeFilePath(trimmed) { return .file }
    if clipboardLooksLikeJSON(trimmed) { return .json }
    if clipboardLooksLikeXML(trimmed) { return .xml }
    if clipboardLooksLikeMarkdown(trimmed) { return .markdown }
    if clipboardLooksLikeEmail(trimmed) { return .email }
    if !trimmed.contains(" "), !trimmed.contains("\n"),
       let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
        return .link
    }
    if Double(trimmed.replacingOccurrences(of: ",", with: "")) != nil { return .number }
    if clipboardLooksLikeCode(trimmed) { return .code }
    return .text
}

/// Classification runs regexes, and the history list renders every item, so results
/// are memoised. Item text never changes for a given id.
private final class ContentKindCache {
    static let shared = ContentKindCache()
    private var storage: [UUID: ContentKind] = [:]

    func kind(for id: UUID, compute: () -> ContentKind) -> ContentKind {
        if let cached = storage[id] { return cached }
        let value = compute()
        if storage.count >= 512 { storage.removeAll(keepingCapacity: true) }
        storage[id] = value
        return value
    }
}

private func previewText(for text: String) -> String {
    String(text.prefix(maxInMemoryTextPreviewCharacters))
}

private enum HistoryPayloadStore {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Copi", isDirectory: true)
            .appendingPathComponent("History", isDirectory: true)
    }

    static func writeText(_ text: String, id: UUID) -> (fileName: String, byteCount: Int)? {
        guard let data = text.data(using: .utf8) else { return nil }
        let fileName = "\(id.uuidString)-text.txt"
        guard writeData(data, fileName: fileName) else { return nil }
        return (fileName, data.count)
    }

    static func readText(fileName: String) -> String? {
        guard let data = readData(fileName: fileName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeImageData(_ data: Data, id: UUID) -> (fileName: String, byteCount: Int)? {
        let fileName = "\(id.uuidString)-image.png"
        guard writeData(data, fileName: fileName) else { return nil }
        return (fileName, data.count)
    }

    static func writeRichData(_ richData: [String: Data], id: UUID) -> (fileNames: [String: String], byteCount: Int)? {
        var fileNames: [String: String] = [:]
        var totalBytes = 0

        for (index, key) in richData.keys.sorted().enumerated() {
            guard let data = richData[key] else { continue }
            let fileName = "\(id.uuidString)-rich-\(index).bin"
            guard writeData(data, fileName: fileName) else { continue }
            fileNames[key] = fileName
            totalBytes += data.count
        }

        return fileNames.isEmpty ? nil : (fileNames, totalBytes)
    }

    static func readData(fileName: String) -> Data? {
        guard let directory else { return nil }
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        return try? Data(contentsOf: directory.appendingPathComponent(safeFileName, isDirectory: false))
    }

    static func deleteAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func prune(keeping fileNames: Set<String>) {
        guard let directory,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return }

        for url in urls where !fileNames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func writeData(_ data: Data, fileName: String) -> Bool {
        guard let directory else { return false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
            try data.write(to: directory.appendingPathComponent(safeFileName, isDirectory: false), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Clipboard item model

struct ClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String       // display/search preview; full payload is file-backed
    let date: Date
    /// App that was frontmost when the copy was detected.
    let sourceAppName: String?
    let sourceBundleID: String?

    private let textFileName: String?
    private let textByteCount: Int
    private let imageFileName: String?
    private let storedImageByteCount: Int
    private let richFileNames: [String: String]?
    private let storedRichByteCount: Int
    private let contentSignature: String
    private let inlineImageData: Data?
    private let inlineRichData: [String: Data]?

    var isImage: Bool { imageFileName != nil || inlineImageData != nil }

    var contentKind: ContentKind {
        ContentKindCache.shared.kind(for: id) {
            clipboardContentKind(text: text, isImage: isImage)
        }
    }

    var fullText: String {
        guard !isImage else { return text }
        if let textFileName,
           let storedText = HistoryPayloadStore.readText(fileName: textFileName) {
            return storedText
        }
        return text
    }

    var imageData: Data? {
        if let inlineImageData { return inlineImageData }
        guard let imageFileName else { return nil }
        return HistoryPayloadStore.readData(fileName: imageFileName)
    }

    var richData: [String: Data]? {
        if let inlineRichData { return inlineRichData }
        guard let richFileNames else { return nil }

        var loaded: [String: Data] = [:]
        for (type, fileName) in richFileNames {
            guard let data = HistoryPayloadStore.readData(fileName: fileName) else { continue }
            loaded[type] = data
        }
        return loaded.isEmpty ? nil : loaded
    }

    var payloadID: String { contentSignature }

    /// NSImage from stored PNG data (cached globally to avoid repeated decode)
    var nsImage: NSImage? {
        guard let data = imageData else { return nil }
        if let cached = ClipboardItem.imageCache[id] { return cached }
        let img = NSImage(data: data)
        ClipboardItem.imageCache[id] = img
        return img
    }

    private static var imageCache: [UUID: NSImage] = [:]
    static func clearImageCache() { imageCache.removeAll() }
    static func pruneImageCache(keeping ids: Set<UUID>) {
        imageCache = imageCache.filter { ids.contains($0.key) }
    }

    var richDataByteCount: Int {
        if storedRichByteCount > 0 { return storedRichByteCount }
        return richData?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    var textPayloadByteCount: Int {
        isImage ? 0 : max(textByteCount, text.utf8.count)
    }

    var imageDataByteCount: Int {
        if storedImageByteCount > 0 { return storedImageByteCount }
        return imageData?.count ?? 0
    }

    var payloadFileNames: Set<String> {
        var fileNames = Set<String>()
        if let textFileName { fileNames.insert(textFileName) }
        if let imageFileName { fileNames.insert(imageFileName) }
        if let richFileNames { fileNames.formUnion(richFileNames.values) }
        return fileNames
    }

    func pruningOversizedRichData(maxBytes: Int) -> ClipboardItem {
        guard richDataByteCount > maxBytes else { return self }
        return strippingRichData()
    }

    func strippingRichData() -> ClipboardItem {
        return ClipboardItem(
            id: id,
            text: text,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            textFileName: textFileName,
            textByteCount: textByteCount,
            imageFileName: imageFileName,
            storedImageByteCount: storedImageByteCount,
            richFileNames: nil,
            storedRichByteCount: 0,
            contentSignature: contentSignature,
            inlineImageData: inlineImageData,
            inlineRichData: nil
        )
    }

    func storingPayloadsOnDisk() -> ClipboardItem {
        var displayText = text
        var storedTextFileName = textFileName
        var storedTextByteCount = textByteCount
        var storedImageFileName = imageFileName
        var imageByteCount = storedImageByteCount
        var storedRichFileNames = richFileNames
        var richByteCount = storedRichByteCount
        var signature = contentSignature

        if isImage {
            if storedImageFileName == nil,
               let inlineImageData,
               let stored = HistoryPayloadStore.writeImageData(inlineImageData, id: id) {
                storedImageFileName = stored.fileName
                imageByteCount = stored.byteCount
                signature = payloadSignature(for: inlineImageData)
            }
        } else if storedTextFileName == nil {
            let fullText = text
            if let stored = HistoryPayloadStore.writeText(fullText, id: id) {
                displayText = previewText(for: fullText)
                storedTextFileName = stored.fileName
                storedTextByteCount = stored.byteCount
                signature = payloadSignature(for: Data(fullText.utf8))
            }
        }

        if storedRichFileNames == nil,
           let inlineRichData,
           let stored = HistoryPayloadStore.writeRichData(inlineRichData, id: id) {
            storedRichFileNames = stored.fileNames
            richByteCount = stored.byteCount
        }

        return ClipboardItem(
            id: id,
            text: displayText,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            textFileName: storedTextFileName,
            textByteCount: storedTextByteCount,
            imageFileName: storedImageFileName,
            storedImageByteCount: imageByteCount,
            richFileNames: storedRichFileNames,
            storedRichByteCount: richByteCount,
            contentSignature: signature,
            inlineImageData: storedImageFileName == nil ? inlineImageData : nil,
            inlineRichData: storedRichFileNames == nil ? inlineRichData : nil
        )
    }

    private init(
        id: UUID,
        text: String,
        date: Date,
        sourceAppName: String?,
        sourceBundleID: String?,
        textFileName: String?,
        textByteCount: Int,
        imageFileName: String?,
        storedImageByteCount: Int,
        richFileNames: [String: String]?,
        storedRichByteCount: Int,
        contentSignature: String,
        inlineImageData: Data?,
        inlineRichData: [String: Data]?
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.textFileName = textFileName
        self.textByteCount = textByteCount
        self.imageFileName = imageFileName
        self.storedImageByteCount = storedImageByteCount
        self.richFileNames = richFileNames
        self.storedRichByteCount = storedRichByteCount
        self.contentSignature = contentSignature
        self.inlineImageData = inlineImageData
        self.inlineRichData = inlineRichData
    }

    init(text: String, richData: [String: Data]? = nil, sourceAppName: String? = nil, sourceBundleID: String? = nil) {
        let id = UUID()
        let textData = Data(text.utf8)
        let storedText = HistoryPayloadStore.writeText(text, id: id)
        let storedRich = richData.flatMap { HistoryPayloadStore.writeRichData($0, id: id) }

        self.init(
            id: id,
            text: storedText == nil ? text : previewText(for: text),
            date: Date(),
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            textFileName: storedText?.fileName,
            textByteCount: storedText?.byteCount ?? textData.count,
            imageFileName: nil,
            storedImageByteCount: 0,
            richFileNames: storedRich?.fileNames,
            storedRichByteCount: storedRich?.byteCount ?? 0,
            contentSignature: payloadSignature(for: textData),
            inlineImageData: nil,
            inlineRichData: storedRich == nil ? richData : nil
        )
    }

    init(image: NSImage, sourceAppName: String? = nil, sourceBundleID: String? = nil) {
        let id = UUID()
        let w = Int(image.size.width)
        let h = Int(image.size.height)
        let label = "[Image \(w)×\(h)]"

        var pngData: Data?
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            pngData = rep.representation(using: .png, properties: [:])
        }

        let storedImage = pngData.flatMap { HistoryPayloadStore.writeImageData($0, id: id) }
        self.init(
            id: id,
            text: label,
            date: Date(),
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            textFileName: nil,
            textByteCount: 0,
            imageFileName: storedImage?.fileName,
            storedImageByteCount: storedImage?.byteCount ?? pngData?.count ?? 0,
            richFileNames: nil,
            storedRichByteCount: 0,
            contentSignature: pngData.map(payloadSignature(for:)) ?? label,
            inlineImageData: storedImage == nil ? pngData : nil,
            inlineRichData: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case date
        case sourceAppName
        case sourceBundleID
        case textFileName
        case textByteCount
        case imageFileName
        case storedImageByteCount
        case richFileNames
        case storedRichByteCount
        case contentSignature
        case imageData
        case richData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let text = try container.decode(String.self, forKey: .text)
        let date = try container.decode(Date.self, forKey: .date)
        let sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        let sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        let textFileName = try container.decodeIfPresent(String.self, forKey: .textFileName)
        let textByteCount = try container.decodeIfPresent(Int.self, forKey: .textByteCount) ?? text.utf8.count
        let imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        let inlineImageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        let storedImageByteCount = try container.decodeIfPresent(Int.self, forKey: .storedImageByteCount) ?? inlineImageData?.count ?? 0
        let richFileNames = try container.decodeIfPresent([String: String].self, forKey: .richFileNames)
        let inlineRichData = try container.decodeIfPresent([String: Data].self, forKey: .richData)
        let storedRichByteCount = try container.decodeIfPresent(Int.self, forKey: .storedRichByteCount)
            ?? inlineRichData?.values.reduce(0) { $0 + $1.count }
            ?? 0
        let signature = try container.decodeIfPresent(String.self, forKey: .contentSignature)
            ?? inlineImageData.map(payloadSignature(for:))
            ?? payloadSignature(for: Data(text.utf8))

        self.init(
            id: id,
            text: text,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            textFileName: textFileName,
            textByteCount: textByteCount,
            imageFileName: imageFileName,
            storedImageByteCount: storedImageByteCount,
            richFileNames: richFileNames,
            storedRichByteCount: storedRichByteCount,
            contentSignature: signature,
            inlineImageData: inlineImageData,
            inlineRichData: inlineRichData
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try container.encodeIfPresent(textFileName, forKey: .textFileName)
        try container.encode(textByteCount, forKey: .textByteCount)
        try container.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try container.encode(storedImageByteCount, forKey: .storedImageByteCount)
        try container.encodeIfPresent(richFileNames, forKey: .richFileNames)
        try container.encode(storedRichByteCount, forKey: .storedRichByteCount)
        try container.encode(contentSignature, forKey: .contentSignature)
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.date == rhs.date
            && lhs.textFileName == rhs.textFileName
            && lhs.textByteCount == rhs.textByteCount
            && lhs.imageFileName == rhs.imageFileName
            && lhs.storedImageByteCount == rhs.storedImageByteCount
            && lhs.richFileNames == rhs.richFileNames
            && lhs.storedRichByteCount == rhs.storedRichByteCount
            && lhs.contentSignature == rhs.contentSignature
    }
}

// MARK: - Engine: polls pasteboard, manages history, handles global shortcut

@Observable
final class ClipboardEngine {
    static let shared = ClipboardEngine()

    private(set) var items: [ClipboardItem] = []
    private(set) var currentPasteboardPreview: String?
    var isOverlayVisible = false

    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount: Int = 0
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        loadHistory()
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        refreshCurrentPasteboardPreview()
        startPolling()
        installShortcutTap()
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        removeShortcutTap()
    }

    // MARK: - Pasteboard polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + pasteboardPollInterval,
            repeating: pasteboardPollInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.checkPasteboard()
        }
        timer.resume()
        pollTimer = timer
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let sourceApp = currentSourceAppName()
        let sourceBundle = currentSourceBundleID()

        // Check for image first (TIFF is the universal macOS image pasteboard type)
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        let hasImage = imageTypes.contains(where: { pb.data(forType: $0) != nil })
        let text = fileURLText(from: pb) ?? pb.string(forType: .string)
        let hasText = !(text ?? "").isEmpty

        updateCurrentPasteboardPreview(text: text, hasImage: hasImage)
        defer {
            notifyMenuBarPreviewChanged()
        }

        if hasImage, !hasText, let imgData = pb.data(forType: .tiff) ?? pb.data(forType: .png),
           let nsImage = NSImage(data: imgData) {
            // Image-only clipboard entry
            let item = ClipboardItem(image: nsImage, sourceAppName: sourceApp, sourceBundleID: sourceBundle)
            guard item.imageDataByteCount <= maxStoredImagePayloadBytes else { return }
            // Don't add if most recent is same dimensions image
            if let first = items.first, first.isImage, first.payloadID == item.payloadID { return }
            items.insert(item, at: 0)
        } else if let text, !text.isEmpty {
            guard text.utf8.count <= maxStoredTextPayloadBytes else { return }
            let incomingPayloadID = payloadSignature(for: Data(text.utf8))
            if let first = items.first, !first.isImage, first.payloadID == incomingPayloadID { return }
            items.removeAll { !$0.isImage && $0.payloadID == incomingPayloadID }
            let item = ClipboardItem(text: text, richData: capturedRichPasteboardData(from: pb), sourceAppName: sourceApp, sourceBundleID: sourceBundle)
            items.insert(item, at: 0)
            stripFormattingIfNeeded(pb, text: text)
        } else {
            return
        }

        let maxItems = AppSettings.shared.historyDepth
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        saveHistory()
    }

    /// Frontmost app at the moment the copy was detected. Polling means this can be
    /// wrong if the user switches apps within one poll interval of copying.
    private func currentSourceAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        // localizedName is CFBundleName, which is often abbreviated (VS Code reports
        // "Code"); the bundle's file name is what users actually recognise.
        if let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent,
           !bundleName.isEmpty {
            return bundleName
        }
        return app.localizedName
    }

    private func currentSourceBundleID() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app.bundleIdentifier
    }

    /// With plain-text pasting on, rewrite the system pasteboard so an ordinary ⌘V
    /// in any app also pastes unstyled. The rich payload is already in history, so
    /// shift-selecting from the overlay can still restore the original formatting.
    private func stripFormattingIfNeeded(_ pb: NSPasteboard, text: String) {
        guard AppSettings.shared.pasteAsPlainText else { return }
        let types = Set(pb.types ?? [])

        let styled: Set<NSPasteboard.PasteboardType> = [.rtf, .rtfd, .html]
        guard !styled.isDisjoint(with: types) else { return }

        // Rewriting would destroy these: a Finder copy would paste its path as text
        // instead of the file, and images would lose their payload. public.url is
        // deliberately not protected — a link is text, so plain-text mode strips it.
        let protected: Set<NSPasteboard.PasteboardType> = [.fileURL, .tiff, .png]
        guard protected.isDisjoint(with: types) else { return }

        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    /// Finder exposes only the file name in the text type, so read the URLs directly
    /// to keep the full path.
    private func fileURLText(from pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return nil }
        return urls.map(\.path).joined(separator: "\n")
    }

    private func refreshCurrentPasteboardPreview() {
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        let hasImage = imageTypes.contains(where: { pb.data(forType: $0) != nil })
        updateCurrentPasteboardPreview(text: pb.string(forType: .string), hasImage: hasImage)
    }

    private func updateCurrentPasteboardPreview(text: String?, hasImage: Bool) {
        if let text, !text.isEmpty {
            currentPasteboardPreview = String(text.prefix(maxCurrentPasteboardPreviewCharacters))
        } else if hasImage {
            currentPasteboardPreview = "Image"
        } else {
            currentPasteboardPreview = nil
        }
    }

    private func updateCurrentPasteboardPreview(for item: ClipboardItem) {
        currentPasteboardPreview = item.isImage
            ? "Image"
            : String(item.text.prefix(maxCurrentPasteboardPreviewCharacters))
    }

    private func notifyMenuBarPreviewChanged() {
        if Thread.isMainThread {
            AppDelegate.shared?.updateMenuBarPreview()
            return
        }

        DispatchQueue.main.async {
            AppDelegate.shared?.updateMenuBarPreview()
        }
    }

    private func capturedRichPasteboardData(from pasteboard: NSPasteboard) -> [String: Data]? {
        let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html]
        var rich: [String: Data] = [:]
        var totalBytes = 0

        for type in richTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            guard data.count <= maxRichPasteboardPayloadBytes,
                  totalBytes + data.count <= maxRichPasteboardPayloadBytes else {
                continue
            }

            rich[type.rawValue] = data
            totalBytes += data.count
        }

        return rich.isEmpty ? nil : rich
    }

    // MARK: - Selection

    func selectItem(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if item.isImage, let img = item.nsImage {
            pb.writeObjects([img])
        } else {
            pb.setString(item.fullText, forType: .string)
        }
        lastChangeCount = pb.changeCount
        updateCurrentPasteboardPreview(for: item)

        // Move to front of history
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        saveHistory()

        isOverlayVisible = false

        notifyMenuBarPreviewChanged()
    }

    /// Called by the overlay after writing to clipboard — updates history + menu bar
    func didSelectItem(_ item: ClipboardItem) {        lastChangeCount = NSPasteboard.general.changeCount
        updateCurrentPasteboardPreview(for: item)

        // Move to front of history
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        saveHistory()

        isOverlayVisible = false

        // Force menu bar update on main thread
        notifyMenuBarPreviewChanged()
    }

    /// Called when a favorite is pasted — just sync the pasteboard change count
    func didPasteFavorite(_ favorite: FavoriteItem) {
        lastChangeCount = NSPasteboard.general.changeCount
        currentPasteboardPreview = String(favorite.text.prefix(maxCurrentPasteboardPreviewCharacters))
        isOverlayVisible = false

        notifyMenuBarPreviewChanged()
    }

    /// Called after a favorite paste puts the user's own clipboard back, so the
    /// poller treats the restored contents as unchanged rather than a new copy.
    func didRestorePasteboard() {
        lastChangeCount = NSPasteboard.general.changeCount
        refreshCurrentPasteboardPreview()
        notifyMenuBarPreviewChanged()
    }

    func clearHistory() {
        items.removeAll()
        ClipboardItem.clearImageCache()
        HistoryPayloadStore.deleteAll()
        saveHistory()
    }

    /// Replaces an entry's text in place. Rich formatting is dropped, because the
    /// edited text no longer matches the captured payload.
    func updateItemText(_ item: ClipboardItem, text: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), !item.isImage else { return }
        items[index] = ClipboardItem(
            text: text,
            sourceAppName: item.sourceAppName,
            sourceBundleID: item.sourceBundleID
        )
        saveHistory()
        notifyMenuBarPreviewChanged()
    }

    // MARK: - Global shortcut (Carbon RegisterEventHotKey — works during secure input)

    @discardableResult
    private func installShortcutTap() -> Bool {
        guard hotKeyRef == nil else { return true }

        let settings = AppSettings.shared

        // Install Carbon event handler for hotkey events
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let engine = Unmanaged<ClipboardEngine>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    engine.toggleOverlay()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard status == noErr else {
            print("[Copi] Failed to install event handler: \(status)")
            return false
        }

        // Convert NSEvent modifier flags to Carbon modifier mask
        let wantFlags = NSEvent.ModifierFlags(rawValue: settings.shortcutModifiers)
        var carbonMods: UInt32 = 0
        if wantFlags.contains(.command)  { carbonMods |= UInt32(cmdKey) }
        if wantFlags.contains(.shift)    { carbonMods |= UInt32(shiftKey) }
        if wantFlags.contains(.option)   { carbonMods |= UInt32(optionKey) }
        if wantFlags.contains(.control)  { carbonMods |= UInt32(controlKey) }

        let hotKeyID = EventHotKeyID(signature: OSType(0x434F5049), // "COPI"
                                      id: 1)

        let regStatus = RegisterEventHotKey(
            UInt32(settings.shortcutKeyCode),
            carbonMods,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus == noErr {
            print("[Copi] Global hotkey registered")
            return true
        } else {
            print("[Copi] Failed to register hotkey: \(regStatus)")
            return false
        }
    }

    /// Re-registers the global hotkey so shortcut changes apply without a restart.
    /// Returns false if the new combination was rejected, usually because another
    /// app already owns it.
    @discardableResult
    func reloadShortcut() -> Bool {
        removeShortcutTap()
        return installShortcutTap()
    }

    private func removeShortcutTap() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func toggleOverlay() {
        if isOverlayVisible {
            isOverlayVisible = false
            CommandOverlay.shared.hide()
            return
        }
        // Favorites are reachable on their own, so an empty history is not empty.
        guard !items.isEmpty || !AppSettings.shared.favorites.isEmpty else { return }
        isOverlayVisible = true
        CommandOverlay.shared.show(items: items)
    }

    // MARK: - Persistence

    private func saveHistory() {
        compactHistoryForStorage()
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "clipboardHistory")
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: "clipboardHistory"),
              let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) else { return }
        let maxItems = AppSettings.shared.historyDepth
        let limitedItems = Array(saved.prefix(maxItems))
        let migratedItems = limitedItems.map { $0.storingPayloadsOnDisk() }
        let compactedItems = compactedHistory(migratedItems)
        items = compactedItems
        ClipboardItem.pruneImageCache(keeping: Set(items.map(\.id)))
        HistoryPayloadStore.prune(keeping: Set(items.flatMap { $0.payloadFileNames }))

        if compactedItems != limitedItems || migratedItems != limitedItems || saved.count > maxItems {
            saveHistory()
        }
    }

    private func compactHistoryForStorage() {
        let compactedItems = compactedHistory(items)
        if compactedItems != items {
            items = compactedItems
        }
        ClipboardItem.pruneImageCache(keeping: Set(items.map(\.id)))
        HistoryPayloadStore.prune(keeping: Set(items.flatMap { $0.payloadFileNames }))
    }

    private func compactedHistory(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var totalTextBytes = 0
        var totalImageBytes = 0
        var totalRichBytes = 0
        return items.compactMap { item in
            let textBytes = item.textPayloadByteCount
            guard textBytes <= maxStoredTextPayloadBytes,
                  totalTextBytes + textBytes <= maxStoredHistoryTextPayloadBytes else {
                return nil
            }

            let imageBytes = item.imageDataByteCount
            guard imageBytes <= maxStoredImagePayloadBytes,
                  totalImageBytes + imageBytes <= maxStoredHistoryImagePayloadBytes else {
                return nil
            }

            let compactedItem = item.pruningOversizedRichData(maxBytes: maxRichPasteboardPayloadBytes)
            let itemRichBytes = compactedItem.richDataByteCount

            if textBytes > 0 { totalTextBytes += textBytes }
            if imageBytes > 0 { totalImageBytes += imageBytes }

            guard itemRichBytes > 0 else {
                return compactedItem
            }

            guard totalRichBytes + itemRichBytes <= maxStoredHistoryRichPayloadBytes else {
                return compactedItem.strippingRichData()
            }

            totalRichBytes += itemRichBytes
            return compactedItem
        }
    }
}
