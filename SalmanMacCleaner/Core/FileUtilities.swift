//
//  FileUtilities.swift
//  SalmanMacCleaner
//
//  Small, safe filesystem helpers shared by scanners and the cleanup engine.
//  No shell, no sudo, no network — only Foundation file APIs.
//

import Foundation

/// Thin, dependency-free wrapper around FileManager used everywhere in the app
/// so tests can swap in an in-memory harness if they ever need to.
public protocol FileManaging {
    func fileExists(atPath path: String) -> Bool
    func isDirectory(atPath path: String) -> Bool
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws
    func removeItem(at url: URL) throws
    func contentsEqual(atPath path1: String, andPath path2: String) -> Bool
    func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]?) -> Bool
}

extension FileManager: FileManaging {}

public enum FileUtilities {

    /// FileManager instance. Tests may swap `default` via a test seam, but
    /// production code always talks to the real manager.
    public static var manager: FileManaging = FileManager.default

    /// Human readable byte formatter (B, KB, MB, GB, TB) with a compact style.
    public static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    /// Size of a file, or 0.
    public static func fileSize(atPath path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.size] as? NSNumber else {
            return 0
        }
        return number.int64Value
    }

    /// Modification date of a file, if available.
    public static func modificationDate(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// Creation date of a file, if available.
    public static func creationDate(atPath path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attributes[.creationDate] as? Date
    }

    /// Best-effort secure name for a file (used in messages, never in logic).
    public static func displayName(forPath path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Enumerate the entries of a directory *without* following symlinks and
    /// *without* crossing devices. Returns immediately on error (callers show
    /// a graceful permission message).
    public static func safeDirectoryContents(
        at url: URL,
        includingHidden: Bool = false
    ) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !includingHidden { options.insert(.skipsHiddenFiles) }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }
        return contents
    }

    /// Serialize an encodable value to pretty JSON (history exports).
    public static func jsonData<T: Encodable>(_ value: T, pretty: Bool = true) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if #available(macOS 10.13, *) {
            encoder.dateEncodingStrategy = .iso8601
        }
        return try? encoder.encode(value)
    }

    /// Write `data` to `url`, creating parent directories as needed.
    @discardableResult
    public static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Read data from `url`.
    public static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
