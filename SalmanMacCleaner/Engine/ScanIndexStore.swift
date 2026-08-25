//
//  ScanIndexStore.swift
//  SalmanMacCleaner
//
//  Persisted scan index backed by SQLite (system library, no third-party
//  dependency). Supports schema migrations, batched record inserts,
//  scan checkpoints, and resume of incomplete scans at root granularity.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLiteError: LocalizedError, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "SQLite open failed: \(m)"
        case .prepareFailed(let m): return "SQLite prepare failed: \(m)"
        case .stepFailed(let m): return "SQLite step failed: \(m)"
        }
    }
}

/// Thin SQLite wrapper (sync calls; owned by the ScanIndexStore actor).
public final class SQLiteDB {
    private var db: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.openFailed(message)
        }
        self.db = handle
        try execute("PRAGMA journal_mode=WAL;")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            throw SQLiteError.stepFailed(message)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return SQLiteStatement(statement: statement)
    }

    public func userVersion() -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    public func setUserVersion(_ version: Int) {
        try? execute("PRAGMA user_version = \(version);")
    }
}

public final class SQLiteStatement {
    private let statement: OpaquePointer

    fileprivate init(statement: OpaquePointer) {
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    @discardableResult
    public func bindText(_ value: String, at index: Int32) -> Self {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        return self
    }

    @discardableResult
    public func bindInt(_ value: Int64, at index: Int32) -> Self {
        sqlite3_bind_int64(statement, index, value)
        return self
    }

    @discardableResult
    public func bindDouble(_ value: Double, at index: Int32) -> Self {
        sqlite3_bind_double(statement, index, value)
        return self
    }

    @discardableResult
    public func bindNull(at index: Int32) -> Self {
        sqlite3_bind_null(statement, index)
        return self
    }

    public func step() throws -> Bool {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(sqlite3_db_handle(statement))))
        }
    }

    public func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    public func columnText(_ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    public func columnInt(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    public func columnIsNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }
}

// MARK: - Schema

public enum ScanIndexSchema {
    public static let currentVersion = 2

