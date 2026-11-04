import Foundation
import SQLite3

/// Stores Codable snapshots in the app database. Each key has an independent import marker:
/// an empty snapshot is a value, so clearing state never resurrects the legacy file.
struct SQLiteAppState {
    let directory: URL
    let key: String

    private enum StorageError: Error { case sqlite(Int32) }

    func load<T: Codable>(_ type: T.Type, importing legacy: () throws -> T?) throws -> T? {
        try withConnection { db in
            try execute(db, "BEGIN IMMEDIATE")
            do {
                let value: T?
                if let bytes = try read(db) {
                    value = try PropertyListDecoder().decode([T].self, from: bytes).first
                } else {
                    value = try legacy()
                    try write(db, encode(value))
                }
                try execute(db, "COMMIT")
                return value
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    func loadJSON<T: Codable>(_ type: T.Type, from url: URL) throws -> T? {
        try load(type) {
            do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
    }

    func save<T: Codable>(_ value: T) throws {
        try withConnection { try write($0, encode(value)) }
    }

    func remove() throws {
        try withConnection { db in
            try statement(db, "DELETE FROM app_state WHERE key = ?") { stmt in
                try check(sqlite3_step(stmt), expected: SQLITE_DONE)
            }
        }
    }

    private func encode<T: Codable>(_ value: T?) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value.map { [$0] } ?? [])
    }

    private func withConnection<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        let url = directory.appendingPathComponent("library.sqlite3")
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        try check(status)
        guard let pointer else { throw StorageError.sqlite(SQLITE_CANTOPEN) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try check(sqlite3_busy_timeout(pointer, 5000))
        try execute(pointer, "CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        return try work(pointer)
    }

    private func read(_ db: OpaquePointer) throws -> Data? {
        try statement(db, "SELECT payload FROM app_state WHERE key = ?") { stmt in
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return nil }
            try check(result, expected: SQLITE_ROW)
            guard let bytes = sqlite3_column_blob(stmt, 0) else { throw StorageError.sqlite(SQLITE_CORRUPT) }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
        }
    }

    private func write(_ db: OpaquePointer, _ data: Data) throws {
        try statement(db, "INSERT OR REPLACE INTO app_state VALUES (?, ?)") { stmt in
            let result = data.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32($0.count), Self.transient)
            }
            try check(result)
            try check(sqlite3_step(stmt), expected: SQLITE_DONE)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func statement<T>(_ db: OpaquePointer, _ sql: String, _ work: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let stmt else { throw StorageError.sqlite(SQLITE_ERROR) }
        defer { sqlite3_finalize(stmt) }
        try check(sqlite3_bind_text(stmt, 1, key, -1, Self.transient))
        return try work(stmt)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK) throws {
        guard result == expected else { throw StorageError.sqlite(result) }
    }
}

/// Imports app preferences lazily while retaining the supplied defaults domain for old installs.
final class SQLitePreferences {
    private let directory: URL
    private let legacy: UserDefaults

    init(directory: URL, legacy: UserDefaults) {
        self.directory = directory
        self.legacy = legacy
    }

    func object(forKey key: String) -> Any? {
        do {
            let bytes = try storage(key).load(Data.self) {
                guard let value = legacy.object(forKey: key) else { return nil }
                return try encode(value)
            }
            guard let bytes,
                  let values = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [Any]
            else { return nil }
            return values.first
        } catch {
            NSLog("ClipToMac: preference could not be loaded")
            return nil
        }
    }

    func set(_ value: Any, forKey key: String) {
        do { try storage(key).save(encode(value)) }
        catch { NSLog("ClipToMac: preference could not be saved") }
    }

    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    private func storage(_ key: String) -> SQLiteAppState {
        SQLiteAppState(directory: directory, key: "preference:" + key)
    }

    private func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }
}
