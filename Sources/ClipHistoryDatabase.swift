import Foundation
import SQLite3

/// The library and its transfer receipts share a database so a delivery is committed once.
final class ClipHistoryDatabase {
    private enum Failure: Error { case sqlite(Int32), invalidRecord, unsupportedSchema }
    private enum Value {
        case text(String?), integer(Int), real(Double)
    }

    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let columns = """
        id, position, body, app_name, package_name, created_at, kind, mime_type,
        attachment_name, attachment_path, source_device, direction, pinned,
        collection, repeat_count, updated_at, transfer_id, delivery_state, content_hash
        """

    init(url: URL, legacyHistory: URL, legacyReceipts: URL) throws {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw Failure.sqlite(status)
        }
        db = connection
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try check(sqlite3_busy_timeout(db, 5_000))
            try transaction {
                let versions = try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }
                switch versions.first {
                case 0:
                    let clips = try Self.readLegacy([ClipItem].self, from: legacyHistory) ?? []
                    let receipts = Set(try Self.readLegacy([String].self, from: legacyReceipts) ?? [])
                    try execute("""
                        CREATE TABLE clips (
                            id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, body TEXT NOT NULL,
                            app_name TEXT NOT NULL, package_name TEXT NOT NULL, created_at REAL NOT NULL,
                            kind TEXT NOT NULL, mime_type TEXT, attachment_name TEXT, attachment_path TEXT,
                            source_device TEXT, direction TEXT NOT NULL, pinned INTEGER NOT NULL,
                            collection TEXT, repeat_count INTEGER NOT NULL, updated_at REAL NOT NULL,
                            transfer_id TEXT NOT NULL, delivery_state TEXT NOT NULL, content_hash TEXT
                        )
                        """)
                    try execute("CREATE TABLE receipts (id TEXT PRIMARY KEY NOT NULL)")
                    try execute("CREATE INDEX clip_order ON clips(position)")
                    try writeClips(clips, previous: [])
                    try writeReceipts(receipts, previous: [])
                    guard try loadClips() == clips, try loadReceipts() == receipts else { throw Failure.invalidRecord }
                    try execute("PRAGMA user_version = 1")
                case 1:
                    break
                default:
                    throw Failure.unsupportedSchema
                }
            }
        } catch {
            sqlite3_close(connection)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func loadClips() throws -> [ClipItem] {
        try query("SELECT \(Self.columns) FROM clips ORDER BY position") { row in
            guard let rawID = Self.text(row, 0), let id = UUID(uuidString: rawID),
                  let kindValue = Self.text(row, 6), let kind = ClipKind(rawValue: kindValue),
                  let body = Self.text(row, 2), let app = Self.text(row, 3),
                  let package = Self.text(row, 4), let direction = Self.text(row, 11),
                  let transfer = Self.text(row, 16), let delivery = Self.text(row, 17)
            else { throw Failure.invalidRecord }
            return ClipItem(
                id: id, text: body, appName: app, packageName: package,
                timestamp: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 5)),
                kind: kind, mimeType: Self.text(row, 7), attachmentName: Self.text(row, 8),
                attachmentPath: Self.text(row, 9), sourceDeviceId: Self.text(row, 10),
                direction: direction, isPinned: sqlite3_column_int(row, 12) != 0,
                collection: Self.text(row, 13), repeatCount: Int(sqlite3_column_int64(row, 14)),
                updatedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 15)),
                transferID: transfer, deliveryState: delivery, contentHash: Self.text(row, 18)
            )
        }
    }

    func loadReceipts() throws -> Set<String> {
        Set(try query("SELECT id FROM receipts") { row in
            guard let id = Self.text(row, 0) else { throw Failure.invalidRecord }
            return id
        })
    }

    func save(clips: [ClipItem]?, receipts: Set<String>? = nil) throws {
        try transaction {
            if let clips { try writeClips(clips, previous: loadClips()) }
            if let receipts { try writeReceipts(receipts, previous: loadReceipts()) }
        }
    }

    private func writeClips(_ clips: [ClipItem], previous: [ClipItem]) throws {
        let ids = Set(clips.map(\.id))
        guard ids.count == clips.count else { throw Failure.invalidRecord }
        let old = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0) })
        for removed in previous where !ids.contains(removed.id) {
            try execute("DELETE FROM clips WHERE id = ?", [.text(removed.id.uuidString)])
        }
        let placeholders = Array(repeating: "?", count: 19).joined(separator: ",")
        for (position, clip) in clips.enumerated() {
            if let existing = old[clip.id], existing.offset == position && existing.element == clip { continue }
            try execute("INSERT OR REPLACE INTO clips (\(Self.columns)) VALUES (\(placeholders))", [
                .text(clip.id.uuidString), .integer(position), .text(clip.text),
                .text(clip.appName), .text(clip.packageName), .real(clip.timestamp.timeIntervalSinceReferenceDate),
                .text(clip.kind.rawValue), .text(clip.mimeType), .text(clip.attachmentName),
                .text(clip.attachmentPath), .text(clip.sourceDeviceId), .text(clip.direction),
                .integer(clip.isPinned ? 1 : 0), .text(clip.collection), .integer(clip.repeatCount),
                .real(clip.updatedAt.timeIntervalSinceReferenceDate), .text(clip.transferID),
                .text(clip.deliveryState), .text(clip.contentHash)
            ])
        }
    }

    private func writeReceipts(_ receipts: Set<String>, previous: Set<String>) throws {
        for id in previous.subtracting(receipts) { try execute("DELETE FROM receipts WHERE id = ?", [.text(id)]) }
        for id in receipts.subtracting(previous) { try execute("INSERT INTO receipts VALUES (?)", [.text(id)]) }
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                if let text {
                    try check(text.withCString { sqlite3_bind_text(stmt, index, $0, Int32(text.utf8.count), Self.transient) })
                } else {
                    try check(sqlite3_bind_null(stmt, index))
                }
            case .integer(let number): try check(sqlite3_bind_int64(stmt, index, Int64(number)))
            case .real(let number): try check(sqlite3_bind_double(stmt, index, number))
            }
        }
        try check(sqlite3_step(stmt), expected: SQLITE_DONE)
    }

    private func query<T>(_ sql: String, decode: (OpaquePointer) throws -> T) throws -> [T] {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        var result: [T] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(try decode(stmt))
            status = sqlite3_step(stmt)
        }
        try check(status, expected: SQLITE_DONE)
        return result
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let stmt else { throw Failure.invalidRecord }
        return stmt
    }

    private func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
        guard status == expected else { throw Failure.sqlite(status) }
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(row, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }

    private static func readLegacy<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
