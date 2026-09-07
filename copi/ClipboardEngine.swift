import Foundation
import AppKit
import Carbon.HIToolbox

private let maxRichPasteboardPayloadBytes = 512 * 1024
private let maxStoredHistoryRichPayloadBytes = 2 * 1024 * 1024
private let maxStoredTextPayloadBytes = 10 * 1024 * 1024
private let maxStoredHistoryTextPayloadBytes = 50 * 1024 * 1024
private let maxStoredImagePayloadBytes = 4 * 1024 * 1024
private let maxStoredHistoryImagePayloadBytes = 32 * 1024 * 1024
private let maxInMemoryTextPreviewCharacters = 2048
private let maxCurrentPasteboardPreviewCharacters = 256
private let pasteboardPollInterval: TimeInterval = 0.25

private func payloadSignature(for data: Data) -> String {
    SecurePayloadCrypto.shared.digest(data) ?? "unavailable-\(UUID().uuidString)"
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
/// Declaration order is the display order everywhere kinds are listed.
enum ContentKind: String, CaseIterable, Codable, Sendable {
    case text = "Text"
    case link = "Link"
    case email = "Email"
    case password = "Password"
    case table = "Table"
    case sql = "SQL"
    case code = "Code"
    case markdown = "Markdown"
    case image = "Image"
    case number = "Number"
    case json = "JSON"
    case xml = "XML"
    case file = "File Path"
}

/// Classification parses the text, and the history list renders every item, so
/// results are memoised. Item text never changes for a given id.
final class ContentKindCache {
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

nonisolated private enum HistoryPayloadStore {
    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Copi", isDirectory: true)
            .appendingPathComponent("SecureHistory-v2", isDirectory: true)
    }

    static func writeText(_ text: String, id: UUID) -> (fileName: String, byteCount: Int)? {
        guard let data = text.data(using: .utf8) else { return nil }
        let fileName = "\(id.uuidString)-text.copi"
        guard writeData(data, fileName: fileName) else { return nil }
        return (fileName, data.count)
    }

    static func readText(fileName: String) -> String? {
        guard let data = readData(fileName: fileName) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeImageData(_ data: Data, id: UUID) -> (fileName: String, byteCount: Int)? {
        let fileName = "\(id.uuidString)-image.copi"
        guard writeData(data, fileName: fileName) else { return nil }
        return (fileName, data.count)
    }

    static func writeRichData(_ richData: [String: Data], id: UUID) -> (fileNames: [String: String], byteCount: Int)? {
        var fileNames: [String: String] = [:]
        var totalBytes = 0

        for (index, key) in richData.keys.sorted().enumerated() {
            guard let data = richData[key] else { continue }
            let fileName = "\(id.uuidString)-rich-\(index).copi"
            guard writeData(data, fileName: fileName) else { continue }
            fileNames[key] = fileName
            totalBytes += data.count
        }

        return fileNames.isEmpty ? nil : (fileNames, totalBytes)
    }

    static func readData(fileName: String) -> Data? {
        guard let directory else { return nil }
        let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
        guard let encrypted = try? Data(contentsOf: directory.appendingPathComponent(safeFileName, isDirectory: false)) else {
            return nil
        }
        return try? SecurePayloadCrypto.shared.open(
            encrypted,
            purpose: "history-file:\(safeFileName)"
        )
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

    static func delete(_ fileNames: Set<String>) {
        guard let directory else { return }
        for fileName in fileNames {
            let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(safeFileName, isDirectory: false))
        }
    }

    private static func writeData(_ data: Data, fileName: String) -> Bool {
        guard let directory else { return false }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let safeFileName = URL(fileURLWithPath: fileName).lastPathComponent
            let encrypted = try SecurePayloadCrypto.shared.seal(
                data,
                purpose: "history-file:\(safeFileName)"
            )
            try encrypted.write(to: directory.appendingPathComponent(safeFileName, isDirectory: false), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Clipboard item model

struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Display/search preview; also the editable label for image entries.
    var text: String
    /// Optional user-facing name for a Password. The encrypted payload remains
    /// in `fullText`; changing this never changes what Copi pastes.
    var customLabel: String?
    /// In-memory only. Equivalent Favorite/history representations share the
    /// strongest masking policy while an overlay is open, without rewriting
    /// the history record that owns the encrypted payload.
    var presentationMaskOverride = false
    var presentationPasswordOverride = false
    var presentationLabelOverride: String?
    let date: Date
    /// App that was frontmost when the copy was detected.
    let sourceAppName: String?
    let sourceBundleID: String?
    /// Compact semantic location in the source app at copy detection time.
    /// The encrypted history manifest persists this; no AX field value or full
    /// browser URL is included.
    let sourceContext: ClipboardSourceContextSnapshot?
    /// A manual classification is permanent and always wins over detection.
    var contentKindOverride: ContentKind?
    /// Bounded capture diagnostics retained for the developer hover card.
    let pasteboardItemCount: Int
    let pasteboardTypeIdentifiers: [String]
    let pasteboardTypeByteCounts: [String: Int]
    let captureNotes: [String]

    private let textFileName: String?
    private let textByteCount: Int
    private let imageFileName: String?
    private let storedImageByteCount: Int
    private let richFileNames: [String: String]?
    private let storedRichByteCount: Int
    private let contentSignature: String
    private let inlineImageData: Data?
    private let inlineRichData: [String: Data]?

    nonisolated var isImage: Bool { imageFileName != nil || inlineImageData != nil }

    var detectedContentKind: ContentKind {
        ContentKindCache.shared.kind(for: id) {
            classifyClipboardContent(
                text: text,
                isImage: isImage,
                // Compared against the stored full text rather than the preview
                // cap, so changing the cap cannot silently disable this.
                isTruncated: text.utf8.count < textByteCount
            )
        }
    }

    var contentKind: ContentKind {
        presentationPasswordOverride ? .password : (contentKindOverride ?? detectedContentKind)
    }
    var shouldMask: Bool { presentationMaskOverride || contentKind == .password }
    var displayLabel: String? { customLabel ?? presentationLabelOverride }

    var fullText: String {
        guard !isImage else { return text }
        if let textFileName,
           let storedText = HistoryPayloadStore.readText(fileName: textFileName) {
            return storedText
        }
        return text
    }

    nonisolated var imageData: Data? {
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
        if let cached = ClipboardItem.imageCache[id] { return cached }
        guard let data = imageData else { return nil }
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

    func discardStoredPayloads() {
        HistoryPayloadStore.delete(payloadFileNames)
    }

    /// A repeated copy of the same payload is still a new provenance event. Keep
    /// the stored payload and permanent type override, but refresh when and where
    /// it was copied so diagnostics do not report stale source information.
    func refreshingSource(
        appName: String?,
        bundleID: String?,
        context: ClipboardSourceContextSnapshot?
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            text: text,
            customLabel: customLabel,
            // The payload capture and its representation diagnostics remain the
            // original event. The refreshed source snapshot carries its own
            // newer observation timestamp.
            date: date,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            sourceContext: context,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
            textFileName: textFileName,
            textByteCount: textByteCount,
            imageFileName: imageFileName,
            storedImageByteCount: storedImageByteCount,
            richFileNames: richFileNames,
            storedRichByteCount: storedRichByteCount,
            contentSignature: contentSignature,
            inlineImageData: inlineImageData,
            inlineRichData: inlineRichData
        )
    }

    func pruningOversizedRichData(maxBytes: Int) -> ClipboardItem {
        guard richDataByteCount > maxBytes else { return self }
        return strippingRichData()
    }

    func strippingRichData() -> ClipboardItem {
        return ClipboardItem(
            id: id,
            text: text,
            customLabel: customLabel,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
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
            customLabel: customLabel,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
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
        customLabel: String?,
        date: Date,
        sourceAppName: String?,
        sourceBundleID: String?,
        sourceContext: ClipboardSourceContextSnapshot?,
        contentKindOverride: ContentKind?,
        pasteboardItemCount: Int,
        pasteboardTypeIdentifiers: [String],
        pasteboardTypeByteCounts: [String: Int],
        captureNotes: [String],
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
        self.customLabel = customLabel
        self.date = date
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.sourceContext = sourceContext
        self.contentKindOverride = contentKindOverride
        self.pasteboardItemCount = pasteboardItemCount
        self.pasteboardTypeIdentifiers = pasteboardTypeIdentifiers
        self.pasteboardTypeByteCounts = pasteboardTypeByteCounts
        self.captureNotes = captureNotes
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

    init(
        text: String,
        customLabel: String? = nil,
        richData: [String: Data]? = nil,
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        sourceContext: ClipboardSourceContextSnapshot? = nil,
        contentKindOverride: ContentKind? = nil,
        pasteboardItemCount: Int = 1,
        pasteboardTypeIdentifiers: [String] = [NSPasteboard.PasteboardType.string.rawValue],
        pasteboardTypeByteCounts: [String: Int] = [:],
        captureNotes: [String] = [],
        persistImmediately: Bool = true
    ) {
        let id = UUID()
        let textData = Data(text.utf8)
        let storedText = persistImmediately ? HistoryPayloadStore.writeText(text, id: id) : nil
        let storedRich = persistImmediately
            ? richData.flatMap { HistoryPayloadStore.writeRichData($0, id: id) }
            : nil

        self.init(
            id: id,
            text: storedText == nil ? text : previewText(for: text),
            customLabel: customLabel,
            date: Date(),
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
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

    /// Pasteboard image capture already provides a usable representation. Keep
    /// those bytes in memory briefly; conversion/encryption and disk I/O happen
    /// on the serial persistence queue instead of the clipboard polling turn.
    init(
        capturedImageData: Data,
        imageSize: NSSize,
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        sourceContext: ClipboardSourceContextSnapshot? = nil,
        pasteboardItemCount: Int = 1,
        pasteboardTypeIdentifiers: [String] = [],
        pasteboardTypeByteCounts: [String: Int] = [:],
        captureNotes: [String] = []
    ) {
        let id = UUID()
        let label = "[Image \(Int(imageSize.width))×\(Int(imageSize.height))]"
        self.init(
            id: id,
            text: label,
            customLabel: nil,
            date: Date(),
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: nil,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
            textFileName: nil,
            textByteCount: 0,
            imageFileName: nil,
            storedImageByteCount: capturedImageData.count,
            richFileNames: nil,
            storedRichByteCount: 0,
            contentSignature: payloadSignature(for: capturedImageData),
            inlineImageData: capturedImageData,
            inlineRichData: nil
        )
    }

    init(
        image: NSImage,
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        sourceContext: ClipboardSourceContextSnapshot? = nil,
        contentKindOverride: ContentKind? = nil,
        pasteboardItemCount: Int = 1,
        pasteboardTypeIdentifiers: [String] = [],
        pasteboardTypeByteCounts: [String: Int] = [:],
        captureNotes: [String] = []
    ) {
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
            customLabel: nil,
            date: Date(),
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
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
        case customLabel
        case date
        case sourceAppName
        case sourceBundleID
        case sourceContext
        case contentKindOverride
        case pasteboardItemCount
        case pasteboardTypeIdentifiers
        case pasteboardTypeByteCounts
        case captureNotes
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
        let customLabel = try container.decodeIfPresent(String.self, forKey: .customLabel)
        let date = try container.decode(Date.self, forKey: .date)
        let sourceAppName = try container.decodeIfPresent(String.self, forKey: .sourceAppName)
        let sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        let sourceContext = try container.decodeIfPresent(
            ClipboardSourceContextSnapshot.self,
            forKey: .sourceContext
        )
        let contentKindOverride = try container.decodeIfPresent(ContentKind.self, forKey: .contentKindOverride)
        let pasteboardItemCount = try container.decodeIfPresent(Int.self, forKey: .pasteboardItemCount) ?? 1
        let pasteboardTypeIdentifiers = try container.decodeIfPresent([String].self, forKey: .pasteboardTypeIdentifiers) ?? []
        let pasteboardTypeByteCounts = try container.decodeIfPresent([String: Int].self, forKey: .pasteboardTypeByteCounts) ?? [:]
        let captureNotes = try container.decodeIfPresent([String].self, forKey: .captureNotes) ?? []
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
            customLabel: customLabel,
            date: date,
            sourceAppName: sourceAppName,
            sourceBundleID: sourceBundleID,
            sourceContext: sourceContext,
            contentKindOverride: contentKindOverride,
            pasteboardItemCount: pasteboardItemCount,
            pasteboardTypeIdentifiers: pasteboardTypeIdentifiers,
            pasteboardTypeByteCounts: pasteboardTypeByteCounts,
            captureNotes: captureNotes,
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
        try container.encodeIfPresent(customLabel, forKey: .customLabel)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try container.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID)
        try container.encodeIfPresent(sourceContext, forKey: .sourceContext)
        try container.encodeIfPresent(contentKindOverride, forKey: .contentKindOverride)
        try container.encode(pasteboardItemCount, forKey: .pasteboardItemCount)
        try container.encode(pasteboardTypeIdentifiers, forKey: .pasteboardTypeIdentifiers)
        try container.encode(pasteboardTypeByteCounts, forKey: .pasteboardTypeByteCounts)
        try container.encode(captureNotes, forKey: .captureNotes)
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
            && lhs.customLabel == rhs.customLabel
            && lhs.presentationMaskOverride == rhs.presentationMaskOverride
            && lhs.presentationPasswordOverride == rhs.presentationPasswordOverride
            && lhs.presentationLabelOverride == rhs.presentationLabelOverride
            && lhs.date == rhs.date
            && lhs.sourceAppName == rhs.sourceAppName
            && lhs.sourceBundleID == rhs.sourceBundleID
            && lhs.sourceContext == rhs.sourceContext
            && lhs.contentKindOverride == rhs.contentKindOverride
            && lhs.pasteboardItemCount == rhs.pasteboardItemCount
            && lhs.pasteboardTypeIdentifiers == rhs.pasteboardTypeIdentifiers
            && lhs.pasteboardTypeByteCounts == rhs.pasteboardTypeByteCounts
            && lhs.captureNotes == rhs.captureNotes
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
    private(set) var currentClipboardItemID: UUID?
    private(set) var historyStorageError: String?
    var isOverlayVisible = false

    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount: Int = 0
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var historyPersistenceIsWritable = true
    private var persistedItemIDs = Set<UUID>()
    private var passwordClipboardClearWork: DispatchWorkItem?
    private var historySaveWork: DispatchWorkItem?
    private let historyPersistenceQueue = DispatchQueue(
        label: "com.jos.copi.history-persistence",
        qos: .utility
    )
    private var historySaveGeneration = 0

    var requiresSecureStorageReset: Bool { !historyPersistenceIsWritable }
    private var passwordClipboardClearChangeCount: Int?

    private init() {
        loadHistory()
        lastChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Lifecycle

    func start() {
        // The clipboard usually predates app launch, so its change count cannot
        // be used as proof that persisted row one is current.
        checkPasteboard(force: true)
        startPolling()
        installShortcutTap()
    }

    func stop() {
        flushPendingHistorySave()
        clearScheduledPasswordClipboardIfOwned(reason: "applicationTermination")
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

    private func checkPasteboard(force: Bool = false) {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard force || count != lastChangeCount else { return }
        if force, count == lastChangeCount, currentClipboardItemID != nil { return }
        let processingInterval = PerformanceTrace.begin("Clipboard Processing")
        defer { PerformanceTrace.end(processingInterval) }
        let captureID = UUID()
        lastChangeCount = count
        // A forced startup/reset reconciliation sees a pre-existing pasteboard,
        // not the app that originally populated it, so provenance would be a
        // guess. Only a newly observed change gets a source snapshot.
        let source = force ? nil : currentSourceApplication()
        let sourceApp = source?.name
        let sourceBundle = source?.bundleID
        let sourceContext = source.map {
            DestinationContextCapture.captureClipboardSource(application: $0.application)
        }
        let shouldRefreshSourceObservation = !force
        let capture = pasteboardCaptureMetadata(from: pb)
        let correlation = DiagnosticLogCorrelation(captureID: captureID)
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .clipboardChangeDetected,
            correlation: correlation,
            fields: [
                DiagnosticLogField(.changeCount, integer: count),
                DiagnosticLogField(.sourceAppName, sourceApp ?? "unknown"),
                DiagnosticLogField(.sourceBundleIdentifier, sourceBundle ?? "unknown"),
                DiagnosticLogField(.itemCount, integer: capture.itemCount),
                DiagnosticLogField(.representationCount, integer: capture.typeIdentifiers.count),
                DiagnosticLogField(.uniformTypeIdentifier, capture.typeIdentifiers.joined(separator: ",")),
            ]
        ))

        // Checking availability does not ask the source app to materialize a
        // potentially huge lazy image representation. Load it only if this is an
        // image-only capture that Copi will actually retain.
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        let availableImageType = pb.availableType(from: imageTypes)
        let hasImage = availableImageType != nil
        let text = fileURLText(from: pb) ?? pb.string(forType: .string)
        let hasText = !(text ?? "").isEmpty

        updateCurrentPasteboardPreview(text: text, hasImage: hasImage)
        defer {
            notifyMenuBarPreviewChanged()
            CommandOverlay.shared.refreshPinnedContent(
                items: items,
                currentClipboardItemID: currentClipboardItemID
            )
        }

        if hasImage, !hasText, let imageType = availableImageType,
           let imgData = pb.data(forType: imageType),
           let nsImage = NSImage(data: imgData) {
            // Image-only clipboard entry
            let item = ClipboardItem(
                capturedImageData: imgData,
                imageSize: nsImage.size,
                sourceAppName: sourceApp,
                sourceBundleID: sourceBundle,
                sourceContext: sourceContext,
                pasteboardItemCount: capture.itemCount,
                pasteboardTypeIdentifiers: capture.typeIdentifiers,
                pasteboardTypeByteCounts: [imageType.rawValue: imgData.count],
                captureNotes: capture.notes
            )
            guard item.imageDataByteCount <= maxStoredImagePayloadBytes else {
                item.discardStoredPayloads()
                currentClipboardItemID = nil
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .clipboardCaptureDropped,
                    level: .notice,
                    correlation: correlation,
                    fields: [DiagnosticLogField(.dropReason, "imagePayloadTooLarge")]
                ))
                return
            }
            // Don't add if most recent is same dimensions image
            if let first = items.first, first.isImage, first.payloadID == item.payloadID {
                item.discardStoredPayloads()
                if shouldRefreshSourceObservation {
                    items[0] = first.refreshingSource(
                        appName: sourceApp,
                        bundleID: sourceBundle,
                        context: sourceContext
                    )
                    scheduleHistorySave()
                }
                currentClipboardItemID = first.id
                var duplicateFields = [
                    DiagnosticLogField(.dropReason, "duplicateMostRecentImage"),
                    DiagnosticLogField(
                        .captureDecision,
                        shouldRefreshSourceObservation ? "sourceObservationRefreshed" : "startupProvenancePreserved"
                    ),
                ]
                if let sourceContext {
                    duplicateFields.append(contentsOf: diagnosticFields(for: sourceContext))
                }
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .clipboardCaptureDropped,
                    correlation: DiagnosticLogCorrelation(
                        captureID: captureID,
                        clipboardItemID: first.id
                    ),
                    fields: duplicateFields
                ))
                recordSourceCopy(first, source: sourceContext, captureID: captureID)
                return
            }
            items.insert(item, at: 0)
            currentClipboardItemID = item.id
        } else if let text, !text.isEmpty {
            guard text.utf8.count <= maxStoredTextPayloadBytes else {
                currentClipboardItemID = nil
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .clipboardCaptureDropped,
                    level: .notice,
                    correlation: correlation,
                    fields: [DiagnosticLogField(.dropReason, "textPayloadTooLarge")]
                ))
                return
            }
            let incomingPayloadID = payloadSignature(for: Data(text.utf8))
            if let first = items.first, !first.isImage, first.payloadID == incomingPayloadID {
                if shouldRefreshSourceObservation {
                    items[0] = first.refreshingSource(
                        appName: sourceApp,
                        bundleID: sourceBundle,
                        context: sourceContext
                    )
                    scheduleHistorySave()
                }
                currentClipboardItemID = first.id
                var duplicateFields = [
                    DiagnosticLogField(.dropReason, "duplicateMostRecentText"),
                    DiagnosticLogField(
                        .captureDecision,
                        shouldRefreshSourceObservation ? "sourceObservationRefreshed" : "startupProvenancePreserved"
                    ),
                ]
                if let sourceContext {
                    duplicateFields.append(contentsOf: diagnosticFields(for: sourceContext))
                }
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .clipboardCaptureDropped,
                    correlation: DiagnosticLogCorrelation(
                        captureID: captureID,
                        clipboardItemID: first.id
                    ),
                    fields: duplicateFields
                ))
                recordSourceCopy(first, source: sourceContext, captureID: captureID)
                return
            }
            let previousItem = items.first {
                !$0.isImage && $0.payloadID == incomingPayloadID
            }
            let previousOverride = previousItem?.contentKindOverride
            let previousCustomLabel = previousItem?.customLabel
            items.removeAll { !$0.isImage && $0.payloadID == incomingPayloadID }
            let richData = capturedRichPasteboardData(from: pb)
            var knownByteCounts = [NSPasteboard.PasteboardType.string.rawValue: text.utf8.count]
            for (type, data) in richData ?? [:] {
                knownByteCounts[type] = data.count
            }
            let item = ClipboardItem(
                text: text,
                customLabel: previousCustomLabel,
                richData: richData,
                sourceAppName: sourceApp,
                sourceBundleID: sourceBundle,
                sourceContext: sourceContext,
                contentKindOverride: previousOverride,
                pasteboardItemCount: capture.itemCount,
                pasteboardTypeIdentifiers: capture.typeIdentifiers,
                pasteboardTypeByteCounts: knownByteCounts,
                captureNotes: capture.notes + (hasImage ? ["Image representations were not retained because the entry also contained text."] : []),
                persistImmediately: false
            )
            items.insert(item, at: 0)
            currentClipboardItemID = item.id
            stripFormattingIfNeeded(pb, text: text)
        } else {
            currentClipboardItemID = nil
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .clipboardCaptureDropped,
                correlation: correlation,
                fields: [DiagnosticLogField(.dropReason, "unsupportedOrEmptyPasteboard")]
            ))
            return
        }

        let maxItems = AppSettings.shared.historyDepth
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }

        saveHistory()
        if let newest = items.first {
            var completionFields = [
                DiagnosticLogField(.payloadType, newest.isImage ? "image" : "text"),
                DiagnosticLogField(.byteCount, integer: newest.isImage ? newest.imageDataByteCount : newest.textPayloadByteCount),
                DiagnosticLogField(.detectedKind, newest.detectedContentKind.rawValue),
                DiagnosticLogField(.effectiveKind, newest.contentKind.rawValue),
                DiagnosticLogField(.payloadDigest, newest.payloadID),
                DiagnosticLogField(.encryptionStatus, storageDescription(for: newest)),
                DiagnosticLogField(.envelopeVersion, integer: SecurePayloadCrypto.envelopeVersion),
            ]
            if let source = newest.sourceContext {
                completionFields.append(contentsOf: diagnosticFields(for: source))
            }
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .clipboardCaptureCompleted,
                correlation: DiagnosticLogCorrelation(
                    captureID: captureID,
                    clipboardItemID: newest.id
                ),
                fields: completionFields
            ))
            recordSourceCopy(newest, source: sourceContext, captureID: captureID)
        }
    }

    private func recordSourceCopy(
        _ item: ClipboardItem,
        source: ClipboardSourceContextSnapshot?,
        captureID: UUID
    ) {
        guard let source else { return }
        SuggestionCoordinator.shared.recordSourceCopy(
            candidateKey: suggestionCandidateKey(for: item),
            source: source,
            clipboardItemID: item.id,
            captureID: captureID
        )
    }

    private func diagnosticFields(
        for source: ClipboardSourceContextSnapshot
    ) -> [DiagnosticLogField] {
        [
            DiagnosticLogField(.sourceSurface, source.semantic.surface.rawValue),
            DiagnosticLogField(.sourceFocusedArea, source.semantic.focusedArea.rawValue),
            DiagnosticLogField(.sourceClassifier, source.semantic.classifier.rawValue),
            DiagnosticLogField(.sourceAccessibility, source.accessibility.rawValue),
            DiagnosticLogField(
                .sourceContextCaptureMilliseconds,
                String(format: "%.2f", source.captureDurationMilliseconds)
            ),
        ]
    }

    private func pasteboardCaptureMetadata(from pasteboard: NSPasteboard) -> (
        itemCount: Int,
        typeIdentifiers: [String],
        byteCounts: [String: Int],
        notes: [String]
    ) {
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        let maximumRecordedTypes = 128
        var identifiers = Set<String>()
        var typesWereTruncated = false
        for item in pasteboardItems.prefix(32) {
            for type in item.types {
                guard identifiers.count < maximumRecordedTypes else {
                    typesWereTruncated = true
                    break
                }
                if type.rawValue.count > 256 { typesWereTruncated = true }
                identifiers.insert(String(type.rawValue.prefix(256)))
            }
        }
        var notes: [String] = []
        if pasteboardItems.count > 1 {
            notes.append("\(pasteboardItems.count) pasteboard items were flattened into one history entry.")
        }
        if pasteboardItems.count > 32 {
            notes.append("Representation diagnostics were limited to the first 32 pasteboard items.")
        }
        if typesWereTruncated {
            notes.append("Representation diagnostics were limited to 128 unique type identifiers.")
        }
        return (
            pasteboardItems.count,
            identifiers.sorted(),
            [:],
            notes
        )
    }

    /// Frontmost app at the moment the copy was detected. Polling means this can be
    /// wrong if the user switches apps within one poll interval of copying.
    private func currentSourceApplication() -> (
        application: NSRunningApplication,
        name: String?,
        bundleID: String?
    )? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        // localizedName is CFBundleName, which is often abbreviated (VS Code reports
        // "Code"); the bundle's file name is what users actually recognise.
        let name: String?
        if let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent,
           !bundleName.isEmpty {
            name = bundleName
        } else {
            name = app.localizedName
        }
        return (app, name, app.bundleIdentifier)
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
            let preview = String(text.prefix(maxCurrentPasteboardPreviewCharacters))
            let digest = SecurePayloadCrypto.shared.digest(Data(text.utf8))
            let isPassword = digest.flatMap { value in
                items.first { !$0.isImage && $0.payloadID == value }
            }?.contentKind == .password
            currentClipboardItemID = digest.flatMap { value in
                items.first { !$0.isImage && $0.payloadID == value }?.id
            }
            let isMaskedFavorite = AppSettings.shared.favorites.contains {
                !$0.isImage && $0.shouldMask && $0.text == text
            }
            currentPasteboardPreview = isPassword || isMaskedFavorite
                ? overlayMaskedText(preview)
                : preview
        } else if hasImage {
            currentPasteboardPreview = "Image"
            currentClipboardItemID = nil
        } else {
            currentPasteboardPreview = nil
            currentClipboardItemID = nil
        }
    }

    private func updateCurrentPasteboardPreview(for item: ClipboardItem) {
        currentClipboardItemID = item.id
        currentPasteboardPreview = item.isImage
            ? "Image"
            : overlayPreviewText(for: item, previewLength: maxCurrentPasteboardPreviewCharacters)
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
        let imagePayload = item.isImage ? item.nsImage : nil
        if item.isImage, imagePayload == nil {
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteFailed,
                level: .error,
                correlation: DiagnosticLogCorrelation(clipboardItemID: item.id),
                fields: [DiagnosticLogField(.reason, "encryptedImagePayloadUnavailable")]
            ))
            return
        }
        passwordClipboardClearWork?.cancel()
        passwordClipboardClearWork = nil
        passwordClipboardClearChangeCount = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        if let imagePayload {
            pb.writeObjects([imagePayload])
        } else {
            pb.setString(item.fullText, forType: .string)
        }
        lastChangeCount = pb.changeCount
        updateCurrentPasteboardPreview(for: item)

        // Move to front of history
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        saveHistory()

        if !AppSettings.shared.overlayAlwaysOnTop { isOverlayVisible = false }

        notifyMenuBarPreviewChanged()

        guard item.contentKind == .password else { return }
        let expectedChangeCount = pb.changeCount
        passwordClipboardClearChangeCount = expectedChangeCount
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.passwordClipboardClearChangeCount == expectedChangeCount else { return }
            self.passwordClipboardClearWork = nil
            self.passwordClipboardClearChangeCount = nil
            guard NSPasteboard.general.changeCount == expectedChangeCount else { return }
            NSPasteboard.general.clearContents()
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.currentClipboardItemID = nil
            self.currentPasteboardPreview = nil
            self.notifyMenuBarPreviewChanged()
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .pasteboardRestored,
                correlation: DiagnosticLogCorrelation(clipboardItemID: item.id),
                fields: [DiagnosticLogField(.outcome, "settingsPasswordClipboardExpired")]
            ))
        }
        passwordClipboardClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// Normal termination must not turn cancelling a timer into leaving a
    /// password behind. Ownership is proven with the same pasteboard generation
    /// captured when Copi wrote the value, so a later user copy is never cleared.
    private func clearScheduledPasswordClipboardIfOwned(reason: String) {
        passwordClipboardClearWork?.cancel()
        passwordClipboardClearWork = nil
        guard let expectedChangeCount = passwordClipboardClearChangeCount else { return }
        passwordClipboardClearChangeCount = nil
        guard NSPasteboard.general.changeCount == expectedChangeCount else { return }
        NSPasteboard.general.clearContents()
        lastChangeCount = NSPasteboard.general.changeCount
        currentClipboardItemID = nil
        currentPasteboardPreview = nil
        notifyMenuBarPreviewChanged()
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .pasteboardRestored,
            fields: [DiagnosticLogField(.outcome, "settingsPasswordClipboardCleared:\(reason)")]
        ))
    }

    /// Called by the overlay after writing to clipboard — updates history + menu bar
    func didSelectItem(_ item: ClipboardItem) {
        lastChangeCount = NSPasteboard.general.changeCount
        updateCurrentPasteboardPreview(for: item)

        // Move to front of history
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        saveHistory()

        if !AppSettings.shared.overlayAlwaysOnTop { isOverlayVisible = false }

        // Force menu bar update on main thread
        notifyMenuBarPreviewChanged()
    }

    /// Called when a favorite is pasted — just sync the pasteboard change count
    func didPasteFavorite(_ favorite: FavoriteItem) {
        lastChangeCount = NSPasteboard.general.changeCount
        currentPasteboardPreview = overlayFavoritePreviewText(
            for: favorite,
            previewLength: maxCurrentPasteboardPreviewCharacters
        )
        currentClipboardItemID = nil
        if !AppSettings.shared.overlayAlwaysOnTop { isOverlayVisible = false }

        notifyMenuBarPreviewChanged()
    }

    /// Called after a multi-selection paste, which writes a payload the poller
    /// should not capture as a fresh copy.
    func didPasteCombined(containsPassword: Bool = false) {
        lastChangeCount = NSPasteboard.general.changeCount
        if containsPassword, let text = NSPasteboard.general.string(forType: .string) {
            currentPasteboardPreview = overlayMaskedText(
                String(text.prefix(maxCurrentPasteboardPreviewCharacters))
            )
            currentClipboardItemID = nil
        } else {
            refreshCurrentPasteboardPreview()
        }
        if !AppSettings.shared.overlayAlwaysOnTop { isOverlayVisible = false }
        notifyMenuBarPreviewChanged()
    }

    /// Called after a favorite paste puts the user's own clipboard back, so the
    /// poller treats the restored contents as unchanged rather than a new copy.
    func didRestorePasteboard() {
        lastChangeCount = NSPasteboard.general.changeCount
        refreshCurrentPasteboardPreview()
        notifyMenuBarPreviewChanged()
    }

    /// Used only while deciding whether a temporary paste may safely restore an
    /// older clipboard snapshot. Known Password entries must not be resurrected
    /// after their original expiry/restore ownership has been superseded.
    func isKnownPasswordClipboardText(_ text: String) -> Bool {
        let digest = SecurePayloadCrypto.shared.digest(Data(text.utf8))
        if let digest,
           items.contains(where: { !$0.isImage && $0.payloadID == digest && $0.contentKind == .password }) {
            return true
        }
        return AppSettings.shared.favorites.contains {
            !$0.isImage && $0.contentKind == .password && $0.text == text
        }
    }

    func clearHistory() {
        items.removeAll()
        currentClipboardItemID = nil
        ClipboardItem.clearImageCache()
        HistoryPayloadStore.deleteAll()
        saveHistory()
        CommandOverlay.shared.refreshPinnedContent(items: [], currentClipboardItemID: nil)
    }

    /// Re-enables history persistence after the user has confirmed a destructive
    /// global secure-storage reset, then commits a clean encrypted manifest.
    func reinitializeAfterSecureStorageReset() throws {
        items.removeAll()
        currentClipboardItemID = nil
        currentPasteboardPreview = nil
        persistedItemIDs.removeAll()
        ClipboardItem.clearImageCache()
        historyPersistenceIsWritable = true
        historyStorageError = nil
        saveHistory(synchronously: true)
        guard historyStorageError == nil else {
            throw SecureStorageError.encryptionFailed
        }
        // Reset removes the persisted row that represented the live pasteboard.
        // Reconcile immediately even though its change count has not changed, so
        // the current clipboard is available as result one without another copy.
        checkPasteboard(force: true)
        notifyMenuBarPreviewChanged()
    }

    /// Replaces an entry's text in place. Images keep their payload and only
    /// take a new label; text entries lose rich formatting, because the edited
    /// text no longer matches the captured payload.
    @discardableResult
    func updateItemText(_ item: ClipboardItem, text: String) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let wasCurrentClipboardItem = currentClipboardItemID == item.id
        if item.isImage {
            items[index].text = text
        } else {
            items[index] = ClipboardItem(
                text: text,
                customLabel: item.customLabel,
                sourceAppName: item.sourceAppName,
                sourceBundleID: item.sourceBundleID,
                sourceContext: item.sourceContext,
                // If this in-memory representation inherited Password safety
                // from equivalent Favorite content, editing creates a new
                // identity that must retain that protection explicitly.
                contentKindOverride: item.contentKind == .password
                    ? .password
                    : item.contentKindOverride,
                pasteboardItemCount: item.pasteboardItemCount,
                pasteboardTypeIdentifiers: item.pasteboardTypeIdentifiers,
                pasteboardTypeByteCounts: item.pasteboardTypeByteCounts,
                captureNotes: item.captureNotes + ["Text was edited in Copi; captured rich representations were removed."]
            )
        }
        if wasCurrentClipboardItem, items[index].id != item.id {
            // Editing history does not rewrite the system clipboard. Re-resolve
            // its live payload instead of pinning the newly edited value as row 1.
            currentClipboardItemID = nil
            refreshCurrentPasteboardPreview()
        }
        saveHistory()
        notifyMenuBarPreviewChanged()
        return items[index]
    }

    /// Names a Password without modifying its secret payload or paste identity.
    @discardableResult
    func updateItemLabel(_ item: ClipboardItem, label: String) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        items[index].customLabel = trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        scheduleHistorySave()
        if currentClipboardItemID == item.id {
            updateCurrentPasteboardPreview(for: items[index])
        }
        notifyMenuBarPreviewChanged()
        return items[index]
    }

    /// Removes selected history rows and their encrypted payload files. Deleting
    /// a row never alters the system pasteboard itself.
    func deleteItems(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        removed.forEach { $0.discardStoredPayloads() }
        ClipboardItem.pruneImageCache(keeping: Set(items.map(\.id)))
        if let currentClipboardItemID, ids.contains(currentClipboardItemID) {
            self.currentClipboardItemID = nil
        }
        scheduleHistorySave()
        notifyMenuBarPreviewChanged()
        CommandOverlay.shared.refreshPinnedContent(
            items: items,
            currentClipboardItemID: currentClipboardItemID
        )
    }

    @discardableResult
    func setContentKindOverride(id: UUID, kind: ContentKind?) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].contentKindOverride = kind
        if currentClipboardItemID == id {
            updateCurrentPasteboardPreview(for: items[index])
        }
        // Return to SwiftUI before encrypting the complete history manifest. In
        // particular, full-manifest encryption must never make the menu look as
        // though the type choice was ignored.
        scheduleHistorySave()
        notifyMenuBarPreviewChanged()
        DiagnosticLog.shared.record(DiagnosticLogEvent(
            .contentTypeOverridden,
            correlation: DiagnosticLogCorrelation(clipboardItemID: id),
            fields: [
                DiagnosticLogField(.detectedKind, items[index].detectedContentKind.rawValue),
                DiagnosticLogField(.overrideKind, kind?.rawValue ?? "Automatic"),
                DiagnosticLogField(.effectiveKind, items[index].contentKind.rawValue),
            ]
        ))
        return items[index]
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
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr,
                      hotKeyID.signature == OSType(0x434F5049), // "COPI"
                      hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
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
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .storageFailed,
                level: .error,
                fields: [
                    DiagnosticLogField(.operation, "installHotKeyHandler"),
                    DiagnosticLogField(.errorCode, integer: Int(status)),
                ]
            ))
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
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .configurationChanged,
                fields: [DiagnosticLogField(.operation, "globalHotKeyRegistered")]
            ))
            return true
        } else {
            DiagnosticLog.shared.record(DiagnosticLogEvent(
                .storageFailed,
                level: .error,
                fields: [
                    DiagnosticLogField(.operation, "registerGlobalHotKey"),
                    DiagnosticLogField(.errorCode, integer: Int(regStatus)),
                ]
            ))
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
            if AppSettings.shared.overlayAlwaysOnTop {
                CommandOverlay.shared.bringPinnedOverlayToFront()
            } else {
                hideOverlay()
            }
            return
        }
        presentOverlay()
    }

    func showPinnedOverlay() {
        guard AppSettings.shared.overlayAlwaysOnTop else { return }
        if isOverlayVisible {
            CommandOverlay.shared.bringPinnedOverlayToFront()
        } else {
            presentOverlay()
        }
    }

    func hideOverlay() {
        isOverlayVisible = false
        CommandOverlay.shared.hide()
    }

    private func presentOverlay() {
        let hotkeyToFrameInterval = PerformanceTrace.begin("Hotkey To First Frame")
        OverlayPasteFlow.prepareForOverlayOpen()
        let frontmost = NSWorkspace.shared.frontmostApplication
        let destination = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil
            : frontmost
        // Freeze destination identity and AX state at hotkey time, before a large
        // clipboard payload can delay ingestion or Copi takes focus.
        let destinationContext = destination.map {
            DestinationContextCapture.capture(application: $0)
        }
        // A genuine just-copy has a new change count even before the 250 ms poll.
        // Do not force an unchanged pasteboard here: during Copi's own temporary
        // password/favorite paste it is intentionally not a history candidate.
        checkPasteboard()
        // Favorites are reachable on their own, so an empty history is not empty.
        guard AppSettings.shared.overlayAlwaysOnTop
                || !items.isEmpty
                || !AppSettings.shared.favorites.isEmpty else {
            PerformanceTrace.end(hotkeyToFrameInterval)
            return
        }
        isOverlayVisible = true
        CommandOverlay.shared.show(
            items: items,
            currentClipboardItemID: currentClipboardItemID,
            destinationApplication: destination,
            destinationContext: destinationContext,
            hotkeyToFrameInterval: hotkeyToFrameInterval
        )
    }

    // MARK: - Persistence

    private func scheduleHistorySave() {
        historySaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.historySaveWork = nil
            self.saveHistory()
        }
        historySaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func flushPendingHistorySave() {
        historySaveWork?.cancel()
        historySaveWork = nil
        saveHistory(synchronously: true)
    }

    private struct HistoryPersistenceResult: Sendable {
        let originalItems: [ClipboardItem]
        let storedItems: [ClipboardItem]
        let errorDescription: String?
    }

    private func saveHistory(synchronously: Bool = false) {
        historySaveWork?.cancel()
        historySaveWork = nil
        guard historyPersistenceIsWritable else { return }
        compactHistoryForStorage()
        historySaveGeneration += 1
        let generation = historySaveGeneration
        let snapshot = items
        let persist = { () -> HistoryPersistenceResult in
            let interval = PerformanceTrace.begin("History Persistence")
            defer { PerformanceTrace.end(interval) }
            do {
                let storedItems = snapshot.map { $0.storingPayloadsOnDisk() }
                let data = try JSONEncoder().encode(storedItems)
                let encrypted = try SecurePayloadCrypto.shared.seal(
                    data,
                    purpose: "history-manifest"
                )
                UserDefaults.standard.set(encrypted, forKey: "secureClipboardHistoryV2")
                return HistoryPersistenceResult(
                    originalItems: snapshot,
                    storedItems: storedItems,
                    errorDescription: nil
                )
            } catch {
                return HistoryPersistenceResult(
                    originalItems: snapshot,
                    storedItems: snapshot,
                    errorDescription: error.localizedDescription
                )
            }
        }
        let applyResult = { [weak self] (result: HistoryPersistenceResult) in
            guard let self else { return }
            if let errorDescription = result.errorDescription {
                self.historyStorageError = errorDescription
                DiagnosticLog.shared.record(DiagnosticLogEvent(
                    .storageFailed,
                    level: .error,
                    fields: [
                        DiagnosticLogField(.operation, "saveHistoryManifest"),
                        DiagnosticLogField(.reason, errorDescription),
                    ]
                ))
                return
            }
            // Do not replace a row that was edited or had its source refreshed
            // while this generation was being encrypted.
            for (original, stored) in zip(result.originalItems, result.storedItems) {
                guard let index = self.items.firstIndex(where: { $0.id == original.id }),
                      self.items[index] == original else { continue }
                self.items[index] = stored
            }
            if self.historySaveGeneration == generation {
                self.persistedItemIDs = Set(result.storedItems.map(\.id))
                self.historyStorageError = nil
            }
        }

        if synchronously {
            let result = historyPersistenceQueue.sync(execute: persist)
            applyResult(result)
        } else {
            historyPersistenceQueue.async {
                let result = persist()
                DispatchQueue.main.async { applyResult(result) }
            }
        }
    }

    private func loadHistory() {
        guard let encrypted = UserDefaults.standard.data(forKey: "secureClipboardHistoryV2") else { return }
        let saved: [ClipboardItem]
        do {
            let data = try SecurePayloadCrypto.shared.open(
                encrypted,
                purpose: "history-manifest"
            )
            saved = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            historyPersistenceIsWritable = false
            historyStorageError = error.localizedDescription
            return
        }
        let maxItems = AppSettings.shared.historyDepth
        let limitedItems = Array(saved.prefix(maxItems))
        let migratedItems = limitedItems.map { $0.storingPayloadsOnDisk() }
        let compactedItems = compactedHistory(migratedItems)
        items = compactedItems
        persistedItemIDs = Set(items.map(\.id))
        ClipboardItem.pruneImageCache(keeping: Set(items.map(\.id)))
        HistoryPayloadStore.prune(keeping: Set(items.flatMap { $0.payloadFileNames }))

        if compactedItems != limitedItems || migratedItems != limitedItems || saved.count > maxItems {
            saveHistory(synchronously: true)
        }
    }

    func storageDescription(for item: ClipboardItem) -> String {
        if let historyStorageError {
            return "History manifest unavailable — \(historyStorageError)"
        }
        guard persistedItemIDs.contains(item.id) else {
            return item.payloadFileNames.isEmpty
                ? "Memory only — manifest not committed"
                : "Encrypted payload staged — manifest not committed"
        }
        return item.payloadFileNames.isEmpty
            ? "Encrypted history manifest"
            : "Encrypted history manifest + \(item.payloadFileNames.count) encrypted payload file(s)"
    }

    private func compactHistoryForStorage() {
        let compactedItems = compactedHistory(items)
        if compactedItems != items {
            items = compactedItems
        }
        ClipboardItem.pruneImageCache(keeping: Set(items.map(\.id)))
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
