//
//  ScanSessionStore.swift
//  SalmanMacCleaner
//
//  Persisted scan + cleanup activity history (Activity & History module).
//  Never logs file contents or credentials; a privacy setting redacts paths.
//

import Foundation
import Combine

public struct ScanHistoryRecord: Identifiable, Codable, Equatable {
    public let id: UUID
    public var date: Date
    public var mode: String
    public var scope: String
    public var duration: TimeInterval
    public var itemsScanned: Int
    public var coveragePercent: Int
    public var provenance: String
    public var candidatesBytes: Int64
    public var applicationCount: Int
    public var duplicateGroupCount: Int

    public init(id: UUID = UUID(),
                date: Date,
                mode: String,
                scope: String,
                duration: TimeInterval,
                itemsScanned: Int,
                coveragePercent: Int,
                provenance: String,
                candidatesBytes: Int64,
                applicationCount: Int,
                duplicateGroupCount: Int) {
        self.id = id
        self.date = date
        self.mode = mode
        self.scope = scope
        self.duration = duration
        self.itemsScanned = itemsScanned
        self.coveragePercent = coveragePercent
        self.provenance = provenance
        self.candidatesBytes = candidatesBytes
        self.applicationCount = applicationCount
        self.duplicateGroupCount = duplicateGroupCount
    }
}

public struct CleanupHistoryRecord: Identifiable, Codable, Equatable {
    public let id: UUID
    public var date: Date
    public var action: String
    public var category: String
    public var itemCount: Int
    public var bytes: Int64
    public var previewOnly: Bool
    public var movedCount: Int
    public var failedCount: Int
    public var root: String

    public init(id: UUID = UUID(),
                date: Date,
                action: String,
                category: String,
                itemCount: Int,
                bytes: Int64,
                previewOnly: Bool,
                movedCount: Int,
                failedCount: Int,
                root: String) {
        self.id = id
        self.date = date
        self.action = action
        self.category = category
        self.itemCount = itemCount
        self.bytes = bytes
        self.previewOnly = previewOnly
        self.movedCount = movedCount
        self.failedCount = failedCount
        self.root = root
    }
}

@MainActor
public final class ScanSessionStore: ObservableObject {

    @Published public private(set) var scans: [ScanHistoryRecord] = []
    @Published public private(set) var cleanups: [CleanupHistoryRecord] = []

    public let fileURL: URL
    /// Path redaction for privacy.
    public var redactPaths = false

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SalmanMacCleaner", isDirectory: true)
            .appendingPathComponent("SessionHistory.json")
    }

    private struct Payload: Codable {
        var scans: [ScanHistoryRecord]
        var cleanups: [CleanupHistoryRecord]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }
        scans = Array(payload.scans.sorted { $0.date > $1.date }.prefix(500))
        cleanups = Array(payload.cleanups.sorted { $0.date > $1.date }.prefix(500))
    }

    public func recordScan(_ record: ScanHistoryRecord) {
        scans.insert(record, at: 0)
        if scans.count > 500 { scans = Array(scans.prefix(500)) }
        persist()
    }

    public func recordCleanup(_ record: CleanupHistoryRecord) {
        cleanups.insert(record, at: 0)
        if cleanups.count > 500 { cleanups = Array(cleanups.prefix(500)) }
        persist()
    }

    public func clearAll() {
        scans = []
        cleanups = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Payload(scans: scans, cleanups: cleanups)) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence.
        }
    }

    // MARK: - Export

    public func exportJSON() -> Data? {
        try? JSONEncoder().encode(Payload(scans: scans, cleanups: cleanups))
    }

    public func exportCSV() -> Data? {
        var csv = "kind,date,action,mode,items,bytes,coverage,moved,failed,preview\n"
        let formatter = ISO8601DateFormatter()
        for scan in scans {
            csv += "scan,\(formatter.string(from: scan.date)),\(csvEscape(scan.mode)),\(scan.mode),\(scan.itemsScanned),\(scan.candidatesBytes),\(scan.coveragePercent),,,\n"
        }
        for cleanup in cleanups {
            csv += "cleanup,\(formatter.string(from: cleanup.date)),\(csvEscape(cleanup.action)),\(csvEscape(cleanup.category)),\(cleanup.itemCount),\(cleanup.bytes),,\(cleanup.movedCount),\(cleanup.failedCount),\(cleanup.previewOnly ? "true" : "false")\n"
        }
        return csv.data(using: .utf8)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// Redact a path for privacy when the setting is enabled.
    public func presentablePath(_ path: String) -> String {
        guard redactPaths else { return path }
        let components = path.split(separator: "/")
        guard let last = components.last else { return "…" }
        return "~/…/\(last)"
    }
}
