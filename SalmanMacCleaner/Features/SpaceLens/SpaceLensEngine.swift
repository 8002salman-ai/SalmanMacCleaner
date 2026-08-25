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
    /// The node was measured to a configured depth but not recursively
    /// expanded. It is still measured, never an unscanned zero placeholder.
    public var isTruncated: Bool

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                allocatedBytes: Int64,
                fileCount: Int = 0,
                isDirectory: Bool,
                children: [SpaceLensNode] = [],
                isAggregate: Bool = false,
                isSystemProtected: Bool = false,
                isDenied: Bool = false,
                isTruncated: Bool = false) {
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
        self.isTruncated = isTruncated
    }

    public var totalBytes: Int64 {
        children.reduce(max(allocatedBytes, 0)) { CleanupAccounting.adding($0, $1.totalBytes) }
    }

    public var totalFiles: Int {
        children.reduce(max(fileCount, 0)) { $0 > Int.max - $1.totalFiles ? Int.max : $0 + $1.totalFiles }
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

    public func node(for path: String,
                     includeHidden: Bool = false,
                     includePackageContents: Bool = false) -> SpaceLensNode? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key(path: path, includeHidden: includeHidden, includePackageContents: includePackageContents)]
    }

    public func setNode(_ node: SpaceLensNode,
                        for path: String,
                        includeHidden: Bool = false,
                        includePackageContents: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        cache[key(path: path, includeHidden: includeHidden, includePackageContents: includePackageContents)] = node
    }

    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        cache = cache.filter { !$0.key.hasPrefix(Self.pathPrefix(path)) }
    }

    private func key(path: String, includeHidden: Bool, includePackageContents: Bool) -> String {
        Self.pathPrefix(path) + "|hidden=\(includeHidden ? 1 : 0)|packages=\(includePackageContents ? 1 : 0)"
    }

    private static func pathPrefix(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path + "|"
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
        var truncatedCount = 0
        var directoriesVisited = 0
        var seenPhysicalFiles = Set<String>()
        var seenDirectories = Set<String>()
    }

    /// Maximum children kept per level before "Other" aggregation.
    public static let childrenCap = 48

    /// Check if a path is system-protected.
    public static func isSystemPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let protectedRoots = ["/System", "/usr", "/bin", "/sbin", "/private/var"]
        return protectedRoots.contains(where: { standardized == $0 || standardized.hasPrefix($0 + "/") })
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
        let rootPath = root.standardizedFileURL.path

        guard FileManager.default.fileExists(atPath: rootPath),
              PathSafety.kind(of: rootPath) == .directory else {
            let denied = SpaceLensNode(
                name: root.lastPathComponent.isEmpty ? rootPath : root.lastPathComponent,
                path: rootPath,
                allocatedBytes: 0,
                isDirectory: true,
                isDenied: true
            )
            return (denied, .denied(reason: NSLocalizedString("space_lens.error.denied", comment: "")))
        }

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
            url: URL(fileURLWithPath: rootPath, isDirectory: true),
            depth: 0,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            includePackageContents: includePackageContents,
            metrics: metrics,
            reportProgress: reportProgress,
            isCancelled: isCancelled
        )

        let state: SpaceLensRootState
        if isCancelled() {
            state = .partial(deniedPaths: metrics.inaccessibleCount, errors: max(metrics.truncatedCount, 1))
        } else if node.isDenied && node.totalBytes == 0 {
            state = .denied(reason: NSLocalizedString("space_lens.error.denied", comment: ""))
        } else if metrics.inaccessibleCount > 0 || metrics.truncatedCount > 0 {
            state = .partial(deniedPaths: metrics.inaccessibleCount, errors: metrics.truncatedCount)
        } else {
            state = .measured(bytes: node.totalBytes, fileCount: node.totalFiles)
        }

        if !isCancelled() {
            SpaceLensCache.shared.setNode(
                node,
                for: rootPath,
                includeHidden: includeHidden,
                includePackageContents: includePackageContents
            )
        }
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
        metrics.directoriesVisited += 1
        guard metrics.directoriesVisited <= 100_000 else {
            metrics.truncatedCount += 1
            return SpaceLensNode(
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                path: path,
                allocatedBytes: 0,
                isDirectory: true,
                isSystemProtected: isSystem,
                isTruncated: true
            )
        }

        if let identity = Crypto.inode(of: path) {
            let key = "\(identity.0):\(identity.1)"
            guard metrics.seenDirectories.insert(key).inserted else {
                metrics.truncatedCount += 1
                // A repeated directory identity is a cycle/alias. It is not
                // an unknown zero-sized scan result; it was intentionally
                // skipped to avoid counting the same subtree twice.
                return SpaceLensNode(
                    name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                    path: path,
                    allocatedBytes: 0,
                    isDirectory: true,
                    isSystemProtected: isSystem,
                    isTruncated: true
                )
            }
        }

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
            metrics.truncatedCount += 1
            return measureShallowDirectory(
                url: url,
                includeHidden: includeHidden,
                metrics: metrics,
                isSystemProtected: isSystem,
                reportProgress: reportProgress,
                isCancelled: isCancelled
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

        for (entryIndex, entry) in entries.enumerated() {
            if entryIndex >= 10_000 {
                metrics.truncatedCount += 1
                break
            }
            if isCancelled() { break }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                metrics.inaccessibleCount += 1
                continue
            }
            if values.isSymbolicLink == true { continue }

            let name = entry.lastPathComponent
            if !includeHidden && (values.isHidden ?? name.hasPrefix(".")) { continue }

            let entryPath = entry.standardizedFileURL.path

            if values.isDirectory == true {
                let isPackage = values.isPackage ?? false
                if isPackage && !includePackageContents {
                    // Package metadata is not the package's disk usage. Measure
                    // its contents through the same bounded, link-safe walker,
                    // then present it as a collapsed node so the toggle only
                    // controls presentation, never the reported bytes.
                    let truncationsBefore = metrics.truncatedCount
                    let measured = measureDirectory(
                        url: entry,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        includeHidden: includeHidden,
                        includePackageContents: true,
                        metrics: metrics,
                        reportProgress: reportProgress,
                        isCancelled: isCancelled
                    )
                    childNodes.append(SpaceLensNode(
                        name: name,
                        path: entryPath,
                        allocatedBytes: measured.totalBytes,
                        fileCount: measured.totalFiles,
                        isDirectory: true,
                        isTruncated: metrics.truncatedCount > truncationsBefore
                    ))
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
                if let identity = Crypto.inode(of: entryPath) {
                    let key = "\(identity.0):\(identity.1)"
                    guard metrics.seenPhysicalFiles.insert(key).inserted else { continue }
                }
                ownBytes = CleanupAccounting.adding(ownBytes, max(size, 0))
                ownFiles += 1
                metrics.filesScanned += 1
                metrics.bytesIndexed = CleanupAccounting.adding(metrics.bytesIndexed, max(size, 0))
                if metrics.filesScanned % 150 == 0 {
                    reportProgress(entryPath)
                }
            }
        }

        // Cap children; heaviest first, rest into an aggregate "Other" node.
        childNodes.sort {
            if $0.totalBytes == $1.totalBytes { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.totalBytes > $1.totalBytes
        }
        if childNodes.count > childrenCap {
            let kept = Array(childNodes.prefix(childrenCap))
            let rest = Array(childNodes.dropFirst(childrenCap))
            aggregateChildren = rest
            aggregateBytes = rest.reduce(Int64(0)) { CleanupAccounting.adding($0, $1.totalBytes) }
            aggregateFiles = rest.reduce(0) { count, child in
                count > Int.max - child.totalFiles ? Int.max : count + child.totalFiles
            }
            childNodes = kept
            if aggregateBytes > 0 {
                // The aggregate owns the rest of the child nodes; storing
                // both their sum and their children would double-count them.
                childNodes.append(SpaceLensNode(
                    name: NSLocalizedString("space_lens.other", comment: ""),
                    path: path + "/__other__",
                    allocatedBytes: 0,
                    fileCount: 0,
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

    /// Measure files directly below a depth boundary. This preserves real
    /// bytes and an explicit partial state rather than manufacturing a
    /// "Zero KB" child for work that was not expanded.
    private static func measureShallowDirectory(
        url: URL,
        includeHidden: Bool,
        metrics: ScanMetrics,
        isSystemProtected: Bool,
        reportProgress: (String) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> SpaceLensNode {
        let path = url.standardizedFileURL.path
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey,
            .fileSizeKey, .fileAllocatedSizeKey
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            metrics.inaccessibleCount += 1
            return SpaceLensNode(
                name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
                path: path,
                allocatedBytes: 0,
                isDirectory: true,
                isSystemProtected: isSystemProtected,
                isDenied: true,
                isTruncated: true
            )
        }

        var bytes: Int64 = 0
        var files = 0
        for (entryIndex, entry) in entries.enumerated() {
            guard entryIndex < 10_000 else {
                metrics.truncatedCount += 1
                break
            }
            guard !isCancelled() else { break }
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let name = entry.lastPathComponent
            if !includeHidden && (values.isHidden ?? name.hasPrefix(".")) { continue }
            let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            if let identity = Crypto.inode(of: entry.path) {
                let key = "\(identity.0):\(identity.1)"
                guard metrics.seenPhysicalFiles.insert(key).inserted else { continue }
            }
            bytes = CleanupAccounting.adding(bytes, max(size, 0))
            files += 1
            metrics.filesScanned += 1
            metrics.bytesIndexed = CleanupAccounting.adding(metrics.bytesIndexed, max(size, 0))
        }
        reportProgress(path)
        return SpaceLensNode(
            name: url.lastPathComponent.isEmpty ? path : url.lastPathComponent,
            path: path,
            allocatedBytes: bytes,
            fileCount: files,
            isDirectory: true,
            isSystemProtected: isSystemProtected,
            isTruncated: true
        )
    }
}
