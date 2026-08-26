//
//  HistoryStore.swift
//  SalmanMacCleaner
//
//  Local-only cleanup history with JSON and CSV export. Entries are recorded
//  *after* a cleanup run completes and are stored inside Application Support
//  (never synced, never sent anywhere). The app performs no network calls.
//

import Foundation
import Combine
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// One recorded cleanup event.
public struct HistoryEntry: Identifiable, Codable, Equatable {
    public let id: UUID
    public let date: Date
    public let action: String
    public let category: String
    public let itemCount: Int
    public let bytes: Int64
    public let dryRun: Bool
    public let root: String

    public init(id: UUID = UUID(),
                date: Date = Date(),
                action: String,
                category: String,
                itemCount: Int,
                bytes: Int64,
                dryRun: Bool,
                root: String) {
        self.id = id
        self.date = date
        self.action = action
        self.category = category
        self.itemCount = itemCount
        self.bytes = bytes
        self.dryRun = dryRun
        self.root = root
    }

    public var isPreview: Bool { dryRun }
}

@MainActor
public final class HistoryStore: ObservableObject {

    @Published public private(set) var entries: [HistoryEntry] = []
    public let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        load()
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SalmanMacCleaner", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    /// Load persisted history. Missing/corrupt files simply start fresh.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([HistoryEntry].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.sorted { $0.date > $1.date }
    }

    /// Append an entry and persist.
    public func record(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries = Array(entries.prefix(500))
        }
        persist()
    }

    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let data = try? encoder.encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // History persistence is best-effort; never blocks cleanup.
        }
    }

    // MARK: - Export

    public enum ExportFormat: String, CaseIterable, Identifiable {
        case json
        case csv
        public var id: String { rawValue }
        public var title: String { rawValue.uppercased() }
    }

    /// Produce export data for the given format.
    public func exportData(format: ExportFormat) -> Data? {
        switch format {
        case .json:
            // Export should be interoperable with a plain JSONDecoder. The
            // persisted store keeps ISO-8601 dates; the exported format uses
            // Foundation's portable numeric Date representation.
            let exportEncoder = JSONEncoder()
            exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try? exportEncoder.encode(entries)
        case .csv:
            var csv = "id,date,action,category,item_count,bytes,dry_run,root\n"
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                let fields = [
                    entry.id.uuidString,
                    formatter.string(from: entry.date),
                    csvEscape(entry.action),
                    csvEscape(entry.category),
                    String(entry.itemCount),
                    String(entry.bytes),
                    entry.dryRun ? "true" : "false",
                    csvEscape(entry.root)
                ]
                csv += fields.joined(separator: ",") + "\n"
            }
            return csv.data(using: .utf8)
        }
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// Run a save panel (on macOS) and write the export. Returns the file URL
    /// on success.
    @MainActor
    public func exportInteractive(format: ExportFormat) -> URL? {
        #if os(macOS)
        guard let data = exportData(format: format) else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "SalmanMacCleaner-History.\(format.rawValue)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        switch format {
        case .json:
            panel.allowedContentTypes = [.json]
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
