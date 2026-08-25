//
//  SpaceLensEngine.swift
//  SalmanMacCleaner
//
//  Builds the hierarchical storage tree behind Space Lens from actual measured
//  inventory. Traversal is bounded, symlink-safe, cooperative on cancellation,
//  and reports honest partial or denied states instead of zero KB for unscanned roots.
//

import Foundation

public struct SpaceLensNode: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var path: String
    public var allocatedBytes: Int64
    public var fileCount: Int
    public var isDirectory: Bool
    public var children: [SpaceLensNode]
    /// When true this node aggregates children that were below the cap.
    public var isAggregate: Bool
    public var isSystemProtected: Bool
    public var isDenied: Bool

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                allocatedBytes: Int64,
                fileCount: Int = 0,
                isDirectory: Bool,
                children: [SpaceLensNode] = [],
                isAggregate: Bool = false,
                isSystemProtected: Bool = false,
                isDenied: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.children = children
        self.isAggregate = isAggregate
        self.isSystemProtected = isSystemProtected
        self.isDenied = isDenied
    }

    public var totalBytes: Int64 {
        allocatedBytes + children.reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    public var totalFiles: Int {
        fileCount + children.reduce(0) { $0 + $1.totalFiles }
    }
}

public struct SpaceLensProgress: Equatable {
    public var currentPath: String
    public var filesScanned: Int
    public var bytesIndexed: Int64
    public var elapsed: TimeInterval
    public var inaccessibleCount: Int

    public init(currentPath: String = "",
                filesScanned: Int = 0,
                bytesIndexed: Int64 = 0,
                elapsed: TimeInterval = 0,
                inaccessibleCount: Int = 0) {
        self.currentPath = currentPath
        self.filesScanned = filesScanned
        self.bytesIndexed = bytesIndexed
        self.elapsed = elapsed
        self.inaccessibleCount = inaccessibleCount
    }
}

public enum SpaceLensRootState: Equatable {
    case notScanned
    case scanning(currentPath: String, files: Int, bytes: Int64, elapsed: TimeInterval, inaccessible: Int)
    case partial(deniedPaths: Int, errors: Int)
    case denied(reason: String)
    case measured(bytes: Int64, fileCount: Int)

    public var title: String {
        switch self {
        case .notScanned: return NSLocalizedString("space_lens.state.not_scanned", comment: "")
        case .scanning: return NSLocalizedString("space_lens.state.scanning", comment: "")
        case .partial: return NSLocalizedString("space_lens.state.partial", comment: "")
        case .denied: return NSLocalizedString("space_lens.state.denied", comment: "")
        case .measured(let bytes, _): return FileUtilities.formattedBytes(bytes)
        }
    }
}

public final class SpaceLensCache: @unchecked Sendable {
    public static let shared = SpaceLensCache()
    private let lock = NSLock()
    private var cache: [String: SpaceLensNode] = [:]

    public func node(for path: String) -> SpaceLensNode? {
        lock.lock()
        defer { lock.unlock() }
        return cache[path]
    }

    public func setNode(_ node: SpaceLensNode, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[path] = node
    }

    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: path)
    }

    public func invalidateAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }
}

public enum SpaceLensEngine {

    /// Reference storage avoids overlapping `inout` access when recursive
    /// traversal reports progress from inside the same call stack.
    private final class ScanMetrics {
        var filesScanned = 0
        var bytesIndexed: Int64 = 0
        var inaccessibleCount = 0
    }

    /// Maximum children kept per level before "Other" aggregation.
    public static let childrenCap = 48

