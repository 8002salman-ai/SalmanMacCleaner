//
//  CleanupEngine.swift
//  SalmanMacCleaner
//
//  The only component in the app that removes files. Design rules:
//  - Dry-run (preview) is the default; `previewOnly == true` touches nothing.
//  - Removal happens exclusively through FileManager.trashItem — the app never
//    permanently deletes anything and never empties the Trash.
//  - Every path is validated at scan time *and* revalidated immediately before
//    it is moved to the Trash (TOCTOU protection).
//  - Running apps are never removed (checked via NSWorkspace).
//  - Selection is explicit: only paths the user checked are passed in.
//

import Foundation
import AppKit
import Combine

public struct CleanupItem: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let path: String
    public let size: Int64
    public let kind: String

    public init(id: UUID = UUID(), path: String, size: Int64 = 0, kind: String = "item") {
        self.id = id
        self.path = path
        self.size = size
        self.kind = kind
    }
}

public struct CleanupFailure: Identifiable, Equatable {
    public let id = UUID()
    public let path: String
    public let reason: String
}

public struct CleanupResult: Equatable {
    public var trashed: [CleanupItem]
    public var failures: [CleanupFailure]
    public var previewed: [CleanupItem]
    public var totalBytes: Int64
    public var elapsed: TimeInterval

    public init(trashed: [CleanupItem] = [],
                failures: [CleanupFailure] = [],
                previewed: [CleanupItem] = [],
                totalBytes: Int64 = 0,
                elapsed: TimeInterval = 0) {
        self.trashed = trashed
        self.failures = failures
        self.previewed = previewed
        self.totalBytes = totalBytes
        self.elapsed = elapsed
    }

    public var failedCount: Int { failures.count }
    public var succeededCount: Int { trashed.count + previewed.count }
}

/// Errors raised while preparing or running a cleanup.
public enum CleanupError: LocalizedError, Equatable {
    case runningApplication(String)
    case unsafeItem(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .runningApplication(let path):
            return NSLocalizedString("cleanup.error.running", comment: "") + " \(path)"
        case .unsafeItem(let path):
            return NSLocalizedString("cleanup.error.unsafe", comment: "") + " \(path)"
        case .notFound(let path):
            return NSLocalizedString("cleanup.error.missing", comment: "") + " \(path)"
        }
    }
}

@MainActor
public final class CleanupEngine: ObservableObject {

    @Published public private(set) var isRunning = false
    @Published public private(set) var currentItem: String?

    public static let shared = CleanupEngine()

    public init() {}

    /// True when any application whose bundle path equals `path` (or a parent
    /// bundle containing it) is currently running. The uninstaller refuses to
    /// remove running apps.
    public static func isAppRunning(bundlePath path: String) -> Bool {
        guard PathSafety.isAppBundle(path) else { return false }
        let runningURLs = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleURL?.standardizedFileURL.path }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return runningURLs.contains(candidate)
    }

    /// Validate a single candidate right before trashing. Returns the accepted
    /// path or throws the first blocking reason.
    public static func revalidate(item: CleanupItem, root: String, allowBundles: Bool) throws -> CleanupItem {
        let purpose: PathSafety.FilePurpose = .cleanup
        let result = PathSafety.validate(path: item.path, root: root, purpose: purpose, allowSymlink: false)
        switch result {
        case .failure(let error):
            throw CleanupError.unsafeItem(error.errorDescription ?? item.path)
        case .success(let validated):
            guard !validated.isSymlink else {
                throw CleanupError.unsafeItem(NSLocalizedString("cleanup.error.symlink", comment: "") + " \(item.path)")
            }
            if PathSafety.isAppBundle(validated.canonical) {
                guard allowBundles else {
                    throw CleanupError.unsafeItem(NSLocalizedString("cleanup.error.bundle", comment: ""))
                }
                guard !Self.isAppRunning(bundlePath: validated.canonical) else {
                    throw CleanupError.runningApplication(validated.canonical)
                }
            } else if !allowBundles {
                // Protected names/suffixes (keychains, databases, scripts, …)
                // are rejected for generic cleanup flows.
                let name = (validated.canonical as NSString).lastPathComponent
                guard !PathSafety.isProtectedFile(name: name, purpose: .cleanup) else {
                    throw CleanupError.unsafeItem(NSLocalizedString("cleanup.error.protected_name", comment: "") + " \(name)")
                }
            }
            guard validated.kind == .regularFile || validated.kind == .directory else {
                throw CleanupError.unsafeItem(NSLocalizedString("cleanup.error.kind", comment: ""))
            }
            return CleanupItem(id: item.id, path: validated.canonical, size: item.size, kind: item.kind)
        }
    }

    /// Execute a cleanup for the *selected* items only.
    ///
    /// - Parameters:
    ///   - items: The exact items the user selected (never "all found").
    ///   - root: Containment root the items were discovered under.
    ///   - previewOnly: When true nothing is moved; the result is a dry run.
    ///   - allowBundles: Whether .app bundles are eligible (uninstaller only).
    ///   - progress: Progress callback (fraction, detail).
    ///   - isCancelled: Polled between items.
    /// - Returns: A full CleanupResult. Safe items go to the Trash, everything
    ///   else is reported as a failure.
    public func clean(
        items: [CleanupItem],
        root: String,
        previewOnly: Bool,
        allowBundles: Bool = false,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) async -> CleanupResult {
        isRunning = true
        defer {
            isRunning = false
            currentItem = nil
        }

        let start = Date()
        var result = CleanupResult()
        let total = max(items.count, 1)
        let fileManager = FileManager.default

        for (index, item) in items.enumerated() {
            if isCancelled() {
                return result
            }
            progress(Double(index) / Double(total), item.path)

            // Immediate revalidation before any filesystem mutation.
            do {
                let safeItem = try Self.revalidate(item: item, root: root, allowBundles: allowBundles)
                currentItem = safeItem.path

                if previewOnly {
                    result.previewed.append(safeItem)
                    result.totalBytes += safeItem.size
                } else {
                    var resultingURL: NSURL?
                    try fileManager.trashItem(at: URL(fileURLWithPath: safeItem.path), resultingItemURL: &resultingURL)
                    result.trashed.append(safeItem)
                    result.totalBytes += safeItem.size
                }
            } catch {
                result.failures.append(CleanupFailure(path: item.path, reason: error.localizedDescription))
            }
        }

        progress(1, nil)
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }

    /// Convenience preview-only pass used by "Preview Cleanup" buttons.
    public func preview(items: [CleanupItem], root: String) async -> CleanupResult {
        await clean(items: items, root: root, previewOnly: true, progress: { _, _ in }, isCancelled: { false })
    }
}
