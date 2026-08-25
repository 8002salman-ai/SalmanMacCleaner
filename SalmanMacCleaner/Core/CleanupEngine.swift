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
import Darwin

public struct CleanupItem: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let path: String
    public let size: Int64
    public let kind: String
    /// Optional lstat identity captured by a scanner. This keeps hard links
    /// from being counted as two physical removals during reconciliation.
    public let device: Int32
    public let inode: UInt64

    public init(id: UUID = UUID(),
                path: String,
                size: Int64 = 0,
                kind: String = "item",
                device: Int32 = 0,
                inode: UInt64 = 0) {
        self.id = id
        self.path = path
        self.size = size
        self.kind = kind
        self.device = device
        self.inode = inode
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
    /// Unique bytes presented to this cleanup run.
    public var candidateBytes: Int64
    /// Unique bytes in the explicit selection.
    public var selectedBytes: Int64
    /// Legacy total: moved bytes in real mode, previewed bytes in preview mode.
    public var totalBytes: Int64
    /// Whether this result came from a read-only preview run.
    public var previewOnly: Bool
    /// Whether cancellation stopped the run before all selected items were processed.
    public var cancelled: Bool
    public var movedBytes: Int64
    public var failedBytes: Int64
    public var remainingBytes: Int64
    public var selectedCount: Int
    public var notProcessed: Int
    public var elapsed: TimeInterval

    public init(trashed: [CleanupItem] = [],
                failures: [CleanupFailure] = [],
                previewed: [CleanupItem] = [],
                candidateBytes: Int64 = 0,
                selectedBytes: Int64 = 0,
                totalBytes: Int64 = 0,
                previewOnly: Bool = false,
                cancelled: Bool = false,
                movedBytes: Int64 = 0,
                failedBytes: Int64 = 0,
                remainingBytes: Int64 = 0,
                selectedCount: Int = 0,
                notProcessed: Int = 0,
                elapsed: TimeInterval = 0) {
        self.trashed = trashed
        self.failures = failures
        self.previewed = previewed
        self.candidateBytes = candidateBytes
        self.selectedBytes = selectedBytes
        self.totalBytes = totalBytes
        self.previewOnly = previewOnly
        self.cancelled = cancelled
        self.movedBytes = movedBytes
        self.failedBytes = failedBytes
        self.remainingBytes = remainingBytes
        self.selectedCount = selectedCount
        self.notProcessed = notProcessed
        self.elapsed = elapsed
    }

    public var failedCount: Int { failures.count }
    public var succeededCount: Int { trashed.count + previewed.count }
    public var processedCount: Int { succeededCount + failedCount }
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
    private var cancellationRequested = false

    public static let shared = CleanupEngine()

    public init() {}

    /// Request cancellation between selected items. The current Trash API
    /// call is allowed to finish; no later item is touched.
    public func cancel() {
        cancellationRequested = true
    }

    /// True when any application whose bundle path equals `path` (or a parent
    /// bundle containing it) is currently running. The uninstaller refuses to
    /// remove running apps.
    public nonisolated static func isAppRunning(bundlePath path: String) -> Bool {
        guard PathSafety.isAppBundle(path) else { return false }
        let runningURLs = NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleURL?.standardizedFileURL.path }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return runningURLs.contains(candidate)
    }

    /// Validate a single candidate right before trashing. Returns the accepted
    /// path or throws the first blocking reason.
    public static func revalidate(item: CleanupItem,
                                  root: String,
                                  allowBundles: Bool,
                                  allowedRoots: [String] = []) throws -> CleanupItem {
        let purpose: PathSafety.FilePurpose = .cleanup
        if !allowedRoots.isEmpty {
            let isAllowed = allowedRoots.contains { PathSafety.isPath(item.path, inside: $0) }
            guard isAllowed else {
                throw CleanupError.unsafeItem(NSLocalizedString("cleanup.error.category_root", comment: "") + " \(item.path)")
            }
        }
        let expectedDevice: dev_t? = item.device > 0 ? dev_t(item.device) : nil
        let result = PathSafety.validate(
            path: item.path,
            root: root,
            expectedDevice: expectedDevice,
            purpose: purpose,
            allowSymlink: false
        )
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
            if validated.kind == .regularFile,
               let linkCount = Crypto.linkCount(of: validated.canonical),
               linkCount > 1 {
                throw CleanupError.unsafeItem(
                    NSLocalizedString("cleanup.error.hard_link_selection", comment: "") + " \(validated.canonical)"
                )
            }
            if item.inode != 0 {
                guard let identity = Crypto.inode(of: validated.canonical),
                      UInt64(identity.1) == item.inode else {
                    throw CleanupError.unsafeItem(NSLocalizedString("validate.failure.identity", comment: ""))
                }
            }
            return CleanupItem(
                id: item.id,
                path: validated.canonical,
                size: item.size,
                kind: item.kind,
                device: item.device,
                inode: item.inode
            )
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
        allowedRoots: [String] = [],
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) async -> CleanupResult {
        cancellationRequested = false
        isRunning = true
        defer {
            isRunning = false
            currentItem = nil
        }

        let start = Date()
        var result = CleanupResult(previewOnly: previewOnly, selectedCount: items.count)
        result.candidateBytes = CleanupAccounting.uniqueBytes(for: items)
        result.selectedBytes = result.candidateBytes
        let total = max(items.count, 1)
        let fileManager = FileManager.default
        var measuredSizes: [String: Int64] = [:]
        func reconcile() async {
            let trashed = result.trashed
            let failures = result.failures
            let sizes = measuredSizes
            let breakdown = await Task.detached(priority: .utility) {
                CleanupAccounting.reconcile(
                    selected: items,
                    moved: trashed.map(\.path),
                    failed: failures.map { ($0.path, $0.reason) },
                    sizeOverrides: sizes
                )
            }.value
            result.candidateBytes = breakdown.candidateBytes
            result.selectedBytes = breakdown.selectedBytes
            result.movedBytes = breakdown.movedBytes
            result.failedBytes = breakdown.failedBytes
            result.remainingBytes = breakdown.remainingBytes
            result.totalBytes = previewOnly
                ? CleanupAccounting.uniqueBytes(for: result.previewed)
                : breakdown.movedBytes
        }

        for (index, item) in items.enumerated() {
            if isCancelled() || cancellationRequested {
                result.cancelled = true
                result.notProcessed = items.count - index
                await reconcile()
                result.elapsed = Date().timeIntervalSince(start)
                progress(1, nil)
                return result
            }
            progress(Double(index) / Double(total), item.path)

            // Immediate revalidation before any filesystem mutation.
            do {
                let safeItem = try await Task.detached(priority: .utility) {
                    try Self.revalidate(
                        item: item,
                        root: root,
                        allowBundles: allowBundles,
                        allowedRoots: allowedRoots
                    )
                }.value
                currentItem = safeItem.path

                let currentSize = await Task.detached(priority: .utility) {
                    CleanupAccounting.currentAllocatedBytes(at: safeItem.path, fallback: safeItem.size)
                }.value
                measuredSizes[safeItem.path] = currentSize
                if previewOnly {
                    result.previewed.append(CleanupItem(
                        id: safeItem.id,
                        path: safeItem.path,
                        size: currentSize,
                        kind: safeItem.kind,
                        device: safeItem.device,
                        inode: safeItem.inode
                    ))
                    result.totalBytes = CleanupAccounting.adding(result.totalBytes, currentSize)
                } else {
                    let destinationPath = try await Task.detached(priority: .userInitiated) {
                        var resultingURL: NSURL?
                        try fileManager.trashItem(
                            at: URL(fileURLWithPath: safeItem.path),
                            resultingItemURL: &resultingURL
                        )
                        return (resultingURL as URL?)?.path
                    }.value
                    guard let destinationPath,
                          FileManager.default.fileExists(atPath: destinationPath) else {
                        throw CleanupMoveError.destinationNotVerified(safeItem.path)
                    }
                    result.trashed.append(CleanupItem(
                        id: safeItem.id,
                        path: safeItem.path,
                        size: currentSize,
                        kind: safeItem.kind,
                        device: safeItem.device,
                        inode: safeItem.inode
                    ))
                    result.movedBytes = CleanupAccounting.adding(result.movedBytes, currentSize)
                    result.totalBytes = CleanupAccounting.adding(result.totalBytes, currentSize)
                }
            } catch {
                result.failures.append(CleanupFailure(path: item.path, reason: error.localizedDescription))
                result.failedBytes = CleanupAccounting.adding(result.failedBytes, max(item.size, 0))
            }
            // Give a toolbar cancellation request a chance between items.
            await Task.yield()
        }

        await reconcile()
        progress(1, nil)
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }

    /// Convenience preview-only pass used by "Preview Cleanup" buttons.
    public func preview(items: [CleanupItem], root: String) async -> CleanupResult {
        await clean(items: items, root: root, previewOnly: true, progress: { _, _ in }, isCancelled: { false })
    }
}