    /// Check if a path is system-protected.
    public static func isSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System") || path.hasPrefix("/usr") || path.hasPrefix("/bin")
            || path.hasPrefix("/sbin") || path.hasPrefix("/private/var")
    }

    /// Build a storage tree for `root`. Depth is bounded; hidden files and
    /// packages are toggled by the caller.
    public static func buildTree(
        root: URL,
        includeHidden: Bool,
        includePackageContents: Bool,
        maxDepth: Int = 6,
        progress: @escaping (SpaceLensProgress) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) -> (node: SpaceLensNode, state: SpaceLensRootState) {
        let startTime = Date()
        let metrics = ScanMetrics()

        func reportProgress(currentPath: String) {
            let elapsed = Date().timeIntervalSince(startTime)
            progress(SpaceLensProgress(
                currentPath: currentPath,
                filesScanned: metrics.filesScanned,
                bytesIndexed: metrics.bytesIndexed,
                elapsed: elapsed,
                inaccessibleCount: metrics.inaccessibleCount
            ))
        }

        let node = measureDirectory(
            url: root,
            depth: 0,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            includePackageContents: includePackageContents,
            metrics: metrics,
            reportProgress: reportProgress,
            isCancelled: isCancelled
        )

        let state: SpaceLensRootState
        if node.isDenied && node.totalBytes == 0 {
            state = .denied(reason: NSLocalizedString("space_lens.error.denied", comment: ""))
        } else if metrics.inaccessibleCount > 0 {
            state = .partial(deniedPaths: metrics.inaccessibleCount, errors: 0)
        } else {
            state = .measured(bytes: node.totalBytes, fileCount: node.totalFiles)
        }

        SpaceLensCache.shared.setNode(node, for: root.standardizedFileURL.path)
        return (node, state)
    }

    private static func measureDirectory(
        url: URL,
        depth: Int,
        maxDepth: Int,
        includeHidden: Bool,
        includePackageContents: Bool,
        metrics: ScanMetrics,
        reportProgress: (String) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> SpaceLensNode {
        let path = url.standardizedFileURL.path
        let isSystem = isSystemPath(path)

        if isCancelled() {
            return SpaceLensNode(
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                path: path,
                allocatedBytes: 0,
                fileCount: 0,
                isDirectory: true,
                isSystemProtected: isSystem
            )
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .fileSizeKey, .fileAllocatedSizeKey, .isHiddenKey
        ]

        guard depth < maxDepth else {
            return SpaceLensNode(
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                path: path,
                allocatedBytes: 0,
                fileCount: 0,
                isDirectory: true,
                isSystemProtected: isSystem
            )
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            metrics.inaccessibleCount += 1
            return SpaceLensNode(
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                path: path,
                allocatedBytes: 0,
                fileCount: 0,
                isDirectory: true,
                isSystemProtected: isSystem,
                isDenied: true
            )
        }

        reportProgress(path)

        var ownBytes: Int64 = 0
        var ownFiles = 0
        var childNodes: [SpaceLensNode] = []
        var aggregateBytes: Int64 = 0
        var aggregateFiles = 0
        var aggregateChildren: [SpaceLensNode] = []

        for entry in entries {
            if isCancelled() { break }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                metrics.inaccessibleCount += 1
                continue
            }
            if values.isSymbolicLink == true { continue }

            let name = entry.lastPathComponent
            if !includeHidden && (values.isHidden ?? name.hasPrefix(".")) { continue }

            let entryPath = entry.standardizedFileURL.path
            let entryIsSystem = isSystemPath(entryPath)

            if values.isDirectory == true {
                let isPackage = values.isPackage ?? false
                if isPackage && !includePackageContents {
                    let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                    ownBytes += size
                    ownFiles += 1
                    metrics.filesScanned += 1
                    metrics.bytesIndexed += size
                    continue
                }
                let child = measureDirectory(
                    url: entry,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    includeHidden: includeHidden,
                    includePackageContents: includePackageContents,
                    metrics: metrics,
                    reportProgress: reportProgress,
                    isCancelled: isCancelled
                )
                childNodes.append(child)
            } else if values.isRegularFile == true {
                let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                ownBytes += size
                ownFiles += 1
                metrics.filesScanned += 1
                metrics.bytesIndexed += size
                if metrics.filesScanned % 150 == 0 {
                    reportProgress(entryPath)
                }
            }
        }

        // Cap children; heaviest first, rest into an aggregate "Other" node.
        childNodes.sort { $0.totalBytes > $1.totalBytes }
        if childNodes.count > childrenCap {
            let kept = Array(childNodes.prefix(childrenCap))
            let rest = Array(childNodes.dropFirst(childrenCap))
            aggregateChildren = rest
            aggregateBytes = rest.reduce(Int64(0)) { $0 + $1.totalBytes }
            aggregateFiles = rest.reduce(0) { $0 + $1.totalFiles }
            childNodes = kept
            if aggregateBytes > 0 {
                childNodes.append(SpaceLensNode(
                    name: NSLocalizedString("space_lens.other", comment: ""),
                    path: path,
                    allocatedBytes: aggregateBytes,
                    fileCount: aggregateFiles,
                    isDirectory: true,
                    children: aggregateChildren,
                    isAggregate: true,
                    isSystemProtected: isSystem
                ))
            }
        }

        return SpaceLensNode(
            name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
            path: path,
            allocatedBytes: ownBytes,
            fileCount: ownFiles,
            isDirectory: true,
            children: childNodes,
            isSystemProtected: isSystem
        )
    }
}
