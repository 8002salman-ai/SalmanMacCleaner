//
//  IgnoreListStore.swift
//  SalmanMacCleaner
//
//  Persisted user ignore list: exact paths and case-insensitive substring
//  patterns. Ignored entries never appear as cleanup candidates.
//

import Foundation
import Combine

public struct IgnoreRule: Identifiable, Codable, Equatable {
    public let id: UUID
    public var pattern: String
    public var kind: Kind
    public var createdAt: Date

    public enum Kind: String, Codable {
        case exactPath
        case contains
    }

    public init(id: UUID = UUID(), pattern: String, kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.kind = kind
        self.createdAt = createdAt
    }
}

@MainActor
public final class IgnoreListStore: ObservableObject {

    @Published public private(set) var rules: [IgnoreRule] = []
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SalmanMacCleaner", isDirectory: true)
            .appendingPathComponent("IgnoreList.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([IgnoreRule].self, from: data) else {
            rules = []
            return
        }
        rules = decoded
    }

    public func add(pattern: String, kind: IgnoreRule.Kind) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !rules.contains(where: { $0.pattern == trimmed && $0.kind == kind }) else { return }
        rules.insert(IgnoreRule(pattern: trimmed, kind: kind), at: 0)
        persist()
    }

    public func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    public func removeAll() {
        rules = []
        persist()
    }

    public func isIgnored(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let lowercased = standardized.lowercased()
        for rule in rules {
            switch rule.kind {
            case .exactPath:
                if rule.pattern == standardized { return true }
            case .contains:
                if !rule.pattern.isEmpty && lowercased.contains(rule.pattern.lowercased()) { return true }
            }
        }
        return false
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence.
        }
    }
}
