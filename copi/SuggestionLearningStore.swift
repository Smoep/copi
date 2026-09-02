import Foundation
import SQLite3

/// Stable, privacy-safe identifiers describing where the overlay was opened.
///
/// The caller owns normalization. In particular, these values should be semantic
/// keys such as a bundle identifier, `compose`, and `recipient-field`, rather
/// than raw window titles, URLs, or focused-control contents.
nonisolated struct SuggestionLearningContext: Codable, Hashable, Sendable {
    let appKey: String
    let surfaceKey: String
    let contextKey: String
    let confidence: Double
    let appMatchable: Bool
    let surfaceMatchable: Bool
    let exactMatchable: Bool

    init(
        appKey: String,
        surfaceKey: String,
        contextKey: String,
        confidence: Double = 0.60,
        appMatchable: Bool = true,
        surfaceMatchable: Bool = true,
        exactMatchable: Bool = true
    ) {
        self.appKey = appKey
        self.surfaceKey = surfaceKey
        self.contextKey = contextKey
        self.confidence = min(1, max(0, confidence))
        self.appMatchable = appMatchable
        self.surfaceMatchable = surfaceMatchable
        self.exactMatchable = exactMatchable
    }

    var rankingContext: SuggestionRankingContext {
        SuggestionRankingContext(
            appKey: appKey,
            surfaceKey: surfaceKey,
            exactKey: contextKey,
            confidence: confidence,
            appMatchable: appMatchable,
            surfaceMatchable: surfaceMatchable,
            exactMatchable: exactMatchable
        )
    }
}

nonisolated struct SuggestionRankingEvidence: Sendable {
    let destinationEvents: [SuggestionDestinationUseEvent]
    let sourceCopies: [SuggestionSourceCopyEvidence]
}

/// One candidate displayed during an overlay session.
///
/// Candidate keys must remain stable across captures. Both history and Favorites
/// use the same keyed content digest so learning follows the payload; `sourceKey`
/// separately records whether the impression came from history or a category.
nonisolated struct SuggestionLearningImpression: Codable, Hashable, Sendable {
    let candidateKey: String
    let sourceKey: String
    let position: Int
    let score: Double?

    init(candidateKey: String, sourceKey: String, position: Int, score: Double? = nil) {
        self.candidateKey = candidateKey
        self.sourceKey = sourceKey
        self.position = position
        self.score = score
    }
}

/// The four increasingly broad levels maintained for every candidate.
nonisolated enum SuggestionLearningLevel: Int, Codable, CaseIterable, Sendable {
    case exact = 0
    case surface = 1
    case application = 2
    case global = 3
}

nonisolated struct SuggestionLearningUsage: Codable, Hashable, Sendable {
    var impressionCount: Int
    var selectionCount: Int
    var copyCount: Int
    var lastImpressedAt: Date?
    var lastSelectedAt: Date?
    var lastCopiedAt: Date?

    static let zero = SuggestionLearningUsage(
        impressionCount: 0,
        selectionCount: 0,
        copyCount: 0,
        lastImpressedAt: nil,
        lastSelectedAt: nil,
        lastCopiedAt: nil
    )

    var interactionCount: Int { selectionCount + copyCount }

    var selectionRate: Double {
        guard impressionCount > 0 else { return 0 }
        return Double(selectionCount) / Double(impressionCount)
    }
}

nonisolated struct SuggestionLearningCandidateUsage: Codable, Hashable, Sendable {
    let candidateKey: String
    var exact: SuggestionLearningUsage
    var surface: SuggestionLearningUsage
    var application: SuggestionLearningUsage
    var global: SuggestionLearningUsage

    init(candidateKey: String) {
        self.candidateKey = candidateKey
        exact = .zero
        surface = .zero
        application = .zero
        global = .zero
    }

    subscript(level: SuggestionLearningLevel) -> SuggestionLearningUsage {
        get {
            switch level {
            case .exact: exact
            case .surface: surface
            case .application: application
            case .global: global
            }
        }
        set {
            switch level {
            case .exact: exact = newValue
            case .surface: surface = newValue
            case .application: application = newValue
            case .global: global = newValue
            }
        }
    }
}

/// One compact aggregate row used to warm the in-memory ranking cache. It
/// contains only stable content/context keys and counters; clipboard payloads
/// never leave encrypted history storage.
nonisolated struct SuggestionLearningAggregateRow: Sendable {
    let candidateKey: String
    let level: SuggestionLearningLevel
    let appKey: String
    let surfaceKey: String
    let contextKey: String
    let usage: SuggestionLearningUsage
}

nonisolated enum SuggestionLearningStoreError: LocalizedError, Sendable {
    case cannotCreateDirectory(String)
    case cannotOpenDatabase(code: Int32, message: String)
    case sqlite(operation: String, code: Int32, message: String)
    case unsupportedSchemaVersion(Int)
    case walUnavailable(String)
    case invalidKey(label: String, reason: String)
    case invalidImpression(String)
    case duplicateCandidateKey(String)
    case duplicatePosition(Int)
    case unknownSession(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            "Could not create the suggestion-learning directory at \(path)."
        case .cannotOpenDatabase(let code, let message):
            "Could not open the suggestion-learning database (\(code)): \(message)"
        case .sqlite(let operation, let code, let message):
            "SQLite failed while \(operation) (\(code)): \(message)"
        case .unsupportedSchemaVersion(let version):
            "Suggestion-learning database version \(version) is newer than this app supports."
        case .walUnavailable(let mode):
            "Suggestion-learning storage requires WAL journaling, but SQLite selected \(mode)."
        case .invalidKey(let label, let reason):
            "Invalid \(label): \(reason)"
        case .invalidImpression(let reason):
            "Invalid suggestion impression: \(reason)"
        case .duplicateCandidateKey(let key):
            "The candidate key \(key) appears more than once in one impression batch."
        case .duplicatePosition(let position):
            "The impression position \(position) appears more than once in one batch."
        case .unknownSession(let id):
            "No suggestion-learning session exists with id \(id)."
        }
    }
}

