import AppCore
import Foundation
import SQLite3

public final actor SQLiteMeetingStore: MeetingStore, TranscriptRetriever {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "SQLiteMeetingStore", code: 1001, userInfo: [NSLocalizedDescriptionKey: "Failed to open database"])
        }
        try Self.createSchema(db: db)
    }

    deinit {
        sqlite3_close(db)
    }

    public func createMeeting(title: String) async throws -> MeetingRecord {
        let meeting = MeetingRecord(title: title)
        let sql = "INSERT INTO meetings(id, title, started_at) VALUES(?, ?, ?)"
        try exec(sql: sql, bind: [meeting.id.uuidString, title, iso(meeting.startedAt)])
        return meeting
    }

    public func appendSegment(meetingID: UUID, segment: TranscriptSegment) async throws {
        let sql = "INSERT INTO segments(id, meeting_id, speaker_id, start_ms, end_ms, text, confidence) VALUES(?, ?, ?, ?, ?, ?, ?)"
        try exec(sql: sql, bind: [
            segment.id.uuidString,
            meetingID.uuidString,
            segment.speakerID ?? "",
            String(segment.startMs),
            String(segment.endMs),
            segment.text,
            String(segment.confidence)
        ])
    }

    public func appendSnapshot(meetingID: UUID, snapshot: SummarySnapshot) async throws {
        let actionItems = try String(data: JSONEncoder().encode(snapshot.actionItems), encoding: .utf8) ?? "[]"
        let decisions = try String(data: JSONEncoder().encode(snapshot.decisions), encoding: .utf8) ?? "[]"
        let sql = "INSERT INTO snapshots(id, meeting_id, timestamp, summary, action_items, decisions) VALUES(?, ?, ?, ?, ?, ?)"
        try exec(sql: sql, bind: [
            UUID().uuidString,
            meetingID.uuidString,
            iso(snapshot.timestamp),
            snapshot.summary,
            actionItems,
            decisions
        ])
    }

    public func closeMeeting(meetingID: UUID, endDate: Date) async throws {
        let sql = "UPDATE meetings SET ended_at = ? WHERE id = ?"
        try exec(sql: sql, bind: [iso(endDate), meetingID.uuidString])
    }

    public func fetchMeetings(query: String?) async throws -> [MeetingRecord] {
        let whereClause = (query?.isEmpty == false) ? " WHERE title LIKE ? " : ""
        let sql = "SELECT id, title, started_at, ended_at FROM meetings\(whereClause) ORDER BY started_at DESC"
        let args = (query?.isEmpty == false) ? ["%\(query ?? "")%"] : []

        return try queryRows(sql: sql, bind: args) { stmt in
            let id = Self.text(stmt, idx: 0)
            let title = Self.text(stmt, idx: 1)
            let started = Self.text(stmt, idx: 2)
            let ended = Self.text(stmt, idx: 3)
            return MeetingRecord(
                id: UUID(uuidString: id) ?? UUID(),
                startedAt: Self.fromISO(started) ?? Date(),
                endedAt: Self.fromISO(ended),
                title: title,
                transcript: [],
                snapshots: []
            )
        }
    }

    public func fetchMeeting(id: UUID) async throws -> MeetingRecord? {
        let meetings = try await fetchMeetings(query: nil)
        guard var meeting = meetings.first(where: { $0.id == id }) else { return nil }
        
        // Load transcript segments
        let transcriptSql = """
        SELECT id, speaker_id, start_ms, end_ms, text, confidence
        FROM segments
        WHERE meeting_id = ?
        ORDER BY start_ms ASC
        """
        meeting.transcript = try queryRows(sql: transcriptSql, bind: [id.uuidString]) { stmt in
            TranscriptSegment(
                id: UUID(uuidString: Self.text(stmt, idx: 0)) ?? UUID(),
                speakerID: {
                    let s = Self.text(stmt, idx: 1)
                    return s.isEmpty ? nil : s
                }(),
                startMs: Int64(Self.text(stmt, idx: 2)) ?? 0,
                endMs: Int64(Self.text(stmt, idx: 3)) ?? 0,
                text: Self.text(stmt, idx: 4),
                confidence: Float(Self.text(stmt, idx: 5)) ?? 0
            )
        }
        
        // Load snapshots
        let snapshotSql = """
        SELECT timestamp, summary, action_items, decisions
        FROM snapshots
        WHERE meeting_id = ?
        ORDER BY timestamp DESC
        LIMIT 1
        """
        let snapshots = try queryRows(sql: snapshotSql, bind: [id.uuidString]) { stmt in
            let timestamp = Self.fromISO(Self.text(stmt, idx: 0)) ?? Date()
            let actionItemsJson = Self.text(stmt, idx: 2)
            let decisionsJson = Self.text(stmt, idx: 3)
            
            let actionItems = (try? JSONSerialization.jsonObject(with: actionItemsJson.data(using: .utf8) ?? Data()) as? [String]) ?? []
            let decisions = (try? JSONSerialization.jsonObject(with: decisionsJson.data(using: .utf8) ?? Data()) as? [String]) ?? []
            
            return SummarySnapshot(
                timestamp: timestamp,
                summary: Self.text(stmt, idx: 1),
                actionItems: actionItems,
                decisions: decisions
            )
        }
        meeting.snapshots = snapshots
        
        return meeting
    }

    public func search(query: String, limit: Int) async throws -> [TranscriptSegment] {
        let sql = """
        SELECT id, speaker_id, start_ms, end_ms, text, confidence
        FROM segments
        WHERE text LIKE ?
        ORDER BY rowid DESC
        LIMIT ?
        """

        return try queryRows(sql: sql, bind: ["%\(query)%", String(limit)]) { stmt in
            TranscriptSegment(
                id: UUID(uuidString: Self.text(stmt, idx: 0)) ?? UUID(),
                speakerID: {
                    let s = Self.text(stmt, idx: 1)
                    return s.isEmpty ? nil : s
                }(),
                startMs: Int64(Self.text(stmt, idx: 2)) ?? 0,
                endMs: Int64(Self.text(stmt, idx: 3)) ?? 0,
                text: Self.text(stmt, idx: 4),
                confidence: Float(Self.text(stmt, idx: 5)) ?? 0
            )
        }
    }

    private static func createSchema(db: OpaquePointer?) throws {
        try execStatic(db: db, sql: """
        CREATE TABLE IF NOT EXISTS meetings(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT
        );
        """)

        try execStatic(db: db, sql: """
        CREATE TABLE IF NOT EXISTS segments(
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            speaker_id TEXT,
            start_ms INTEGER NOT NULL,
            end_ms INTEGER NOT NULL,
            text TEXT NOT NULL,
            confidence REAL NOT NULL,
            FOREIGN KEY(meeting_id) REFERENCES meetings(id)
        );
        """)

        try execStatic(db: db, sql: """
        CREATE TABLE IF NOT EXISTS snapshots(
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            summary TEXT NOT NULL,
            action_items TEXT NOT NULL,
            decisions TEXT NOT NULL,
            FOREIGN KEY(meeting_id) REFERENCES meetings(id)
        );
        """)

        try execStatic(db: db, sql: "CREATE INDEX IF NOT EXISTS idx_segments_text ON segments(text);")
    }

    private static func execStatic(db: OpaquePointer?, sql: String) throws {
        guard let db else { throw NSError(domain: "SQLiteMeetingStore", code: 1007) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteMeetingStore", code: 1008, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func exec(sql: String, bind: [String] = []) throws {
        guard let db else { throw NSError(domain: "SQLiteMeetingStore", code: 1002) }
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteMeetingStore", code: 1003, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, item) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), item, -1, sqliteTransient)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "SQLiteMeetingStore", code: 1004, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func queryRows<T>(sql: String, bind: [String], mapper: (OpaquePointer) -> T) throws -> [T] {
        guard let db else { throw NSError(domain: "SQLiteMeetingStore", code: 1005) }
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteMeetingStore", code: 1006, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        defer { sqlite3_finalize(stmt) }

        for (idx, item) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(idx + 1), item, -1, sqliteTransient)
        }

        var items: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let stmt { items.append(mapper(stmt)) }
        }
        return items
    }

    private static func text(_ stmt: OpaquePointer?, idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func fromISO(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }
}
