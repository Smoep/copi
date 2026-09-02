import Foundation
import SQLite3

@main
struct SuggestionLearningStoreTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("copi-learning-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("suggestions.sqlite3")
        try installVersion2Fixture(at: databaseURL)

        let store = try SuggestionLearningStore(databaseURL: databaseURL)
        let cutoff = Date(timeIntervalSince1970: 1)
        let migrated = try await store.rankingEvidence(for: ["candidate:legacy"], since: cutoff)
        expect(migrated.destinationEvents.count == 1, "legacy selection survives migration")
        expect(migrated.destinationEvents[0].dispatchedAt == nil, "legacy selection is never invented as a dispatch")
        expect(migrated.destinationEvents[0].context.confidence == 0.60, "legacy context receives conservative confidence")
        expect(migrated.sourceCopies.first?.count == 12, "legacy global copies seed the bounded source prior")

        let context = SuggestionLearningContext(
            appKey: "app:test",
            surfaceKey: "app:test|surface:compose",
            contextKey: "app:test|surface:compose|focus:body",
            confidence: 0.85,
            surfaceMatchable: true,
            exactMatchable: true
        )
        let sessionID = try await store.beginSession(id: "session:new", context: context)
        try await store.recordSelection(sessionID: sessionID, candidateKey: "candidate:new")
        try await store.recordPasteDispatched(sessionID: sessionID, candidateKeys: ["candidate:new"])
        try await store.recordPasteDispatched(sessionID: sessionID, candidateKeys: ["candidate:new"])
        try await store.recordSourceCopy(candidateKey: "candidate:new", context: context)

        let current = try await store.rankingEvidence(for: ["candidate:new"], since: cutoff)
        expect(current.destinationEvents.count == 1, "selection insert is idempotent per session/candidate")
        expect(current.destinationEvents[0].dispatchedAt != nil, "dispatch upgrades the selection")
        expect(current.sourceCopies.reduce(0) { $0 + $1.count } == 1, "new source copy is recorded once")
        print("Suggestion learning-store tests passed")
    }

    private static func installVersion2Fixture(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            fatalError("could not create v2 fixture")
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE suggestion_sessions (
            id TEXT PRIMARY KEY NOT NULL, started_at REAL NOT NULL, ended_at REAL,
            app_key TEXT NOT NULL, surface_key TEXT NOT NULL, context_key TEXT NOT NULL
        );
        CREATE TABLE suggestion_impressions (
            id INTEGER PRIMARY KEY, session_id TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
            candidate_key TEXT NOT NULL, source_key TEXT NOT NULL, position INTEGER NOT NULL,
            score REAL, shown_at REAL NOT NULL, selected_at REAL,
            UNIQUE(session_id, candidate_key), UNIQUE(session_id, position)
        );
        CREATE TABLE suggestion_selections (
            id INTEGER PRIMARY KEY, session_id TEXT NOT NULL REFERENCES suggestion_sessions(id) ON DELETE CASCADE,
            candidate_key TEXT NOT NULL, selected_at REAL NOT NULL, position INTEGER,
            UNIQUE(session_id, candidate_key)
        );
        CREATE TABLE suggestion_usage_stats (
            candidate_key TEXT NOT NULL, level INTEGER NOT NULL,
            app_key TEXT NOT NULL, surface_key TEXT NOT NULL, context_key TEXT NOT NULL,
            impression_count INTEGER NOT NULL DEFAULT 0, selection_count INTEGER NOT NULL DEFAULT 0,
            copy_count INTEGER NOT NULL DEFAULT 0, last_impressed_at REAL,
            last_selected_at REAL, last_copied_at REAL,
            PRIMARY KEY(candidate_key, level, app_key, surface_key, context_key)
        ) WITHOUT ROWID;
        INSERT INTO suggestion_sessions VALUES(
            'session:legacy', 1900000000, 1900000010,
            'app:test', 'app:test|surface:compose', 'app:test|surface:compose|focus:body'
        );
        INSERT INTO suggestion_selections(session_id, candidate_key, selected_at)
            VALUES('session:legacy', 'candidate:legacy', 1900000005);
        INSERT INTO suggestion_usage_stats(
            candidate_key, level, app_key, surface_key, context_key,
            copy_count, last_copied_at
        ) VALUES('candidate:legacy', 3, '', '', '', 12, 1900000005);
        PRAGMA user_version = 2;
        """
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            fatalError(message)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Failed: \(message)") }
    }
}