/// SQLite persistence for suggestion impressions and selections.
///
/// Actor isolation gives the SQLite connection a single executor. A caller on
/// the main actor can safely use `await` without running database work on the UI
/// actor, and callers never receive SQLite-owned pointers or mutable state.
actor SuggestionLearningStore {
    private static let schemaVersion = 3
    private static let globalScopeKey = ""
    private static let maximumKeyBytes = 2_048

    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SuggestionLearningStoreError.cannotCreateDirectory(directory.path)
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let openCode = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)
        guard openCode == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite did not provide an error message"
            if let connection { sqlite3_close_v2(connection) }
            throw SuggestionLearningStoreError.cannotOpenDatabase(
                code: openCode,
                message: message
            )
        }

        database = connection
        do {
            try Self.configureDatabase(connection)
            try Self.installSchema(connection)
        } catch {
            sqlite3_close_v2(connection)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    /// Creates a session and records its first visible suggestion set atomically.
    /// The returned UUID string is suitable for correlation in diagnostics.
    @discardableResult
    func beginSession(
        id requestedSessionID: String? = nil,
        context: SuggestionLearningContext,
        impressions: [SuggestionLearningImpression] = [],
        startedAt: Date = Date()
    ) throws -> String {
        try validate(context: context)
        try validate(impressions: impressions)
        try validate(date: startedAt, label: "session start time")

        let sessionID = requestedSessionID ?? UUID().uuidString.lowercased()
        try Self.validateStableKey(sessionID, label: "session id")
        try inTransaction {
            try insertSession(id: sessionID, context: context, startedAt: startedAt)
            try insertImpressions(
                sessionID: sessionID,
                context: context,
                impressions: impressions,
                shownAt: startedAt
            )
        }
        return sessionID
    }

    /// Records candidates revealed after a session starts. A candidate is counted
    /// at most once per session, even if the UI asks to record the same set again.
    func recordImpressions(
        sessionID: String,
        impressions: [SuggestionLearningImpression],
        shownAt: Date = Date()
    ) throws {
        try Self.validateStableKey(sessionID, label: "session id")
        try validate(impressions: impressions)
        try validate(date: shownAt, label: "impression time")
        guard !impressions.isEmpty else { return }

        try inTransaction {
            let context = try contextForSession(id: sessionID)
            try insertImpressions(
                sessionID: sessionID,
                context: context,
                impressions: impressions,
                shownAt: shownAt
            )
        }
    }

    /// Records one chosen candidate. Duplicate calls for the same candidate and
    /// session are idempotent. A choice need not have been a suggestion: learning
    /// from a normal-list selection is useful for future suggestions too.
    func recordSelection(
        sessionID: String,
        candidateKey: String,
        selectedAt: Date = Date()
    ) throws {
        try Self.validateStableKey(sessionID, label: "session id")
        try Self.validateStableKey(candidateKey, label: "candidate key")
        try validate(date: selectedAt, label: "selection time")

        try inTransaction {
            let context = try contextForSession(id: sessionID)
            let inserted = try insertSelection(
                sessionID: sessionID,
                candidateKey: candidateKey,
                selectedAt: selectedAt
            )
            guard inserted else { return }

            try markImpressionSelected(
                sessionID: sessionID,
                candidateKey: candidateKey,
                selectedAt: selectedAt
            )
            try updateUsage(
                candidateKey: candidateKey,
                context: context,
                impressionDelta: 0,
                selectionDelta: 1,
                copyDelta: 0,
                eventDate: selectedAt
            )
        }
    }

    /// Upgrades previously recorded selections to dispatched-paste events. The
    /// update is idempotent and never creates a dispatch without a selection.
    func recordPasteDispatched(
        sessionID: String,
        candidateKeys: [String],
        dispatchedAt: Date = Date()
    ) throws {
        try Self.validateStableKey(sessionID, label: "session id")
        try validate(date: dispatchedAt, label: "paste dispatch time")
        let uniqueKeys = Array(Set(candidateKeys))
        guard !uniqueKeys.isEmpty else { return }
        for key in uniqueKeys {
            try Self.validateStableKey(key, label: "candidate key")
        }
        let sql = """
        UPDATE suggestion_selections
        SET dispatched_at = COALESCE(dispatched_at, ?)
        WHERE session_id = ? AND candidate_key = ?;
        """
        try inTransaction {
            for key in uniqueKeys {
                try withStatement(sql, operation: "recording a dispatched paste") { statement in
                    try bind(dispatchedAt, at: 1, in: statement)
                    try bind(sessionID, at: 2, in: statement)
                    try bind(key, at: 3, in: statement)
                    try stepDone(statement, operation: "recording a dispatched paste")
                }
            }
        }
    }

    /// Records an externally observed copy in the semantic context where it
    /// occurred. Unlike an overlay selection, this needs no presentation
    /// session: the pasteboard generation is the idempotency boundary.
    func recordSourceCopy(
        candidateKey: String,
        context: SuggestionLearningContext,
        copiedAt: Date = Date()
    ) throws {
        try Self.validateStableKey(candidateKey, label: "candidate key")
        try validate(context: context)
        try validate(date: copiedAt, label: "copy time")
        try inTransaction {
            try insertSourceCopy(candidateKey: candidateKey, copiedAt: copiedAt)
            try updateUsage(
                candidateKey: candidateKey,
                context: context,
                impressionDelta: 0,
                selectionDelta: 0,
                copyDelta: 1,
                eventDate: copiedAt
            )
        }
    }

    func endSession(id sessionID: String, endedAt: Date = Date()) throws {
        try Self.validateStableKey(sessionID, label: "session id")
        try validate(date: endedAt, label: "session end time")

        let sql = """
        UPDATE suggestion_sessions
        SET ended_at = COALESCE(ended_at, ?)
        WHERE id = ?;
        """
        try withStatement(sql, operation: "ending a suggestion session") { statement in
            try bind(endedAt, at: 1, in: statement)
            try bind(sessionID, at: 2, in: statement)
            try stepDone(statement, operation: "ending a suggestion session")
            guard sqlite3_changes(try connection()) > 0 else {
                throw SuggestionLearningStoreError.unknownSession(sessionID)
            }
        }
    }

    /// Returns all four usage levels for each requested candidate. Missing rows
    /// are returned as zero counts, so the result is immediately scoreable.
    func usageStatistics(
        for candidateKeys: [String],
        context: SuggestionLearningContext
    ) throws -> [String: SuggestionLearningCandidateUsage] {
        try validate(context: context)

        var uniqueKeys: [String] = []
        var seen = Set<String>()
        for key in candidateKeys {
            try Self.validateStableKey(key, label: "candidate key")
            if seen.insert(key).inserted { uniqueKeys.append(key) }
        }
        guard !uniqueKeys.isEmpty else { return [:] }

        let sql = """
        SELECT level, impression_count, selection_count, copy_count,
               last_impressed_at, last_selected_at, last_copied_at
        FROM suggestion_usage_stats
        WHERE candidate_key = ?
          AND (
            (level = 0 AND app_key = ? AND surface_key = ? AND context_key = ?)
            OR (level = 1 AND app_key = ? AND surface_key = ? AND context_key = '')
            OR (level = 2 AND app_key = ? AND surface_key = '' AND context_key = '')
            OR (level = 3 AND app_key = '' AND surface_key = '' AND context_key = '')
          );
        """

        var result = Dictionary(
            uniqueKeysWithValues: uniqueKeys.map {
                ($0, SuggestionLearningCandidateUsage(candidateKey: $0))
            }
        )

        try withStatement(sql, operation: "querying candidate usage") { statement in
            for candidateKey in uniqueKeys {
                defer { reset(statement) }
                try bind(candidateKey, at: 1, in: statement)
                try bind(context.appKey, at: 2, in: statement)
                try bind(context.surfaceKey, at: 3, in: statement)
                try bind(context.contextKey, at: 4, in: statement)
                try bind(context.appKey, at: 5, in: statement)
                try bind(context.surfaceKey, at: 6, in: statement)
                try bind(context.appKey, at: 7, in: statement)

                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else {
                        throw sqliteError(operation: "querying candidate usage", code: code)
                    }
                    guard let level = SuggestionLearningLevel(
                        rawValue: Int(sqlite3_column_int(statement, 0))
                    ) else { continue }

                    let usage = SuggestionLearningUsage(
                        impressionCount: Int(sqlite3_column_int64(statement, 1)),
                        selectionCount: Int(sqlite3_column_int64(statement, 2)),
                        copyCount: Int(sqlite3_column_int64(statement, 3)),
                        lastImpressedAt: dateColumn(statement, index: 4),
                        lastSelectedAt: dateColumn(statement, index: 5),
                        lastCopiedAt: dateColumn(statement, index: 6)
                    )
                    result[candidateKey]?[level] = usage
                }
            }
        }
        return result
    }

    /// Reads all aggregate rows for the supplied candidates in one pass. This
    /// is used off the main thread at startup so the first overlay opened in a
    /// previously learned context can rank immediately without waiting for a
    /// context-specific SQLite round trip.
    func aggregateRows(
        for candidateKeys: [String]
    ) throws -> [SuggestionLearningAggregateRow] {
        var uniqueKeys: [String] = []
        var seen = Set<String>()
        for key in candidateKeys {
            try Self.validateStableKey(key, label: "candidate key")
            if seen.insert(key).inserted { uniqueKeys.append(key) }
        }
        guard !uniqueKeys.isEmpty else { return [] }

        let sql = """
        SELECT level, app_key, surface_key, context_key,
               impression_count, selection_count, copy_count,
               last_impressed_at, last_selected_at, last_copied_at
        FROM suggestion_usage_stats
        WHERE candidate_key = ?;
        """
        var rows: [SuggestionLearningAggregateRow] = []
        try withStatement(sql, operation: "warming suggestion aggregates") { statement in
            for candidateKey in uniqueKeys {
                defer { reset(statement) }
                try bind(candidateKey, at: 1, in: statement)
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else {
                        throw sqliteError(operation: "warming suggestion aggregates", code: code)
                    }
                    guard let level = SuggestionLearningLevel(
                        rawValue: Int(sqlite3_column_int(statement, 0))
                    ) else { continue }
                    rows.append(SuggestionLearningAggregateRow(
                        candidateKey: candidateKey,
                        level: level,
                        appKey: textColumn(statement, index: 1),
                        surfaceKey: textColumn(statement, index: 2),
                        contextKey: textColumn(statement, index: 3),
                        usage: SuggestionLearningUsage(
                            impressionCount: Int(sqlite3_column_int64(statement, 4)),
                            selectionCount: Int(sqlite3_column_int64(statement, 5)),
                            copyCount: Int(sqlite3_column_int64(statement, 6)),
                            lastImpressedAt: dateColumn(statement, index: 7),
                            lastSelectedAt: dateColumn(statement, index: 8),
                            lastCopiedAt: dateColumn(statement, index: 9)
                        )
                    ))
                }
            }
        }
        return rows
    }

    /// Reads the detailed, bounded evidence needed by the destination-first
    /// scorer. No clipboard payload or source-control metadata is present here.
    func rankingEvidence(
        for candidateKeys: [String],
        since cutoff: Date
    ) throws -> SuggestionRankingEvidence {
        try validate(date: cutoff, label: "ranking evidence cutoff")
        var uniqueKeys: [String] = []
        var seen = Set<String>()
        for key in candidateKeys {
            try Self.validateStableKey(key, label: "candidate key")
            if seen.insert(key).inserted { uniqueKeys.append(key) }
        }
        guard !uniqueKeys.isEmpty else {
            return SuggestionRankingEvidence(destinationEvents: [], sourceCopies: [])
        }

        let destinationSQL = """
        SELECT s.session_id, s.candidate_key,
               x.app_key, x.surface_key, x.context_key,
               x.context_confidence, x.app_matchable,
               x.surface_matchable, x.exact_matchable,
               s.selected_at, s.dispatched_at
        FROM suggestion_selections AS s
        JOIN suggestion_sessions AS x ON x.id = s.session_id
        WHERE s.candidate_key = ?
          AND COALESCE(s.dispatched_at, s.selected_at) >= ?
        ORDER BY COALESCE(s.dispatched_at, s.selected_at) DESC;
        """
        var destinationEvents: [SuggestionDestinationUseEvent] = []
        try withStatement(destinationSQL, operation: "reading destination-use evidence") { statement in
            for candidateKey in uniqueKeys {
                defer { reset(statement) }
                try bind(candidateKey, at: 1, in: statement)
                try bind(cutoff, at: 2, in: statement)
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else {
                        throw sqliteError(operation: "reading destination-use evidence", code: code)
                    }
                    destinationEvents.append(SuggestionDestinationUseEvent(
                        sessionID: textColumn(statement, index: 0),
                        candidateKey: textColumn(statement, index: 1),
                        context: SuggestionRankingContext(
                            appKey: textColumn(statement, index: 2),
                            surfaceKey: textColumn(statement, index: 3),
                            exactKey: textColumn(statement, index: 4),
                            confidence: sqlite3_column_double(statement, 5),
                            appMatchable: sqlite3_column_int(statement, 6) != 0,
                            surfaceMatchable: sqlite3_column_int(statement, 7) != 0,
                            exactMatchable: sqlite3_column_int(statement, 8) != 0
                        ),
                        selectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                        dispatchedAt: dateColumn(statement, index: 10)
                    ))
                }
            }
        }

        let sourceSQL = """
        SELECT candidate_key, copied_at, event_count
        FROM suggestion_source_copy_events
        WHERE candidate_key = ? AND copied_at >= ?
        ORDER BY copied_at DESC;
        """
        var sourceCopies: [SuggestionSourceCopyEvidence] = []
        try withStatement(sourceSQL, operation: "reading source-copy evidence") { statement in
            for candidateKey in uniqueKeys {
                defer { reset(statement) }
                try bind(candidateKey, at: 1, in: statement)
                try bind(cutoff, at: 2, in: statement)
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW else {
                        throw sqliteError(operation: "reading source-copy evidence", code: code)
                    }
                    sourceCopies.append(SuggestionSourceCopyEvidence(
                        candidateKey: textColumn(statement, index: 0),
                        copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        count: Int(sqlite3_column_int64(statement, 2))
                    ))
                }
            }
        }
        return SuggestionRankingEvidence(
            destinationEvents: destinationEvents,
            sourceCopies: sourceCopies
        )
    }

    /// Removes detailed evidence outside the ranking window. Compact legacy
    /// aggregates remain available for diagnostics and migration auditing only.
    @discardableResult
    func pruneSessions(endedBefore cutoff: Date) throws -> Int {
        try validate(date: cutoff, label: "session prune cutoff")
        let sql = """
        DELETE FROM suggestion_sessions
        WHERE COALESCE(ended_at, started_at) < ?;
        """
        return try inTransaction {
            let removed = try withStatement(sql, operation: "pruning suggestion sessions") { statement in
                try bind(cutoff, at: 1, in: statement)
                try stepDone(statement, operation: "pruning suggestion sessions")
                return Int(sqlite3_changes(try connection()))
            }
            try withStatement(
                "DELETE FROM suggestion_source_copy_events WHERE copied_at < ?;",
                operation: "pruning source-copy evidence"
            ) { statement in
                try bind(cutoff, at: 1, in: statement)
                try stepDone(statement, operation: "pruning source-copy evidence")
            }
            return removed
        }
    }

    /// Clears both event history and learned aggregate counts.
    func clearAll() throws {
        try inTransaction {
            try execute("DELETE FROM suggestion_sessions;", operation: "clearing suggestion sessions")
            try execute("DELETE FROM suggestion_source_copy_events;", operation: "clearing source-copy evidence")
            try execute("DELETE FROM suggestion_usage_stats;", operation: "clearing suggestion usage")
        }
    }

    // MARK: - Database setup

    private nonisolated static func configureDatabase(_ database: OpaquePointer) throws {
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 2_500)
        try execute(
            "PRAGMA foreign_keys = ON;",
            on: database,
            operation: "enabling foreign keys"
        )
        try execute(
            "PRAGMA synchronous = NORMAL;",
            on: database,
            operation: "setting synchronous mode"
        )

        let mode = try pragmaText(
            "PRAGMA journal_mode = WAL;",
            on: database,
            operation: "enabling WAL"
        )
        guard mode.caseInsensitiveCompare("wal") == .orderedSame else {
            throw SuggestionLearningStoreError.walUnavailable(mode)
        }
    }

    private nonisolated static func installSchema(_ database: OpaquePointer) throws {
        let version = try pragmaInt(
            "PRAGMA user_version;",
            on: database,
            operation: "reading schema version"
        )
        guard version <= Self.schemaVersion else {
            throw SuggestionLearningStoreError.unsupportedSchemaVersion(version)
        }

        var installedVersion = version
        if installedVersion == 1 {
            try inTransaction(on: database) {
                try execute(
                    """
                    ALTER TABLE suggestion_usage_stats
                        ADD COLUMN copy_count INTEGER NOT NULL DEFAULT 0 CHECK(copy_count >= 0);
                    ALTER TABLE suggestion_usage_stats
                        ADD COLUMN last_copied_at REAL;
                    PRAGMA user_version = 2;
                    """,
                    on: database,
                    operation: "migrating copy-aware suggestion learning"
                )
            }
            installedVersion = 2
        }
        if installedVersion == 2 {
            try inTransaction(on: database) {
                try execute(
                    """
                    ALTER TABLE suggestion_sessions
                        ADD COLUMN context_confidence REAL NOT NULL DEFAULT 0.60
                        CHECK(context_confidence >= 0 AND context_confidence <= 1);
                    ALTER TABLE suggestion_sessions
                        ADD COLUMN app_matchable INTEGER NOT NULL DEFAULT 1
                        CHECK(app_matchable IN (0, 1));
                    ALTER TABLE suggestion_sessions
                        ADD COLUMN surface_matchable INTEGER NOT NULL DEFAULT 1
                        CHECK(surface_matchable IN (0, 1));
                    ALTER TABLE suggestion_sessions
                        ADD COLUMN exact_matchable INTEGER NOT NULL DEFAULT 1
                        CHECK(exact_matchable IN (0, 1));
                    ALTER TABLE suggestion_sessions
                        ADD COLUMN ranking_rule_version INTEGER NOT NULL DEFAULT 1;
                    ALTER TABLE suggestion_selections ADD COLUMN dispatched_at REAL;

                    CREATE TABLE suggestion_source_copy_events (
                        id            INTEGER PRIMARY KEY,
                        candidate_key TEXT NOT NULL,
                        copied_at     REAL NOT NULL,
                        event_count   INTEGER NOT NULL DEFAULT 1 CHECK(event_count > 0)
                    );
                    CREATE INDEX suggestion_source_copy_candidate_time
                        ON suggestion_source_copy_events(candidate_key, copied_at DESC);

                    INSERT INTO suggestion_source_copy_events(candidate_key, copied_at, event_count)
                    SELECT candidate_key, last_copied_at,
                           MIN(copy_count, 63)
                    FROM suggestion_usage_stats
                    WHERE level = 3 AND copy_count > 0 AND last_copied_at IS NOT NULL;

                    PRAGMA user_version = 3;
                    """,
                    on: database,
                    operation: "migrating destination-first suggestion learning"
                )
            }
            return
        }
        guard installedVersion == 0 else { return }
        try inTransaction(on: database) {
            try execute(
                """
                CREATE TABLE suggestion_sessions (
                    id          TEXT PRIMARY KEY NOT NULL,
                    started_at  REAL NOT NULL,
                    ended_at    REAL,
                    app_key     TEXT NOT NULL,
                    surface_key TEXT NOT NULL,
                    context_key TEXT NOT NULL,
                    context_confidence REAL NOT NULL CHECK(context_confidence >= 0 AND context_confidence <= 1),
                    app_matchable INTEGER NOT NULL CHECK(app_matchable IN (0, 1)),
                    surface_matchable INTEGER NOT NULL CHECK(surface_matchable IN (0, 1)),
                    exact_matchable INTEGER NOT NULL CHECK(exact_matchable IN (0, 1)),
                    ranking_rule_version INTEGER NOT NULL
                );

                CREATE TABLE suggestion_impressions (
                    id            INTEGER PRIMARY KEY,
                    session_id    TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
                    candidate_key TEXT NOT NULL,
                    source_key    TEXT NOT NULL,
                    position      INTEGER NOT NULL CHECK(position >= 0),
                    score         REAL,
                    shown_at      REAL NOT NULL,
                    selected_at   REAL,
                    UNIQUE(session_id, candidate_key),
                    UNIQUE(session_id, position)
                );

                CREATE TABLE suggestion_selections (
                    id            INTEGER PRIMARY KEY,
                    session_id    TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
                    candidate_key TEXT NOT NULL,
                    selected_at   REAL NOT NULL,
                    dispatched_at REAL,
                    position      INTEGER,
                    UNIQUE(session_id, candidate_key)
                );

                CREATE TABLE suggestion_usage_stats (
                    candidate_key    TEXT NOT NULL,
                    level            INTEGER NOT NULL CHECK(level BETWEEN 0 AND 3),
                    app_key          TEXT NOT NULL,
                    surface_key      TEXT NOT NULL,
                    context_key      TEXT NOT NULL,
                    impression_count INTEGER NOT NULL DEFAULT 0 CHECK(impression_count >= 0),
                    selection_count  INTEGER NOT NULL DEFAULT 0 CHECK(selection_count >= 0),
                    copy_count       INTEGER NOT NULL DEFAULT 0 CHECK(copy_count >= 0),
                    last_impressed_at REAL,
                    last_selected_at  REAL,
                    last_copied_at    REAL,
                    PRIMARY KEY(candidate_key, level, app_key, surface_key, context_key)
                ) WITHOUT ROWID;

                CREATE TABLE suggestion_source_copy_events (
                    id            INTEGER PRIMARY KEY,
                    candidate_key TEXT NOT NULL,
                    copied_at     REAL NOT NULL,
                    event_count   INTEGER NOT NULL DEFAULT 1 CHECK(event_count > 0)
                );

                CREATE INDEX suggestion_sessions_context_time
                    ON suggestion_sessions(app_key, surface_key, context_key, started_at DESC);
                CREATE INDEX suggestion_impressions_candidate_time
                    ON suggestion_impressions(candidate_key, shown_at DESC);
                CREATE INDEX suggestion_selections_candidate_time
                    ON suggestion_selections(candidate_key, selected_at DESC);
                CREATE INDEX suggestion_usage_scope
                    ON suggestion_usage_stats(level, app_key, surface_key, context_key, candidate_key);
                CREATE INDEX suggestion_source_copy_candidate_time
                    ON suggestion_source_copy_events(candidate_key, copied_at DESC);

                PRAGMA user_version = 3;
                """,
                on: database,
                operation: "creating suggestion-learning schema"
            )
        }
    }

    // MARK: - Writes

    private func insertSession(
        id: String,
        context: SuggestionLearningContext,
        startedAt: Date
    ) throws {
        let sql = """
        INSERT INTO suggestion_sessions(
            id, started_at, app_key, surface_key, context_key,
            context_confidence, app_matchable, surface_matchable, exact_matchable,
            ranking_rule_version
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql, operation: "starting a suggestion session") { statement in
            try bind(id, at: 1, in: statement)
            try bind(startedAt, at: 2, in: statement)
            try bind(context.appKey, at: 3, in: statement)
            try bind(context.surfaceKey, at: 4, in: statement)
            try bind(context.contextKey, at: 5, in: statement)
            try bind(context.confidence, at: 6, in: statement)
            try bind(context.appMatchable ? 1 : 0, at: 7, in: statement)
            try bind(context.surfaceMatchable ? 1 : 0, at: 8, in: statement)
            try bind(context.exactMatchable ? 1 : 0, at: 9, in: statement)
            try bind(SuggestionRankingRules.version, at: 10, in: statement)
            try stepDone(statement, operation: "starting a suggestion session")
        }
    }

    private func insertSourceCopy(candidateKey: String, copiedAt: Date) throws {
        let sql = """
        INSERT INTO suggestion_source_copy_events(candidate_key, copied_at, event_count)
        VALUES (?, ?, 1);
        """
        try withStatement(sql, operation: "recording source-copy evidence") { statement in
            try bind(candidateKey, at: 1, in: statement)
            try bind(copiedAt, at: 2, in: statement)
            try stepDone(statement, operation: "recording source-copy evidence")
        }
    }

    private func insertImpressions(
        sessionID: String,
        context: SuggestionLearningContext,
        impressions: [SuggestionLearningImpression],
        shownAt: Date
    ) throws {
        guard !impressions.isEmpty else { return }
        let sql = """
        INSERT OR IGNORE INTO suggestion_impressions(
            session_id, candidate_key, source_key, position, score, shown_at
        ) VALUES (?, ?, ?, ?, ?, ?);
        """

        try withStatement(sql, operation: "recording suggestion impressions") { statement in
            for impression in impressions {
                defer { reset(statement) }
                try bind(sessionID, at: 1, in: statement)
                try bind(impression.candidateKey, at: 2, in: statement)
                try bind(impression.sourceKey, at: 3, in: statement)
                try bind(impression.position, at: 4, in: statement)
                try bind(impression.score, at: 5, in: statement)
                try bind(shownAt, at: 6, in: statement)
                try stepDone(statement, operation: "recording suggestion impressions")

                // INSERT OR IGNORE makes repeated recording of a session idempotent.
                guard sqlite3_changes(try connection()) > 0 else { continue }
                try updateUsage(
                    candidateKey: impression.candidateKey,
                    context: context,
                    impressionDelta: 1,
                    selectionDelta: 0,
                    copyDelta: 0,
                    eventDate: shownAt
                )
            }
        }
    }

    private func insertSelection(
        sessionID: String,
        candidateKey: String,
        selectedAt: Date
    ) throws -> Bool {
        let sql = """
        INSERT OR IGNORE INTO suggestion_selections(
            session_id, candidate_key, selected_at, position
        ) VALUES (
            ?, ?, ?,
            (SELECT position
             FROM suggestion_impressions
             WHERE session_id = ? AND candidate_key = ?)
        );
        """
        return try withStatement(sql, operation: "recording a suggestion selection") { statement in
            try bind(sessionID, at: 1, in: statement)
            try bind(candidateKey, at: 2, in: statement)
            try bind(selectedAt, at: 3, in: statement)
            try bind(sessionID, at: 4, in: statement)
            try bind(candidateKey, at: 5, in: statement)
            try stepDone(statement, operation: "recording a suggestion selection")
            return sqlite3_changes(try connection()) > 0
        }
    }

    private func markImpressionSelected(
        sessionID: String,
        candidateKey: String,
        selectedAt: Date
    ) throws {
        let sql = """
        UPDATE suggestion_impressions
        SET selected_at = COALESCE(selected_at, ?)
        WHERE session_id = ? AND candidate_key = ?;
        """
        try withStatement(sql, operation: "marking a selected impression") { statement in
            try bind(selectedAt, at: 1, in: statement)
            try bind(sessionID, at: 2, in: statement)
            try bind(candidateKey, at: 3, in: statement)
            try stepDone(statement, operation: "marking a selected impression")
        }
    }

    private func updateUsage(
        candidateKey: String,
        context: SuggestionLearningContext,
        impressionDelta: Int,
        selectionDelta: Int,
        copyDelta: Int,
        eventDate: Date
    ) throws {
        let sql = """
        INSERT INTO suggestion_usage_stats(
            candidate_key, level, app_key, surface_key, context_key,
            impression_count, selection_count, copy_count,
            last_impressed_at, last_selected_at, last_copied_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(candidate_key, level, app_key, surface_key, context_key)
        DO UPDATE SET
            impression_count = impression_count + excluded.impression_count,
            selection_count = selection_count + excluded.selection_count,
            copy_count = copy_count + excluded.copy_count,
            last_impressed_at = CASE
                WHEN excluded.last_impressed_at IS NULL THEN last_impressed_at
                WHEN last_impressed_at IS NULL OR excluded.last_impressed_at > last_impressed_at
                    THEN excluded.last_impressed_at
                ELSE last_impressed_at
            END,
            last_selected_at = CASE
                WHEN excluded.last_selected_at IS NULL THEN last_selected_at
                WHEN last_selected_at IS NULL OR excluded.last_selected_at > last_selected_at
                    THEN excluded.last_selected_at
                ELSE last_selected_at
            END,
            last_copied_at = CASE
                WHEN excluded.last_copied_at IS NULL THEN last_copied_at
                WHEN last_copied_at IS NULL OR excluded.last_copied_at > last_copied_at
                    THEN excluded.last_copied_at
                ELSE last_copied_at
            END;
        """

        let eventTimestamp = eventDate.timeIntervalSince1970
        try withStatement(sql, operation: "updating suggestion usage") { statement in
            for scope in scopeRows(for: context) {
                defer { reset(statement) }
                try bind(candidateKey, at: 1, in: statement)
                try bind(scope.level.rawValue, at: 2, in: statement)
                try bind(scope.appKey, at: 3, in: statement)
                try bind(scope.surfaceKey, at: 4, in: statement)
                try bind(scope.contextKey, at: 5, in: statement)
                try bind(impressionDelta, at: 6, in: statement)
                try bind(selectionDelta, at: 7, in: statement)
                try bind(copyDelta, at: 8, in: statement)
                try bind(impressionDelta > 0 ? eventTimestamp : nil, at: 9, in: statement)
                try bind(selectionDelta > 0 ? eventTimestamp : nil, at: 10, in: statement)
                try bind(copyDelta > 0 ? eventTimestamp : nil, at: 11, in: statement)
                try stepDone(statement, operation: "updating suggestion usage")
            }
        }
    }

    // MARK: - Reads

    private func contextForSession(id: String) throws -> SuggestionLearningContext {
        let sql = """
        SELECT app_key, surface_key, context_key, context_confidence,
               app_matchable, surface_matchable, exact_matchable
        FROM suggestion_sessions
        WHERE id = ?
        LIMIT 1;
        """
        return try withStatement(sql, operation: "reading a suggestion session") { statement in
            try bind(id, at: 1, in: statement)
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE {
                throw SuggestionLearningStoreError.unknownSession(id)
            }
            guard code == SQLITE_ROW else {
                throw sqliteError(operation: "reading a suggestion session", code: code)
            }
            return SuggestionLearningContext(
                appKey: textColumn(statement, index: 0),
                surfaceKey: textColumn(statement, index: 1),
                contextKey: textColumn(statement, index: 2),
                confidence: sqlite3_column_double(statement, 3),
                appMatchable: sqlite3_column_int(statement, 4) != 0,
                surfaceMatchable: sqlite3_column_int(statement, 5) != 0,
                exactMatchable: sqlite3_column_int(statement, 6) != 0
            )
        }
    }

    // MARK: - Scope keys

    private struct ScopeRow {
        let level: SuggestionLearningLevel
        let appKey: String
        let surfaceKey: String
        let contextKey: String
    }

    private func scopeRows(for context: SuggestionLearningContext) -> [ScopeRow] {
        [
            ScopeRow(
                level: .exact,
                appKey: context.appKey,
                surfaceKey: context.surfaceKey,
                contextKey: context.contextKey
            ),
            ScopeRow(
                level: .surface,
                appKey: context.appKey,
                surfaceKey: context.surfaceKey,
                contextKey: Self.globalScopeKey
            ),
            ScopeRow(
                level: .application,
                appKey: context.appKey,
                surfaceKey: Self.globalScopeKey,
                contextKey: Self.globalScopeKey
            ),
            ScopeRow(
                level: .global,
                appKey: Self.globalScopeKey,
                surfaceKey: Self.globalScopeKey,
                contextKey: Self.globalScopeKey
            ),
        ]
    }

    // MARK: - Validation

    private func validate(context: SuggestionLearningContext) throws {
        try Self.validateStableKey(context.appKey, label: "application key")
        try Self.validateStableKey(context.surfaceKey, label: "surface key")
        try Self.validateStableKey(context.contextKey, label: "context key")
    }

    private func validate(impressions: [SuggestionLearningImpression]) throws {
        var candidateKeys = Set<String>()
        var positions = Set<Int>()
        for impression in impressions {
            try Self.validateStableKey(impression.candidateKey, label: "candidate key")
            try Self.validateStableKey(impression.sourceKey, label: "candidate source key")
            guard impression.position >= 0 else {
                throw SuggestionLearningStoreError.invalidImpression("position must be nonnegative")
            }
            if let score = impression.score, !score.isFinite {
                throw SuggestionLearningStoreError.invalidImpression("score must be finite")
            }
            guard candidateKeys.insert(impression.candidateKey).inserted else {
                throw SuggestionLearningStoreError.duplicateCandidateKey(impression.candidateKey)
            }
            guard positions.insert(impression.position).inserted else {
                throw SuggestionLearningStoreError.duplicatePosition(impression.position)
            }
        }
    }

    private static func validateStableKey(_ key: String, label: String) throws {
        guard !key.isEmpty else {
            throw SuggestionLearningStoreError.invalidKey(label: label, reason: "it is empty")
        }
        guard !key.contains("\0") else {
            throw SuggestionLearningStoreError.invalidKey(label: label, reason: "it contains a NUL byte")
        }
        guard key.utf8.count <= maximumKeyBytes else {
            throw SuggestionLearningStoreError.invalidKey(
                label: label,
                reason: "it exceeds \(maximumKeyBytes) UTF-8 bytes"
            )
        }
    }

    private func validate(date: Date, label: String) throws {
        guard date.timeIntervalSince1970.isFinite else {
            throw SuggestionLearningStoreError.invalidKey(label: label, reason: "it is not finite")
        }
    }

    // MARK: - SQLite helpers

    /// Bootstrap helpers are static because a synchronous actor initializer is
    /// nonisolated until it returns. They operate only on the new, unpublished
    /// connection passed by the initializer.
    private nonisolated static func inTransaction<T>(
        on database: OpaquePointer,
        _ body: () throws -> T
    ) throws -> T {
        try execute("BEGIN IMMEDIATE;", on: database, operation: "beginning a transaction")
        do {
            let result = try body()
            try execute("COMMIT;", on: database, operation: "committing a transaction")
            return result
        } catch {
            try? execute("ROLLBACK;", on: database, operation: "rolling back a transaction")
            throw error
        }
    }

    private nonisolated static func execute(
        _ sql: String,
        on database: OpaquePointer,
        operation: String
    ) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
            } else {
                message = String(cString: sqlite3_errmsg(database))
            }
            sqlite3_free(errorPointer)
            throw SuggestionLearningStoreError.sqlite(
                operation: operation,
                code: code,
                message: message
            )
        }
    }

    private nonisolated static func withStatement<T>(
        _ sql: String,
        on database: OpaquePointer,
        operation: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SuggestionLearningStoreError.sqlite(
                operation: operation,
                code: code,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private nonisolated static func pragmaText(
        _ sql: String,
        on database: OpaquePointer,
        operation: String
    ) throws -> String {
        try withStatement(sql, on: database, operation: operation) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                throw SuggestionLearningStoreError.sqlite(
                    operation: operation,
                    code: code,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            guard let pointer = sqlite3_column_text(statement, 0) else { return "" }
            return String(cString: pointer)
        }
    }

    private nonisolated static func pragmaInt(
        _ sql: String,
        on database: OpaquePointer,
        operation: String
    ) throws -> Int {
        try withStatement(sql, on: database, operation: operation) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                throw SuggestionLearningStoreError.sqlite(
                    operation: operation,
                    code: code,
                    message: String(cString: sqlite3_errmsg(database))
                )
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func connection() throws -> OpaquePointer {
        guard let database else {
            throw SuggestionLearningStoreError.cannotOpenDatabase(
                code: SQLITE_MISUSE,
                message: "The database connection is closed"
            )
        }
        return database
    }

    private func inTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;", operation: "beginning a transaction")
        do {
            let result = try body()
            try execute("COMMIT;", operation: "committing a transaction")
            return result
        } catch {
            try? execute("ROLLBACK;", operation: "rolling back a transaction")
            throw error
        }
    }

    private func execute(_ sql: String, operation: String) throws {
        let database = try connection()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard code == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
            } else {
                message = String(cString: sqlite3_errmsg(database))
            }
            sqlite3_free(errorPointer)
            throw SuggestionLearningStoreError.sqlite(
                operation: operation,
                code: code,
                message: message
            )
        }
    }

    private func withStatement<T>(
        _ sql: String,
        operation: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        let database = try connection()
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw sqliteError(operation: operation, code: code)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer, operation: String) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else {
            throw sqliteError(operation: operation, code: code)
        }
    }

    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let code = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, suggestionSQLiteTransient)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding text", code: code)
        }
    }

    private func bind(_ value: Int, at index: Int32, in statement: OpaquePointer) throws {
        let code = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding an integer", code: code)
        }
    }

    private func bind(_ value: Double?, at index: Int32, in statement: OpaquePointer) throws {
        let code = value.map { sqlite3_bind_double(statement, index, $0) }
            ?? sqlite3_bind_null(statement, index)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding a number", code: code)
        }
    }

    private func bind(_ value: Date, at index: Int32, in statement: OpaquePointer) throws {
        let code = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        guard code == SQLITE_OK else {
            throw sqliteError(operation: "binding a date", code: code)
        }
    }

    private func textColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func dateColumn(_ statement: OpaquePointer, index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func pragmaText(_ sql: String, operation: String) throws -> String {
        try withStatement(sql, operation: operation) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                throw sqliteError(operation: operation, code: code)
            }
            return textColumn(statement, index: 0)
        }
    }

    private func pragmaInt(_ sql: String, operation: String) throws -> Int {
        try withStatement(sql, operation: operation) { statement in
            let code = sqlite3_step(statement)
            guard code == SQLITE_ROW else {
                throw sqliteError(operation: operation, code: code)
            }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func sqliteError(operation: String, code: Int32) -> SuggestionLearningStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "The database connection is closed"
        return .sqlite(operation: operation, code: code, message: message)
    }
}

nonisolated(unsafe) private let suggestionSQLiteTransient =
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
