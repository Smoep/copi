import AppKit
import Foundation
import Observation

// MARK: - Public event vocabulary

/// Broad streams used to filter Copi's newline-delimited diagnostic log.
enum DiagnosticLogCategory: String, Codable, Sendable {
    case lifecycle
    case configuration
    case clipboard
    case accessibility
    case context
    case overlay
    case suggestion
    case selection
    case paste
    case storage
    case security
}

enum DiagnosticLogLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
}

/// Event names are deliberately closed rather than caller-provided strings. This
/// keeps the log searchable and avoids accidentally using the event name as a
/// place to interpolate clipboard contents.
enum DiagnosticLogEventName: String, Codable, Sendable {
    case applicationLaunched
    case applicationWillTerminate
    case configurationChanged
    case permissionChecked
    case clipboardChangeDetected
    case clipboardCaptureCompleted
    case clipboardCaptureDropped
    case sourceCopyLearned
    case accessibilitySnapshot
    case accessibilityTimedOut
    case contextClassified
    case overlayOpened
    case overlayClosed
    case hoverTargetChanged
    case hoverScopeCommitted
    case hoverResultsMaterialized
    case hoverPreviewMaterialized
    case overlayLayoutSlow
    case mainThreadStallDetected
    case hoverDiagnosticSummary
    case candidatesRanked
    case candidateScored
    case selectionCommitted
    case pasteStarted
    case pasteCompleted
    case pasteFailed
    case pasteboardRestored
    case storageRead
    case storageWrite
    case storagePruned
    case storageFailed
    case encryptionCompleted
    case encryptionFailed
    case favoriteChanged
    case contentTypeOverridden

    var category: DiagnosticLogCategory {
        switch self {
        case .applicationLaunched, .applicationWillTerminate:
            return .lifecycle
        case .configurationChanged, .permissionChecked:
            return .configuration
        case .clipboardChangeDetected, .clipboardCaptureCompleted, .clipboardCaptureDropped:
            return .clipboard
        case .accessibilitySnapshot, .accessibilityTimedOut:
            return .accessibility
        case .contextClassified:
            return .context
        case .overlayOpened, .overlayClosed, .hoverTargetChanged,
             .hoverScopeCommitted, .hoverResultsMaterialized, .hoverPreviewMaterialized,
             .overlayLayoutSlow,
             .mainThreadStallDetected, .hoverDiagnosticSummary:
            return .overlay
        case .candidatesRanked, .candidateScored, .sourceCopyLearned:
            return .suggestion
        case .selectionCommitted:
            return .selection
        case .pasteStarted, .pasteCompleted, .pasteFailed, .pasteboardRestored:
            return .paste
        case .storageRead, .storageWrite, .storagePruned, .storageFailed:
            return .storage
        case .encryptionCompleted, .encryptionFailed:
            return .security
        case .favoriteChanged, .contentTypeOverridden:
            return .configuration
        }
    }
}

/// Stable IDs that allow a capture, overlay session, score and paste to be joined
/// without putting the clipboard payload itself in the log.
struct DiagnosticLogCorrelation: Codable, Sendable {
    var overlaySessionID: UUID?
    var contextSnapshotID: UUID?
    var captureID: UUID?
    var clipboardItemID: UUID?
    var favoriteID: UUID?
    var candidateID: UUID?
    var pasteOperationID: UUID?

    init(
        overlaySessionID: UUID? = nil,
        contextSnapshotID: UUID? = nil,
        captureID: UUID? = nil,
        clipboardItemID: UUID? = nil,
        favoriteID: UUID? = nil,
        candidateID: UUID? = nil,
        pasteOperationID: UUID? = nil
    ) {
        self.overlaySessionID = overlaySessionID
        self.contextSnapshotID = contextSnapshotID
        self.captureID = captureID
        self.clipboardItemID = clipboardItemID
        self.favoriteID = favoriteID
        self.candidateID = candidateID
        self.pasteOperationID = pasteOperationID
    }
}

private enum DiagnosticLogBounds {
    static let maximumFieldsPerEvent = 64
    static let maximumFieldScalars = 512
    static let maximumStatusErrorScalars = 400
    static let maximumEncodedEventBytes = 64 * 1024
}

