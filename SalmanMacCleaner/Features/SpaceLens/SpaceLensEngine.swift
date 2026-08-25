//
//  SpaceLensEngine.swift
//  SalmanMacCleaner
//
//  Builds the hierarchical storage tree behind Space Lens. Children are
//  capped per level (heaviest first); the rest are aggregated into an
//  "Other" node that can itself be drilled into. Allocated size is preferred
//  for proportions. Traversal is bounded and symlink-safe.
//

import Foundation

public struct SpaceLensNode: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var path: String
    public var allocatedBytes: Int64
    public var isDirectory: Bool
    public var children: [SpaceLensNode]
    /// When true this node aggregates children that were below the cap.
    public var isAggregate: Bool

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                allocatedBytes: Int64,
                isDirectory: Bool,
                children: [SpaceLensNode] = [],
                isAggregate: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.isDirectory = isDirectory
        self.children = children
        self.isAggregate = isAggregate
    }

    public var totalBytes: Int64 {
        allocatedBytes + children.reduce(0) { $0 + $1.allocatedBytes }
    }
}

public enum SpaceLensEngine {

    /// Maximum children kept per level before "Other" aggregation.
    public static let childrenCap = 48

    /// Build a storage tree for `root`. Depth is bounded; hidden files and
    /// packages are toggled by the caller. Runs off the main actor.
    public static func buildTree(
        root: URL,
        includeHidden: Bool,
        includePackageContents: Bool,
        maxDepth: Int = 6,
        isCancelled: @escaping () -> Bool = { false }
    ) -> SpaceLensNode {
        measureDirectory(
            url: root,
            depth: 0,
            maxDepth: maxDepth,
            includeHidden: includeHidden,
            includePackageContents: includePackageContents,
            isCancelled: isCancelled
        )
    }

    private static func measureDirectory(
        url: URL,
        depth: Int,
        maxDepth: Int,
        includeHidden: Bool,
        includePackageContents: Bool,
        isCancelled: @escaping () -> Bool
    ) -> SpaceLensNode {
        let path = url.standardizedFileURL.path
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .fileSizeKey, .fileAllocatedSizeKey, .isHiddenKey
        ]

        guard depth < maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: keys,
                  options: [.skipsSubdirectoryDescendants]
              ) else {
            return SpaceLensNode(name: url.lastPathComponent, path: path,
                                 allocatedBytes: 0, isDirectory: true)
        }

        var ownBytes: Int64 = 0
        var childNodes: [SpaceLensNode] = []
        var aggregateBytes: Int64 = 0
        var aggregateChildren: [SpaceLensNode] = []

        for entry in entries {
            if isCancelled() { break }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }

            let name = entry.lastPathComponent
            if !includeHidden && (values.isHidden ?? name.hasPrefix(".")) { continue }

            if values.isDirectory == true {
                let isPackage = values.isPackage ?? false
                if isPackage && !includePackageContents {
                    ownBytes += Int64(values.fileAllocatedSize ?? 0)
                    continue
                }
                let child = measureDirectory(
                    url: entry,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    includeHidden: includeHidden,
                    includePackageContents: includePackageContents,
                    isCancelled: isCancelled
                )
                childNodes.append(child)
            } else if values.isRegularFile == true {
                ownBytes += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }

        // Cap children; heaviest first, rest into an aggregate "Other" node.
        childNodes.sort { $0.totalBytes > $1.totalBytes }
        if childNodes.count > childrenCap {
            let kept = Array(childNodes.prefix(childrenCap))
            let rest = Array(childNodes.dropFirst(childrenCap))
            aggregateChildren = rest
            aggregateBytes = rest.reduce(0) { $0 + $1.totalBytes }
            childNodes = kept
            if aggregateBytes > 0 {
                childNodes.append(SpaceLensNode(
                    name: NSLocalizedString("space_lens.other", comment: ""),
                    path: path,
                    allocatedBytes: aggregateBytes,
                    isDirectory: true,
                    children: aggregateChildren,
                    isAggregate: true
                ))
            }
        }

        return SpaceLensNode(
            name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
            path: path,
            allocatedBytes: ownBytes,
            isDirectory: true,
            children: childNodes
        )
    }
}
