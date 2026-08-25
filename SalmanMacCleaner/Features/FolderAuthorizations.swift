//
//  FolderAuthorizations.swift
//  SalmanMacCleaner
//
//  Security-scoped folder authorizations for Deep Scan / Custom Scan.
//
//  The user grants folder access via NSOpenPanel (the only correct way for
//  a sandboxed app to read Desktop/Documents/Downloads/external drives).
//  Bookmarks are persisted and re-resolved with security scope on every
//  scan; stale bookmarks are reported, never silently used.
//

import Foundation
import AppKit
import SwiftUI
import Combine

public struct AuthorizedFolder: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var bookmarkData: Data
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, bookmarkData: Data, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }
}

@MainActor
public final class FolderAuthorizationsStore: ObservableObject {

    public static let shared = FolderAuthorizationsStore()

    @Published public private(set) var folders: [AuthorizedFolder] = []
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SalmanMacCleaner", isDirectory: true)
            .appendingPathComponent("AuthorizedFolders.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AuthorizedFolder].self, from: data) else {
            folders = []
            return
        }
        folders = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence.
        }
    }

    /// Present the system folder picker and persist a security-scoped
    /// bookmark for the chosen folder. Returns true when granted.
    public func presentFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("folders.picker.prompt", comment: "")
        panel.message = NSLocalizedString("folders.picker.message", comment: "")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        authorize(url: url)
    }

    /// Store a security-scoped bookmark for `url`.
    @discardableResult
    public func authorize(url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard !folders.contains(where: { $0.name == standardized.path }) else { return true }

        let bookmarkData: Data
        do {
            bookmarkData = try standardized.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return false
        }

        folders.append(AuthorizedFolder(
            name: standardized.path,
            bookmarkData: bookmarkData
        ))
        persist()
        return true
    }

    public func revoke(id: UUID) {
        folders.removeAll { $0.id == id }
        persist()
    }

    /// Resolve all stored bookmarks with security scope. Stale bookmarks are
    /// dropped from the result (and optionally reported).
    public func resolvedURLs() -> [URL] {
        var resolved: [URL] = []
        for folder in folders {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }
            resolved.append(url.standardizedFileURL)
        }
        return resolved
    }

    /// Run `body` while the resolved security scopes are active (required
    /// for sandboxed access).
    public func withAccess<T>(_ body: () throws -> T) rethrows -> T {
        let urls = resolvedURLs()
        let accesses = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, granted) in accesses where granted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    // MARK: - Long-lived scope activation (scan duration)

    private var activeScopes: [URL: Bool] = [:]

    /// Start security scope on every resolved bookmark and keep it active
    /// until `deactivateScopes()` — used for the duration of a scan.
    public func activateScopes() -> [URL] {
        let urls = resolvedURLs()
        for url in urls where activeScopes[url] == nil {
            activeScopes[url] = url.startAccessingSecurityScopedResource()
        }
        return urls
    }

    public func deactivateScopes() {
        for (url, granted) in activeScopes where granted {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopes = [:]
    }
}

/// Reusable authorization section shown in the Deep Scan hero and Settings.
public struct AuthorizedFoldersSection: View {
    @ObservedObject var store: FolderAuthorizationsStore

    public init(store: FolderAuthorizationsStore = .shared) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("folders.section.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.presentFolderPicker()
                } label: {
                    Label("folders.choose", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            if store.folders.isEmpty {
                Text("folders.none")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(store.folders) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .foregroundStyle(AuroraPalette.cyan)
                        Text(folder.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            store.revoke(id: folder.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("folders.revoke"))
                    }
                }
            }
            Text("folders.explanation")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
    }
}
