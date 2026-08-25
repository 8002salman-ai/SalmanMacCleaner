//
//  DeveloperCacheScanner.swift
//  SalmanMacCleaner
//
//  Scans well-known developer tool caches: Xcode DerivedData, Archives,
//  Simulator data, SwiftPM, CocoaPods, npm, Yarn, pnpm, Gradle, Maven,
//  Cargo, pip and Homebrew. Read-only discovery with category grouping and
//  preview-first cleanup. Personal and protected locations are never
//  traversed.
//

import Foundation

/// Category identifiers for every supported tool.
public enum DeveloperCacheCategory: String, CaseIterable, Identifiable, Codable {
    case derivedData
    case archives
    case simulatorData
    case swiftPM
    case cocoapods
    case npm
    case yarn
    case pnpm
    case gradle
    case maven
    case cargo
    case pip
    case homebrew

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .derivedData: return NSLocalizedString("devcat.derived_data", comment: "")
        case .archives: return NSLocalizedString("devcat.archives", comment: "")
        case .simulatorData: return NSLocalizedString("devcat.simulator", comment: "")
        case .swiftPM: return "SwiftPM"
        case .cocoapods: return "CocoaPods"
        case .npm: return "npm"
        case .yarn: return "Yarn"
        case .pnpm: return "pnpm"
        case .gradle: return "Gradle"
        case .maven: return "Maven"
        case .cargo: return "Cargo"
        case .pip: return "pip"
        case .homebrew: return "Homebrew"
        }
    }

    public var systemImage: String {
        switch self {
        case .derivedData: return "hammer"
        case .archives: return "archivebox"
        case .simulatorData: return "iphone"
        case .swiftPM: return "swift"
        case .cocoapods: return "shippingbox"
        case .npm: return "cube.box"
        case .yarn: return "circle.hexagongrid"
        case .pnpm: return "square.stack.3d.up"
        case .gradle: return "gearshape.2"
        case .maven: return "arrow.triangle.branch"
        case .cargo: return "box.truck"
        case .pip: return "drop"
        case .homebrew: return "mug"
        }
    }

    /// The concrete on-disk locations probed for this category (relative to
    /// the user's home directory).
    public var candidatePaths: [String] {
        let home = PathSafety.userHome.path
        switch self {
        case .derivedData:
            return [home + "/Library/Developer/Xcode/DerivedData"]
        case .archives:
            return [home + "/Library/Developer/Xcode/Archives"]
        case .simulatorData:
            return [home + "/Library/Developer/CoreSimulator"]
        case .swiftPM:
            return [
                home + "/Library/org.swift.swiftpm",
                home + "/Library/Caches/org.swift.swiftpm"
            ]
        case .cocoapods:
            return [home + "/Library/Caches/CocoaPods"]
        case .npm:
            return [home + "/.npm"]
        case .yarn:
            return [
                home + "/Library/Caches/Yarn",
                home + "/.yarn"
            ]
        case .pnpm:
            return [home + "/Library/Caches/pnpm"]
        case .gradle:
            return [home + "/.gradle"]
        case .maven:
            return [home + "/.m2/repository"]
        case .cargo:
            return [home + "/.cargo/registry"]
        case .pip:
            return [home + "/Library/Caches/pip"]
        case .homebrew:
            return [home + "/Library/Caches/Homebrew"]
        }
    }

    /// True when a discovered entry is eligible for cleanup (min age, min size).
    public var minEntryAgeDays: Int {
        switch self {
        case .derivedData, .archives, .simulatorData: return 0
        default: return 7
        }
    }

    public var minEntryBytes: Int64 {
        switch self {
        case .pip, .homebrew, .npm, .yarn, .pnpm: return 1
        default: return 0
        }
    }
}

public enum DeveloperCacheScanError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

public enum DeveloperCacheScanner {

    /// Scan every supported category and return grouped entries.
    public static func scan(
        categories: Set<DeveloperCacheCategory> = Set(DeveloperCacheCategory.allCases),
        maxAgeDays: Int = 90,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> [DeveloperCacheEntry] {
        var entries: [DeveloperCacheEntry] = []
        let activeCategories = categories.isEmpty ? Set(DeveloperCacheCategory.allCases) : categories
        let total = max(activeCategories.count, 1)
        var done = 0

        for category in activeCategories {
            if isCancelled() { throw DeveloperCacheScanError.cancelled }
            done += 1
            progress(Double(done) / Double(total), category.title)
            entries.append(contentsOf: scanCategory(category, maxAgeDays: maxAgeDays, isCancelled: isCancelled))
        }
        entries.sort { $0.size > $1.size }
        return entries
    }

    /// Scan a single category. Directory entries are measured (shallow + one
    /// extra level for DerivedData), file entries are validated individually.
    public static func scanCategory(
        _ category: DeveloperCacheCategory,
        maxAgeDays: Int,
        progress: ((Double, String?) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [DeveloperCacheEntry] {
        let minAge = max(category.minEntryAgeDays, maxAgeDays)
        var entries: [DeveloperCacheEntry] = []
        let now = Date()

        for candidate in category.candidatePaths {
            if isCancelled() { return entries }
            let safe = PathSafety.validate(
                path: candidate,
                root: PathSafety.userHome.path,
                purpose: .explicitDeveloperCache,
                allowSymlink: false
            )
            guard case .success(let validated) = safe else { continue }
            guard validated.kind == .directory else { continue }
            guard !PathSafety.isPersonalDirectory(validated.canonical) else { continue }

            let url = URL(fileURLWithPath: validated.canonical, isDirectory: true)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for child in children {
                if isCancelled() { return entries }
                let childPath = child.path
                let childSafe = PathSafety.validate(
                    path: childPath,
                    root: PathSafety.userHome.path,
                    purpose: .explicitDeveloperCache,
                    allowSymlink: false
                )
                guard case .success(let validatedChild) = childSafe else { continue }
                guard !validatedChild.isSymlink else { continue }
                guard !PathSafety.isAppBundle(validatedChild.canonical) else { continue }

                let name = URL(fileURLWithPath: validatedChild.canonical).lastPathComponent
                if PathSafety.isProtectedFile(name: name, purpose: .explicitDeveloperCache) { continue }

                let isDirectory = validatedChild.kind == .directory
                let size: Int64
                if isDirectory {
                    size = measuredDirectorySize(at: URL(fileURLWithPath: validatedChild.canonical, isDirectory: true))
                } else {
                    size = FileUtilities.fileSize(atPath: validatedChild.canonical)
                }
                guard size >= category.minEntryBytes else { continue }

                let modified = FileUtilities.modificationDate(atPath: validatedChild.canonical) ?? .distantPast
                guard modified < now.addingTimeInterval(-Double(minAge) * 86_400) else { continue }

                entries.append(DeveloperCacheEntry(
                    category: category.rawValue,
                    name: name,
                    path: validatedChild.canonical,
                    size: size,
                    modified: modified,
                    isDirectory: isDirectory
                ))
            }
        }
        return entries
    }

    /// Bounded directory measurement: direct children only, never descending
    /// into other devices, never following symlinks.
    private static func measuredDirectorySize(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for child in contents {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Human-friendly safety note for a category (shown next to its results).
    public static func safetyNote(for category: DeveloperCacheCategory) -> String {
        switch category {
        case .derivedData:
            return NSLocalizedString("devcat.note.derived_data", comment: "")
        case .archives:
            return NSLocalizedString("devcat.note.archives", comment: "")
        case .simulatorData:
            return NSLocalizedString("devcat.note.simulator", comment: "")
        default:
            return NSLocalizedString("devcat.note.default", comment: "")
        }
    }
}