/// Allow-listed metadata keys. There is intentionally no generic `message`,
/// `content`, `value`, or `password` key. Values are flattened to one line and
/// bounded before they can reach the writer.
struct DiagnosticLogField: Codable, Sendable {
    enum Key: String, Codable, Sendable {
        case enabled
        case operation
        case outcome
        case reason
        case errorDomain
        case errorCode
        case durationMilliseconds
        case appName
        case bundleIdentifier
        case appVersion
        case processIdentifier
        case sourceAppName
        case sourceBundleIdentifier
        case sourceSurface
        case sourceFocusedArea
        case sourceClassifier
        case sourceAccessibility
        case sourceContextCaptureMilliseconds
        case destinationAppName
        case destinationBundleIdentifier
        case windowRole
        case windowSubrole
        case windowTitle
        case controlRole
        case controlSubrole
        case controlIdentifier
        case controlTitle
        case controlDescription
        case controlPlaceholder
        case ancestry
        case nearbyLabels
        case normalizedHost
        case semanticContext
        case classifier
        case contextConfidence
        case permissionState
        case changeCount
        case itemCount
        case representationCount
        case uniformTypeIdentifier
        case payloadType
        case byteCount
        case totalByteCount
        case captureDecision
        case dropReason
        case detectedKind
        case overrideKind
        case effectiveKind
        case scope
        case previousScope
        case queryState
        case rankingMode
        case candidateSource
        case promotionBasis
        case contextFit
        case affinityRule
        case ruleVersion
        case selectionMethod
        case copyCount
        case contextualCount
        case surfaceCount
        case applicationCount
        case globalCount
        case exactDispatchCount
        case surfaceDispatchCount
        case applicationDispatchCount
        case globalDispatchCount
        case exactSelectionOnlyCount
        case surfaceSelectionOnlyCount
        case applicationSelectionOnlyCount
        case globalSelectionOnlyCount
        case exactEffectiveCount
        case surfaceEffectiveCount
        case applicationEffectiveCount
        case globalEffectiveCount
        case destinationSubtotal
        case sourcePopularityBonus
        case favoriteBonus
        case semanticAffinityBonus
        case eligibility
        case scoreReferenceTime
        case score
        case feature
        case inclusionReason
        case exclusionReason
        case payloadDigest
        case envelopeVersion
        case encryptionStatus
        case keyAvailability
        case pasteboardRestoration
        case fileName
        case fileCount
        case fileBytes
        case rotationReason
        case pointerEventCount
        case targetTransitionCount
        case scopeCommitCount
        case resultCount
        case previewCount
        case layoutPassCount
        case slowLayoutPassCount
        case maximumLayoutMilliseconds
        case mainQueueDelayMilliseconds
    }

    let key: Key
    let value: String

    init(_ key: Key, _ metadataValue: String) {
        self.key = key
        value = boundedDiagnosticString(
            metadataValue,
            maximumScalars: DiagnosticLogBounds.maximumFieldScalars
        )
    }

    init(_ key: Key, integer: Int) {
        self.init(key, String(integer))
    }

    init(_ key: Key, integer: Int64) {
        self.init(key, String(integer))
    }

    init(_ key: Key, double: Double) {
        self.init(key, String(double))
    }

    init(_ key: Key, boolean: Bool) {
        self.init(key, boolean ? "true" : "false")
    }
}

/// A pending event. The process/session IDs and timestamp are added only after
/// the logger's enabled gate accepts it.
struct DiagnosticLogEvent: Sendable {
    let name: DiagnosticLogEventName
    let level: DiagnosticLogLevel
    let correlation: DiagnosticLogCorrelation
    let fields: [DiagnosticLogField]
    fileprivate let fieldsWereTruncated: Bool

    init(
        _ name: DiagnosticLogEventName,
        level: DiagnosticLogLevel = .info,
        correlation: DiagnosticLogCorrelation = DiagnosticLogCorrelation(),
        fields: [DiagnosticLogField] = []
    ) {
        self.name = name
        self.level = level
        self.correlation = correlation
        fieldsWereTruncated = fields.count > DiagnosticLogBounds.maximumFieldsPerEvent
        self.fields = Array(fields.prefix(DiagnosticLogBounds.maximumFieldsPerEvent))
    }
}

// MARK: - Observable status

/// UI-facing state. The writer publishes mutations on the main queue.
@Observable
final class DiagnosticLogStatus {
    fileprivate(set) var isEnabled = false
    fileprivate(set) var fileCount = 0
    fileprivate(set) var totalBytes: Int64 = 0
    fileprivate(set) var lastUpdated: Date?
    fileprivate(set) var isClearing = false
    fileprivate(set) var lastError: String?
}

// MARK: - JSONL writer