    public static func createTables() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS scans (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at REAL NOT NULL,
              ended_at REAL,
              mode TEXT NOT NULL,
              scope_json TEXT NOT NULL,
              status TEXT NOT NULL DEFAULT 'running',
              phase INTEGER,
              counts_json TEXT NOT NULL DEFAULT '{}',
              coverage_json TEXT,
              outcome_json TEXT,
              provenance TEXT NOT NULL DEFAULT 'full'
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS records (
              scan_id INTEGER NOT NULL,
              path TEXT NOT NULL,
              parent TEXT,
              name TEXT,
              is_directory INTEGER,
              is_package INTEGER,
              logical_size INTEGER,
              allocated_size INTEGER,
              modified REAL,
              created REAL,
              device INTEGER,
              inode INTEGER,
              owner_uid INTEGER,
              permissions INTEGER,
              is_symlink INTEGER,
              is_hidden INTEGER,
              is_purgeable INTEGER,
              is_quarantined INTEGER,
              classification TEXT,
              safety TEXT,
              reason TEXT,
              PRIMARY KEY (scan_id, path)
            );
            """,
            "CREATE INDEX IF NOT EXISTS idx_records_scan ON records(scan_id);",
            """
            CREATE TABLE IF NOT EXISTS scan_roots (
              scan_id INTEGER NOT NULL,
              root TEXT NOT NULL,
              state TEXT NOT NULL,
              PRIMARY KEY (scan_id, root)
            );
            """,
            """
            CREATE TABLE IF NOT EXISTS volume_state (
              mount_point TEXT PRIMARY KEY,
              last_event_id INTEGER,
              last_scan REAL
            );
            """
        ]
    }
}

// MARK: - Actor store

public actor ScanIndexStore {

    private let db: SQLiteDB
    public let databasePath: String
    private var activeScanID: Int64?

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SalmanMacCleaner", isDirectory: true)
            .appendingPathComponent("ScanIndex.sqlite")
    }

    public init(path: String? = nil) throws {
        let resolved = path ?? Self.defaultURL().path
        self.databasePath = resolved
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: resolved).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.db = try SQLiteDB(path: resolved)
        try migrateIfNeeded()
    }

    private func migrateIfNeeded() throws {
        let version = db.userVersion()
        if version < 1 {
            for statement in ScanIndexSchema.createTables() {
                try db.execute(statement)
            }
            db.setUserVersion(ScanIndexSchema.currentVersion)
        }
        // Future migrations append here with version-gated steps.
        if version >= 1 && version < 2 {
            try db.execute("""
                CREATE TABLE IF NOT EXISTS volume_state (
                  mount_point TEXT PRIMARY KEY,
                  last_event_id INTEGER,
                  last_scan REAL
                );
                """)
            db.setUserVersion(2)
        }
    }

    // MARK: - Sessions (checkpoints + resume)

    @discardableResult
    public func beginScan(mode: ScanMode, scope: ScanScope, provenance: ScanProvenance) throws -> Int64 {
        let statement = try db.prepare(
            "INSERT INTO scans (started_at, mode, scope_json, status, provenance) VALUES (?, ?, ?, 'running', ?);"
        )
        _ = statement
            .bindDouble(Date().timeIntervalSince1970, at: 1)
            .bindText(mode.rawValue, at: 2)
            .bindText(Self.encodeJSON(scope), at: 3)
            .bindText(provenance.rawValue, at: 4)
        _ = try statement.step()
        let id = db.lastInsertRowID()
        activeScanID = id
        return id
    }

    public func completeScan(scanID: Int64, outcome: ScanOutcome, counts: InventoryCounts, coverage: CoverageReport) throws {
        let statement = try db.prepare(
            "UPDATE scans SET status='completed', ended_at=?, counts_json=?, coverage_json=?, outcome_json=? WHERE id=?;"
        )
        _ = statement
            .bindDouble(Date().timeIntervalSince1970, at: 1)
            .bindText(Self.encodeJSON(counts), at: 2)
            .bindText(Self.encodeJSON(coverage), at: 3)
            .bindText(Self.encodeJSON(outcome), at: 4)
            .bindInt(scanID, at: 5)
        _ = try statement.step()
        activeScanID = nil
    }

    public func failScan(scanID: Int64, message: String) throws {
        let statement = try db.prepare("UPDATE scans SET status='failed', ended_at=?, coverage_json=? WHERE id=?;")
        _ = statement
            .bindDouble(Date().timeIntervalSince1970, at: 1)
            .bindText(Self.encodeJSON(["error": message]), at: 2)
            .bindInt(scanID, at: 3)
        _ = try statement.step()
        activeScanID = nil
    }

    public func markRootState(scanID: Int64, root: String, state: String) throws {
        let statement = try db.prepare(
            "INSERT OR REPLACE INTO scan_roots (scan_id, root, state) VALUES (?, ?, ?);"
        )
        _ = statement.bindInt(scanID, at: 1).bindText(root, at: 2).bindText(state, at: 3)
        _ = try statement.step()
    }

    /// Roots completed by a previous run of the same scan (resume support).
    public func completedRoots(scanID: Int64) throws -> Set<String> {
        let statement = try db.prepare("SELECT root FROM scan_roots WHERE scan_id=? AND state='completed';")
        _ = statement.bindInt(scanID, at: 1)
        var roots: Set<String> = []
        while try statement.step() {
            roots.insert(statement.columnText(0))
        }
        return roots
    }

    /// The latest resumable (running) scan for a mode.
    public func latestResumableScan(mode: ScanMode) -> (scanID: Int64, scope: ScanScope)? {
        guard let statement = try? db.prepare(
            "SELECT id, scope_json FROM scans WHERE status='running' AND mode=? ORDER BY started_at DESC LIMIT 1;"
        ) else { return nil }
        _ = statement.bindText(mode.rawValue, at: 1)
        guard (try? statement.step()) == true else { return nil }
        let id = statement.columnInt(0)
        let scopeJSON = statement.columnText(1)
        guard let data = scopeJSON.data(using: .utf8),
              let scope = try? JSONDecoder().decode(ScanScope.self, from: data) else { return nil }
        return (id, scope)
    }

    // MARK: - Records

    public func insertRecords(_ records: [FileRecord], scanID: Int64) throws {
        try insertClassifiedRecords(
            scanID: scanID,
            pairs: records.map {
                ($0, JunkVerdict(category: .unknown, safety: .protected,
                                 reason: "unclassified", autoSelectable: false,
                                 regenerable: false, sourceRule: "inventory"))
            }
        )
    }

    /// Batch insert with classification verdicts (single write per record).
    public func insertClassifiedRecords(scanID: Int64, pairs: [(FileRecord, JunkVerdict)]) throws {
        try db.execute("BEGIN TRANSACTION;")
        let statement = try db.prepare("""
            INSERT OR REPLACE INTO records (
              scan_id, path, parent, name, is_directory, is_package,
              logical_size, allocated_size, modified, created,
              device, inode, owner_uid, permissions,
              is_symlink, is_hidden, is_purgeable, is_quarantined,
              classification, safety, reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
        do {
            for pair in pairs {
                let record = pair.0
                let verdict = pair.1
                statement.reset()
                _ = statement
                    .bindInt(scanID, at: 1)
                    .bindText(record.path, at: 2)
                    .bindText(record.parent, at: 3)
                    .bindText(record.name, at: 4)
                    .bindInt(record.isDirectory ? 1 : 0, at: 5)
                    .bindInt(record.isPackage ? 1 : 0, at: 6)
                    .bindInt(record.logicalSize, at: 7)
                    .bindInt(record.allocatedSize, at: 8)
                    .bindDouble(record.modified?.timeIntervalSince1970 ?? 0, at: 9)
                    .bindDouble(record.created?.timeIntervalSince1970 ?? 0, at: 10)
                    .bindInt(Int64(record.device), at: 11)
                    .bindInt(Int64(record.inode), at: 12)
                    .bindInt(Int64(record.ownerUID), at: 13)
                    .bindInt(Int64(record.permissions), at: 14)
                    .bindInt(record.isSymlink ? 1 : 0, at: 15)
                    .bindInt(record.isHidden ? 1 : 0, at: 16)
                    .bindInt(record.isPurgeable ? 1 : 0, at: 17)
                    .bindInt(record.isQuarantined ? 1 : 0, at: 18)
                    .bindText(verdict.category.rawValue, at: 19)
                    .bindText(verdict.safety.rawValue, at: 20)
                    .bindText(verdict.reason, at: 21)
                _ = try statement.step()
            }
            try db.execute("COMMIT;")
        } catch {
            try? db.execute("ROLLBACK;")
            throw error
        }
    }

    public func setClassification(scanID: Int64, path: String, verdict: JunkVerdict) throws {
        let statement = try db.prepare(
            "UPDATE records SET classification=?, safety=?, reason=? WHERE scan_id=? AND path=?;"
        )
        _ = statement
            .bindText(verdict.category.rawValue, at: 1)
            .bindText(verdict.safety.rawValue, at: 2)
            .bindText(verdict.reason, at: 3)
            .bindInt(scanID, at: 4)
            .bindText(path, at: 5)
        _ = try statement.step()
    }

    public func recordsCount(scanID: Int64) -> Int64 {
        guard let statement = try? db.prepare("SELECT COUNT(*) FROM records WHERE scan_id=?;") else { return 0 }
        _ = statement.bindInt(scanID, at: 1)
        guard (try? statement.step()) == true else { return 0 }
        return statement.columnInt(0)
    }

    /// Duplicate candidates: regular files ≥ 1 KiB, biggest first, capped.
    public func duplicateCandidates(scanID: Int64, limit: Int) -> [ScannedItem] {
        guard let statement = try? db.prepare(
            """
            SELECT path, logical_size, allocated_size, modified FROM records
            WHERE scan_id=? AND is_directory=0 AND logical_size>=1024
            ORDER BY logical_size DESC LIMIT ?;
            """
        ) else { return [] }
        _ = statement.bindInt(scanID, at: 1)
        _ = statement.bindInt(Int64(limit), at: 2)
        var results: [ScannedItem] = []
        while (try? statement.step()) == true {
            let path = statement.columnText(0)
            let logical = statement.columnInt(1)
            let modifiedRaw = statement.columnDouble(3)
            let modified = modifiedRaw > 0 ? Date(timeIntervalSince1970: modifiedRaw) : nil
            results.append(ScannedItem(path: path, size: logical, modificationDate: modified))
        }
        return results
    }

    /// Classified (non-protected or all) items for the results workspace.
    public func classifiedItems(scanID: Int64, safety: SafetyLevel?, category: String?, limit: Int) -> [ClassifiedRecord] {
        var sql = """
            SELECT path, name, logical_size, allocated_size, modified, classification, safety, reason
            FROM records WHERE scan_id=?
            """
        if let safety {
            sql += " AND safety=?"
        }
        if let category {
            sql += " AND classification=?"
        }
        sql += " ORDER BY allocated_size DESC LIMIT ?;"

        guard let statement = try? db.prepare(sql) else { return [] }
        var nextIndex: Int32 = 2
        _ = statement.bindInt(scanID, at: 1)
        if let safety {
            _ = statement.bindText(safety.rawValue, at: nextIndex)
            nextIndex += 1
        }
        if let category {
            _ = statement.bindText(category, at: nextIndex)
            nextIndex += 1
        }
        _ = statement.bindInt(Int64(limit), at: nextIndex)

        var results: [ClassifiedRecord] = []
        while (try? statement.step()) == true {
            let modifiedRaw = statement.columnDouble(4)
            results.append(ClassifiedRecord(
                path: statement.columnText(0),
                name: statement.columnText(1),
                logicalSize: statement.columnInt(2),
                allocatedSize: statement.columnInt(3),
                modified: modifiedRaw > 0 ? Date(timeIntervalSince1970: modifiedRaw) : nil,
                category: statement.columnText(5),
                safety: statement.columnText(6),
                reason: statement.columnText(7)
            ))
        }
        return results
    }

    public func deleteRecords(scanID: Int64) {
        let statement = try? db.prepare("DELETE FROM records WHERE scan_id=?;")
        _ = statement?.bindInt(scanID, at: 1)
        _ = try? statement?.step()
    }

    /// Evict exactly the paths that were moved to the Trash, so the results
    /// workspace can never show — or re-select — an item that no longer
    /// exists. Everything else in the scan stays indexed.
    public func deleteRecords(scanID: Int64, paths: [String]) {
        deleteRecordsAndDescendants(scanID: scanID, paths: paths)
    }

    /// Evict moved paths and all descendant records under any moved directory,
    /// preventing stale entries from reappearing after directory trashing.
    public func deleteRecordsAndDescendants(scanID: Int64, paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths {
            let statement = try? db.prepare("DELETE FROM records WHERE scan_id=? AND path=?;")
            _ = statement?.bindInt(scanID, at: 1)
            _ = statement?.bindText(path, at: 2)
            _ = try? statement?.step()

            let prefixPattern = path.hasSuffix("/") ? path + "%" : path + "/%"
            let descStatement = try? db.prepare("DELETE FROM records WHERE scan_id=? AND path LIKE ?;")
            _ = descStatement?.bindInt(scanID, at: 1)
            _ = descStatement?.bindText(prefixPattern, at: 2)
            _ = try? descStatement?.step()
        }
    }

    /// Recalculate exact totals from live index records after removals.
    public func recalculateTotals(scanID: Int64) -> (itemsScanned: Int, bytesIndexed: Int64, safeBytes: Int64, reviewBytes: Int64, protectedBytes: Int64) {
        var itemsScanned = 0
        var bytesIndexed: Int64 = 0
        var safeBytes: Int64 = 0
        var reviewBytes: Int64 = 0
        var protectedBytes: Int64 = 0

        guard let statement = try? db.prepare("SELECT safety, allocated_size FROM records WHERE scan_id=?;") else {
            return (0, 0, 0, 0, 0)
        }
        _ = statement.bindInt(scanID, at: 1)
        while (try? statement.step()) == true {
            itemsScanned += 1
            let safety = statement.columnText(0)
            let size = statement.columnInt(1)
            bytesIndexed += size
            if safety == SafetyLevel.safe.rawValue {
                safeBytes += size
            } else if safety == SafetyLevel.review.rawValue {
                reviewBytes += size
            } else if safety == SafetyLevel.protected.rawValue {
                protectedBytes += size
            }
        }
        return (itemsScanned, bytesIndexed, safeBytes, reviewBytes, protectedBytes)
    }

    // MARK: - Volume event state (incremental scans)

    public func lastEventID(forMountPoint mountPoint: String) -> UInt64? {
        guard let statement = try? db.prepare("SELECT last_event_id FROM volume_state WHERE mount_point=?;") else { return nil }
        _ = statement.bindText(mountPoint, at: 1)
        guard (try? statement.step()) == true else { return nil }
        return UInt64(statement.columnInt(0))
    }

    public func saveEventState(mountPoint: String, lastEventID: UInt64) throws {
        let statement = try db.prepare(
            "INSERT OR REPLACE INTO volume_state (mount_point, last_event_id, last_scan) VALUES (?, ?, ?);"
        )
        _ = statement
            .bindText(mountPoint, at: 1)
            .bindInt(Int64(lastEventID), at: 2)
            .bindDouble(Date().timeIntervalSince1970, at: 3)
        _ = try statement.step()
    }

    // MARK: - Helpers

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        if #available(macOS 10.13, *) {
            encoder.dateEncodingStrategy = .iso8601
        }
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension SQLiteDB {
    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }
}

/// Lightweight record returned for results-workspace lists.
public struct ClassifiedRecord: Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var modified: Date?
    public var category: String
    public var safety: String
    public var reason: String

    public init(path: String,
                name: String,
                logicalSize: Int64,
                allocatedSize: Int64,
                modified: Date?,
                category: String,
                safety: String,
                reason: String) {
        self.path = path
        self.name = name
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.category = category
        self.safety = safety
        self.reason = reason
    }

    public var safetyLevel: SafetyLevel {
        SafetyLevel(rawValue: safety) ?? .protected
    }

    public var junkCategory: JunkCategory {
        JunkCategory(rawValue: category) ?? .unknown
    }
}