/// A small custom JSONL logger rather than Unified Logging: users can reveal and
/// clear these files, and each diagnostic event remains machine-readable.
///
/// Construct events inline when calling `record`. Its autoclosure is not evaluated
/// while logging is disabled, so the normal clipboard polling path pays only for
/// a short lock-protected Boolean check.
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    static let maximumFileBytes: Int64 = 10 * 1024 * 1024
    static let maximumRetainedBytes: Int64 = 50 * 1024 * 1024

    let status = DiagnosticLogStatus()

    var directoryURL: URL? {
        try? Self.logsDirectoryURL()
    }

    /// Cheap gate for performance probes that should be completely dormant when
    /// the user has not enabled diagnostic logging.
    var isEnabled: Bool {
        currentEnabledState()
    }

    private struct GateState {
        var enabled = false
        var generation: UInt64 = 0
    }

    private struct StoredEvent: Encodable {
        let schemaVersion: Int
        let eventID: UUID
        let processSessionID: UUID
        let processIdentifier: Int32
        let timestamp: Date
        let category: DiagnosticLogCategory
        let name: DiagnosticLogEventName
        let level: DiagnosticLogLevel
        let correlation: DiagnosticLogCorrelation
        let fields: [DiagnosticLogField]
        let fieldsWereTruncated: Bool
    }

    private struct ManagedFile {
        let url: URL
        let byteCount: Int64
        let modifiedAt: Date
    }

    private enum WriterError: LocalizedError {
        case applicationSupportUnavailable
        case encodedEventTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "The Application Support directory is unavailable."
            case .encodedEventTooLarge(let byteCount):
                return "A diagnostic event was dropped because it encoded to \(byteCount) bytes."
            }
        }
    }

    private let writerQueue = DispatchQueue(
        label: "com.jos.copi.diagnostic-log",
        qos: .utility
    )
    private let writerQueueKey = DispatchSpecificKey<UInt8>()
    private let gateLock = NSLock()
    private var gate = GateState()

    private let processSessionID = UUID()
    private let encoder: JSONEncoder
    private let fileNameDateFormatter: DateFormatter

    // Accessed only on writerQueue.
    private var currentFileURL: URL?
    private var currentFileHandle: FileHandle?
    private var currentFileBytes: Int64 = 0
    private var knownFileCount = 0
    private var knownTotalBytes: Int64 = 0
    private var knownLastUpdated: Date?
    private var writerIsClearing = false
    private var writerLastError: String?
    private var diskStateWasLoaded = false

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        fileNameDateFormatter = formatter

        writerQueue.setSpecific(key: writerQueueKey, value: 1)
    }

    /// Enables or disables future events immediately. Disabling also closes the
    /// active handle after already-enqueued writer work reaches the serial queue.
    func configure(enabled: Bool) {
        let generation: UInt64 = withGateLock {
            if gate.enabled != enabled {
                gate.enabled = enabled
                gate.generation &+= 1
            }
            return gate.generation
        }

        publishEnabledImmediately(enabled)
        writerQueue.async { [weak self] in
            guard let self else { return }
            guard self.gateMatches(enabled: enabled, generation: generation) else { return }

            do {
                if enabled {
                    _ = try self.ensureLogsDirectory()
                } else {
                    self.closeCurrentFile(synchronize: true)
                }
                try self.reloadDiskState()
                try self.enforceRetentionLimit()
                self.writerLastError = nil
            } catch {
                self.setWriterError(error)
            }
            self.publishStatus()
        }
    }

    /// Records a typed event. Keep the event expression inline so this autoclosure
    /// can avoid building fields or snapshots while diagnostics are disabled.
    func record(_ event: @autoclosure () -> DiagnosticLogEvent) {
        guard let generation = acceptedGeneration() else { return }
        let acceptedAt = Date()
        let pending = event()

        writerQueue.async { [weak self] in
            guard let self,
                  self.gateMatches(enabled: true, generation: generation) else { return }
            self.write(pending, acceptedAt: acceptedAt)
        }
    }

    /// Removes only Copi-managed JSONL files. The active file remains closed until
    /// another event arrives, so a successful clear can genuinely report zero.
    func clear() {
        DispatchQueue.main.async { [weak status] in
            status?.isClearing = true
            status?.lastError = nil
        }

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.writerIsClearing = true
            self.closeCurrentFile(synchronize: true)

            do {
                let files = try self.managedLogFiles()
                var firstFailure: Error?
                for file in files {
                    do {
                        try FileManager.default.removeItem(at: file.url)
                    } catch {
                        if firstFailure == nil { firstFailure = error }
                    }
                }
                try self.reloadDiskState()
                if let firstFailure {
                    self.setWriterError(firstFailure)
                } else {
                    self.writerLastError = nil
                }
            } catch {
                self.setWriterError(error)
            }

            self.writerIsClearing = false
            self.publishStatus()
        }
    }

    /// Creates the directory when needed, then opens it in Finder on the main queue.
    func reveal() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                let directory = try self.ensureLogsDirectory()
                try self.reloadDiskState()
                self.writerLastError = nil
                self.publishStatus()
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(directory)
                }
            } catch {
                self.setWriterError(error)
                self.publishStatus()
            }
        }
    }

    /// Re-reads sizes and dates so Settings can refresh after external file changes.
    func refresh() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.reloadDiskState()
                try self.enforceRetentionLimit()
                self.writerLastError = nil
            } catch {
                self.setWriterError(error)
            }
            self.publishStatus()
        }
    }

    /// Waits for prior writes and asks the active file handle to synchronize.
    func flush() {
        performWriterSync {
            do {
                try currentFileHandle?.synchronize()
                writerLastError = nil
            } catch {
                setWriterError(error)
            }
            publishStatus()
        }
    }

    /// Useful during application termination or tests that need the file closed.
    func flushAndClose() {
        performWriterSync {
            closeCurrentFile(synchronize: true)
            publishStatus()
        }
    }

    // MARK: Event writing

    private func write(_ event: DiagnosticLogEvent, acceptedAt: Date) {
        do {
            if !diskStateWasLoaded { try reloadDiskState() }

            let stored = StoredEvent(
                schemaVersion: 1,
                eventID: UUID(),
                processSessionID: processSessionID,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                timestamp: acceptedAt,
                category: event.name.category,
                name: event.name,
                level: event.level,
                correlation: event.correlation,
                fields: event.fields,
                fieldsWereTruncated: event.fieldsWereTruncated
            )
            var line = try encoder.encode(stored)
            line.append(0x0A)
            guard line.count <= DiagnosticLogBounds.maximumEncodedEventBytes else {
                throw WriterError.encodedEventTooLarge(line.count)
            }

            try rotateIfNeeded(forIncomingByteCount: Int64(line.count))
            let handle = try writableFileHandle()
            try handle.write(contentsOf: line)
            currentFileBytes += Int64(line.count)
            knownTotalBytes += Int64(line.count)
            knownLastUpdated = acceptedAt
            writerLastError = nil

            try enforceRetentionLimit()
        } catch {
            setWriterError(error)
            closeCurrentFile(synchronize: false)
            // Re-scan before the next event; a failed append or close can make the
            // in-memory byte totals inaccurate.
            diskStateWasLoaded = false
        }
        publishStatus()
    }

    private func rotateIfNeeded(forIncomingByteCount incomingBytes: Int64) throws {
        guard currentFileHandle != nil,
              currentFileBytes > 0,
              currentFileBytes + incomingBytes > Self.maximumFileBytes else { return }
        closeCurrentFile(synchronize: true)
    }

    private func writableFileHandle() throws -> FileHandle {
        if let currentFileHandle { return currentFileHandle }

        let directory = try ensureLogsDirectory()
        let timestamp = fileNameDateFormatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let fileName = "copi-debug-\(timestamp)-\(suffix).jsonl"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            // The log can contain window/control metadata. If its promised private
            // permissions cannot be applied, fail closed before writing an event.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let handle = try FileHandle(forWritingTo: url)
        currentFileURL = url
        currentFileHandle = handle
        currentFileBytes = 0
        knownFileCount += 1
        return handle
    }

    private func closeCurrentFile(synchronize: Bool) {
        guard let handle = currentFileHandle else {
            currentFileURL = nil
            currentFileBytes = 0
            return
        }
        if synchronize {
            do {
                try handle.synchronize()
            } catch {
                setWriterError(error)
            }
        }
        do {
            try handle.close()
        } catch {
            setWriterError(error)
        }
        currentFileHandle = nil
        currentFileURL = nil
        currentFileBytes = 0
    }

    // MARK: Files and retention

    private static func logsDirectoryURL() throws -> URL {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WriterError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("Copi", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
    }

    @discardableResult
    private func ensureLogsDirectory() throws -> URL {
        let directory = try Self.logsDirectoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func managedLogFiles() throws -> [ManagedFile] {
        let directory = try Self.logsDirectoryURL()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("copi-debug-"), url.pathExtension == "jsonl" else { return nil }
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile != false else { return nil }
            return ManagedFile(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
    }

    private func reloadDiskState() throws {
        let files = try managedLogFiles()
        if let currentFileURL {
            let diskFile = files.first(where: { $0.url == currentFileURL })
            if diskFile == nil || diskFile?.byteCount != currentFileBytes {
                // Finder may delete, truncate, or replace the active path while
                // its old inode remains open. Start a fresh managed file instead
                // of continuing to write invisibly or with incorrect accounting.
                closeCurrentFile(synchronize: true)
            }
        }
        knownFileCount = files.count
        knownTotalBytes = files.reduce(0) { $0 + $1.byteCount }
        knownLastUpdated = files.map(\.modifiedAt).max()
        if let currentFileURL,
           let current = files.first(where: { $0.url == currentFileURL }) {
            currentFileBytes = current.byteCount
        }
        diskStateWasLoaded = true
    }

    private func enforceRetentionLimit() throws {
        guard knownTotalBytes > Self.maximumRetainedBytes else { return }
        let files = try managedLogFiles().sorted {
            if $0.modifiedAt == $1.modifiedAt {
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            return $0.modifiedAt < $1.modifiedAt
        }

        for file in files {
            guard knownTotalBytes > Self.maximumRetainedBytes else { break }
            guard file.url != currentFileURL else { continue }
            try FileManager.default.removeItem(at: file.url)
            knownFileCount = max(0, knownFileCount - 1)
            knownTotalBytes = max(0, knownTotalBytes - file.byteCount)
        }

        // Deletion may have removed the newest closed file in a clock-skewed
        // directory, so recompute the displayed timestamp from what remains.
        let remaining = try managedLogFiles()
        knownFileCount = remaining.count
        knownTotalBytes = remaining.reduce(0) { $0 + $1.byteCount }
        knownLastUpdated = remaining.map(\.modifiedAt).max()
    }

    // MARK: State publication and synchronization

    private func acceptedGeneration() -> UInt64? {
        withGateLock { gate.enabled ? gate.generation : nil }
    }

    private func gateMatches(enabled: Bool, generation: UInt64) -> Bool {
        withGateLock { gate.enabled == enabled && gate.generation == generation }
    }

    private func currentEnabledState() -> Bool {
        withGateLock { gate.enabled }
    }

    private func withGateLock<T>(_ body: () -> T) -> T {
        gateLock.lock()
        defer { gateLock.unlock() }
        return body()
    }

    private func publishEnabledImmediately(_ enabled: Bool) {
        DispatchQueue.main.async { [weak status] in
            status?.isEnabled = enabled
        }
    }

    private func publishStatus() {
        let enabled = currentEnabledState()
        let fileCount = knownFileCount
        let totalBytes = knownTotalBytes
        let lastUpdated = knownLastUpdated
        let isClearing = writerIsClearing
        let lastError = writerLastError

        DispatchQueue.main.async { [weak status] in
            guard let status else { return }
            status.isEnabled = enabled
            status.fileCount = fileCount
            status.totalBytes = totalBytes
            status.lastUpdated = lastUpdated
            status.isClearing = isClearing
            status.lastError = lastError
        }
    }

    private func setWriterError(_ error: Error) {
        writerLastError = boundedDiagnosticString(
            error.localizedDescription,
            maximumScalars: DiagnosticLogBounds.maximumStatusErrorScalars
        )
    }

    private func performWriterSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: writerQueueKey) != nil {
            work()
        } else {
            writerQueue.sync(execute: work)
        }
    }
}

/// Produces a bounded, single-line metadata value without first copying an
/// unbounded source string. Control characters become spaces; when truncated,
/// the last scalar is an ellipsis.
private func boundedDiagnosticString(_ value: String, maximumScalars: Int) -> String {
    guard maximumScalars > 0 else { return "" }
    let space = UnicodeScalar(32)!
    let ellipsis = UnicodeScalar(0x2026)!
    var output = String.UnicodeScalarView()
    output.reserveCapacity(maximumScalars)

    var iterator = value.unicodeScalars.makeIterator()
    var count = 0
    while count < maximumScalars, let scalar = iterator.next() {
        output.append(CharacterSet.controlCharacters.contains(scalar) ? space : scalar)
        count += 1
    }

    if iterator.next() != nil, !output.isEmpty {
        output.removeLast()
        output.append(ellipsis)
    }
    return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
}
