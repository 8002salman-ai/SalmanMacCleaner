//
//  DeveloperCacheScanner.swift
//  SalmanMacCleaner
//
//  Read-only, allowlisted developer-cache discovery. Tool names alone never
//  produce candidates: an entry is returned only when an allowed path exists,
//  is inside the current user's home, is owned by that user, and can be
//  measured without following links or entering projects/user data.
//

import Foundation

public enum DeveloperCacheCategory: String, CaseIterable, Identifiable, Codable {
    case derivedData
    case archives
    case xcodeDeviceSupport
    case simulatorCache
    case swiftPM
    case cocoapods
    case npm
    case yarn
    case pnpm
    case homebrew
    case macPorts
    case docker
    case gradle
    case android
    case flutter
    case reactNative
    case cargo
    case go
    case python
    case composer
    case maven
    case unity
    case unreal

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .derivedData: return NSLocalizedString("devcat.derived_data", comment: "")
        case .archives: return NSLocalizedString("devcat.archives", comment: "")
        case .xcodeDeviceSupport: return NSLocalizedString("devcat.device_support", comment: "")
        case .simulatorCache: return NSLocalizedString("devcat.simulator_cache", comment: "")
        case .swiftPM: return "SwiftPM"
        case .cocoapods: return "CocoaPods"
        case .npm: return "npm"
        case .yarn: return "Yarn"
        case .pnpm: return "pnpm"
        case .homebrew: return "Homebrew"
        case .macPorts: return "MacPorts"
        case .docker: return "Docker"
        case .gradle: return "Gradle"
        case .android: return "Android"
        case .flutter: return "Flutter / Dart"
        case .reactNative: return "React Native / Metro"
        case .cargo: return "Rust / Cargo"
        case .go: return "Go"
        case .python: return "Python / pip"
        case .composer: return "Composer"
        case .maven: return "Maven"
        case .unity: return "Unity"
        case .unreal: return "Unreal Engine"
        }
    }

    public var systemImage: String {
        switch self {
        case .derivedData: return "hammer"
        case .archives: return "archivebox"
        case .xcodeDeviceSupport: return "iphone.gen3"
        case .simulatorCache: return "iphone"
        case .swiftPM: return "swift"
        case .cocoapods: return "shippingbox"
        case .npm, .yarn, .pnpm: return "shippingbox.fill"
        case .homebrew, .macPorts: return "mug"
        case .docker: return "shippingbox"
        case .gradle, .android: return "gearshape.2"
        case .flutter, .reactNative: return "rectangle.3.group"
        case .cargo, .go, .python, .composer, .maven: return "chevron.left.forwardslash.chevron.right"
        case .unity, .unreal: return "cube"
        }
    }

    public var minimumEntryAgeDays: Int {
        switch self {
        case .derivedData, .simulatorCache: return 7
        case .archives, .xcodeDeviceSupport: return 30
        default: return 7
        }
    }

    /// Allowlisted cache roots. These are deliberately narrower than the
    /// tool's entire home directory, especially for Simulator, Docker, and
    /// Android where active/user data lives beside caches.
    public func candidatePaths(home: URL) -> [String] {
        let h = home.path
        switch self {
        case .derivedData: return [h + "/Library/Developer/Xcode/DerivedData"]
        case .archives: return [h + "/Library/Developer/Xcode/Archives"]
        case .xcodeDeviceSupport:
            return [
                h + "/Library/Developer/Xcode/iOS DeviceSupport",
                h + "/Library/Developer/Xcode/watchOS DeviceSupport",
                h + "/Library/Developer/Xcode/tvOS DeviceSupport",
                h + "/Library/Developer/Xcode/visionOS DeviceSupport"
            ]
        case .simulatorCache:
            // Never scan CoreSimulator/Devices or runtimes: those contain
            // active simulator and user data. Caches are the only target.
            return [h + "/Library/Developer/CoreSimulator/Caches"]
        case .swiftPM:
            return [h + "/Library/Caches/org.swift.swiftpm", h + "/Library/org.swift.swiftpm"]
        case .cocoapods: return [h + "/Library/Caches/CocoaPods"]
        case .npm: return [h + "/.npm/_cacache", h + "/.npm/_logs"]
        case .yarn: return [h + "/Library/Caches/Yarn", h + "/.yarn/berry/cache"]
        case .pnpm: return [h + "/Library/Caches/pnpm", h + "/.local/share/pnpm/store"]
        case .homebrew: return [h + "/Library/Caches/Homebrew", h + "/.cache/Homebrew"]
        case .macPorts:
            // Root-owned MacPorts locations sit under protected system paths.
            // Keep tool detection, but never expose that path as a candidate.
            return []
        case .docker:
            // Docker's VM/container data is protected. We intentionally do
            // not inspect ~/.docker because it can contain credentials.
            return []
        case .gradle: return [h + "/.gradle/caches", h + "/.gradle/wrapper/dists"]
        case .android: return [h + "/.android/cache", h + "/Library/Android/sdk/.temp"]
        case .flutter: return [h + "/.pub-cache/cache", h + "/Library/Caches/dart"]
        case .reactNative: return [h + "/Library/Caches/Metro", h + "/.metro"]
        case .cargo: return [h + "/.cargo/registry/cache", h + "/.cargo/git/db"]
        case .go: return [h + "/Library/Caches/go-build", h + "/go/pkg/mod/cache"]
        case .python: return [h + "/Library/Caches/pip", h + "/.cache/pip"]
        case .composer: return [h + "/.composer/cache"]
        case .maven: return [h + "/.m2/repository"]
        case .unity: return [h + "/Library/Unity/cache", h + "/Library/Caches/Unity"]
        case .unreal: return [h + "/Library/Application Support/Epic/UnrealEngine/Common/DerivedDataCache"]
        }
    }

    public var candidatePaths: [String] { candidatePaths(home: PathSafety.userHome) }

    /// Companion application/tool paths are used only for detection labels,
    /// never as cleanup candidates.
    public func toolEvidencePaths(home: URL) -> [String] {
        switch self {
        case .derivedData, .archives, .xcodeDeviceSupport, .simulatorCache, .swiftPM, .cocoapods:
            return ["/Applications/Xcode.app", "/System/Applications/Xcode.app"]
        case .npm: return [home.path + "/.npmrc"]
        case .yarn: return [home.path + "/.yarnrc.yml"]
        case .pnpm: return [home.path + "/.config/pnpm"]
        case .homebrew: return ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        case .macPorts: return ["/opt/local/bin/port"]
        case .docker: return ["/Applications/Docker.app"]
        case .gradle: return [home.path + "/.gradle"]
        case .android: return ["/Applications/Android Studio.app", home.path + "/Library/Android"]
        case .flutter: return [home.path + "/development/flutter", "/opt/homebrew/bin/flutter"]
        case .reactNative: return [home.path + "/node_modules/react-native"]
        case .cargo: return [home.path + "/.cargo/bin/cargo"]
        case .go: return ["/usr/local/go", "/opt/homebrew/bin/go"]
        case .python: return ["/usr/bin/python3", "/opt/homebrew/bin/python3"]
        case .composer: return ["/usr/local/bin/composer", "/opt/homebrew/bin/composer"]
        case .maven: return ["/usr/local/bin/mvn", "/opt/homebrew/bin/mvn"]
        case .unity: return ["/Applications/Unity Hub.app"]
        case .unreal: return ["/Applications/Epic Games Launcher.app"]
        }
    }
}

public struct DeveloperCacheDescriptor: Identifiable, Equatable {
    public let category: DeveloperCacheCategory
    public let existingCachePaths: [String]
    public let toolDetected: Bool

    public var id: String { category.rawValue }
    public var detected: Bool { !existingCachePaths.isEmpty }
    public var isToolOnly: Bool { existingCachePaths.isEmpty && toolDetected }

    public init(category: DeveloperCacheCategory, existingCachePaths: [String], toolDetected: Bool) {
        self.category = category
        self.existingCachePaths = existingCachePaths
        self.toolDetected = toolDetected
    }
}

public struct DeveloperCacheScanReport: Equatable {
    public var entries: [DeveloperCacheEntry]
    public var scannedPaths: [String]
    public var deniedPaths: [String]
    /// Paths whose bounded traversal stopped at the safety cap. These bytes
    /// are still useful findings, but the report must not call the scan full.
    public var truncatedPaths: [String]

    public init(entries: [DeveloperCacheEntry] = [],
                scannedPaths: [String] = [],
                deniedPaths: [String] = [],
                truncatedPaths: [String] = []) {
        self.entries = entries
        self.scannedPaths = scannedPaths
        self.deniedPaths = deniedPaths
        self.truncatedPaths = truncatedPaths
    }
}

public enum DeveloperCacheScanError: LocalizedError, Equatable {
    case cancelled
    public var errorDescription: String? {
        NSLocalizedString("scan.error.cancelled", comment: "")
    }
}

public enum DeveloperCacheScanner {

    public static func descriptors(home: URL = PathSafety.userHome) -> [DeveloperCacheDescriptor] {
        DeveloperCacheCategory.allCases.map { category in
            let existing = category.candidatePaths(home: home).filter { path in
                FileManager.default.fileExists(atPath: path)
            }
            let toolDetected = category.toolEvidencePaths(home: home).contains {
                FileManager.default.fileExists(atPath: $0)
            }
            return DeveloperCacheDescriptor(category: category, existingCachePaths: existing, toolDetected: toolDetected)
        }
    }

    public static func detectedCategories(home: URL = PathSafety.userHome) -> Set<DeveloperCacheCategory> {
        Set(descriptors(home: home).filter(\.detected).map(\.category))
    }

    /// Compatibility API used by feature coordinators.
    public static func scan(
        categories: Set<DeveloperCacheCategory> = Set(DeveloperCacheCategory.allCases),
        maxAgeDays: Int = 90,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> [DeveloperCacheEntry] {
        try scanReport(categories: categories, maxAgeDays: maxAgeDays, progress: progress, isCancelled: isCancelled).entries
    }

    public static func scanReport(
        categories: Set<DeveloperCacheCategory>,
        maxAgeDays: Int,
        home: URL = PathSafety.userHome,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> DeveloperCacheScanReport {
        let active = categories.isEmpty ? Set(DeveloperCacheCategory.allCases) : categories
        let ordered = DeveloperCacheCategory.allCases.filter { active.contains($0) }
        var report = DeveloperCacheScanReport()
        for (index, category) in ordered.enumerated() {
            if isCancelled() { throw DeveloperCacheScanError.cancelled }
            progress(Double(index) / Double(max(ordered.count, 1)), category.title)
            let result = try scanCategoryReport(
                category,
                maxAgeDays: maxAgeDays,
                home: home,
                progress: { fraction, detail in
                    let aggregate = (Double(index) + fraction) / Double(max(ordered.count, 1))
                    progress(aggregate, detail)
                },
                isCancelled: isCancelled
            )
            report.entries.append(contentsOf: result.entries)
            report.scannedPaths.append(contentsOf: result.scannedPaths)
            report.deniedPaths.append(contentsOf: result.deniedPaths)
            report.truncatedPaths.append(contentsOf: result.truncatedPaths)
        }
        report.entries.sort(by: { lhs, rhs in
            if lhs.category == rhs.category { return lhs.size > rhs.size }
            return lhs.category < rhs.category
        })
        progress(1, NSLocalizedString("devcaches.scan_complete", comment: ""))
        return report
    }

    public static func scanCategory(
        _ category: DeveloperCacheCategory,
        maxAgeDays: Int,
        home: URL = PathSafety.userHome,
        progress: ((Double, String?) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) -> [DeveloperCacheEntry] {
        (try? scanCategoryReport(
            category,
            maxAgeDays: maxAgeDays,
            home: home,
            progress: progress,
            isCancelled: isCancelled
        ))?.entries ?? []
    }

    private static func scanCategoryReport(
        _ category: DeveloperCacheCategory,
        maxAgeDays: Int,
        home: URL,
        progress: ((Double, String?) -> Void)? = nil,
        isCancelled: @escaping () -> Bool
    ) throws -> DeveloperCacheScanReport {
        var report = DeveloperCacheScanReport()
        let minimumAge = max(category.minimumEntryAgeDays, maxAgeDays)
        let cutoff = Date().addingTimeInterval(-Double(minimumAge) * 86_400)
        let allowlisted = category.candidatePaths(home: home)

        for (candidateIndex, candidate) in allowlisted.enumerated() {
            if isCancelled() { throw DeveloperCacheScanError.cancelled }
            let validation = PathSafety.validate(
                path: candidate,
                root: home.path,
                purpose: .explicitDeveloperCache,
                allowSymlink: false
            )
            guard case .success(let validated) = validation,
                  validated.kind == .directory,
                  PathSafety.isPath(validated.canonical, inside: home.path) else {
                if FileManager.default.fileExists(atPath: candidate) { report.deniedPaths.append(candidate) }
                continue
            }
            report.scannedPaths.append(validated.canonical)
            progress?(Double(candidateIndex) / Double(max(allowlisted.count, 1)), validated.canonical)
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: validated.canonical, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                report.deniedPaths.append(validated.canonical)
                continue
            }

            for (childIndex, child) in children.enumerated() {
                guard childIndex < 10_000 else {
                    report.truncatedPaths.append(validated.canonical)
                    break
                }
                if isCancelled() { throw DeveloperCacheScanError.cancelled }
                progress?(Double(candidateIndex) / Double(max(allowlisted.count, 1)), child.path)
                let childValidation = PathSafety.validate(
                    path: child.path,
                    root: validated.canonical,
                    purpose: .explicitDeveloperCache,
                    allowSymlink: false
                )
                guard case .success(let childPath) = childValidation,
                      childPath.kind == .directory || childPath.kind == .regularFile,
                      !childPath.isSymlink,
                      allowedEntry(childPath.canonical, category: category, root: validated.canonical) else { continue }

                let modified = FileUtilities.modificationDate(atPath: childPath.canonical) ?? .distantPast
                guard modified <= cutoff else { continue }
                let measurement = try measuredSize(
                    at: childPath.canonical,
                    isDirectory: childPath.kind == .directory,
                    isCancelled: isCancelled
                )
                if measurement.truncated {
                    report.truncatedPaths.append(childPath.canonical)
                }
                let size = measurement.bytes
                guard size > 0 else { continue }
                let identity = Crypto.inode(of: childPath.canonical)
                report.entries.append(DeveloperCacheEntry(
                    category: category.rawValue,
                    name: URL(fileURLWithPath: childPath.canonical).lastPathComponent,
                    path: childPath.canonical,
                    size: size,
                    modified: modified,
                    isDirectory: childPath.kind == .directory,
                    confidence: category == .archives || category == .xcodeDeviceSupport ? .review : .safe,
                    reason: safetyNote(for: category),
                    device: identity.map { Int32(clamping: Int64($0.0)) } ?? 0,
                    inode: identity.map { UInt64($0.1) } ?? 0
                ))
            }
        }
        return report
    }

    private static func allowedEntry(_ path: String, category: DeveloperCacheCategory, root: String) -> Bool {
        guard PathSafety.isPath(path, inside: root), !PathSafety.isAppBundle(path) else { return false }
        if PathSafety.isProtectedFile(name: URL(fileURLWithPath: path).lastPathComponent, purpose: .explicitDeveloperCache) { return false }
        // Explicitly refuse active simulator/device and project-like data.
        if category == .simulatorCache && (path.contains("/Devices") || path.contains("/data")) { return false }
        if path.contains(".xcodeproj") || path.contains(".xcworkspace") || path.contains("node_modules") { return false }
        return true
    }

    private struct DirectoryMeasurement {
        var bytes: Int64
        var truncated: Bool
    }

    /// Iterative bounded traversal with inode deduplication and cancellation.
    private static func measuredSize(
        at path: String,
        isDirectory: Bool,
        isCancelled: @escaping () -> Bool
    ) throws -> DirectoryMeasurement {
        if !isDirectory {
            return DirectoryMeasurement(bytes: FileUtilities.fileSize(atPath: path), truncated: false)
        }
        var stack = [(path: path, depth: 0)]
        var visited = Set<String>()
        var total: Int64 = 0
        var truncated = false
        var entriesVisited = 0
        while let current = stack.popLast() {
            if isCancelled() { throw DeveloperCacheScanError.cancelled }
            guard current.depth <= 64 else {
                truncated = true
                continue
            }
            if let identity = Crypto.inode(of: current.path) {
                let key = "\(identity.0):\(identity.1)"
                guard visited.insert(key).inserted else { continue }
            } else {
                guard visited.insert("path:\(current.path)").inserted else { continue }
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: current.path, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                truncated = true
                continue
            }
            for (entryIndex, entry) in entries.enumerated() {
                if isCancelled() { throw DeveloperCacheScanError.cancelled }
                entriesVisited += 1
                guard entriesVisited <= 250_000, entryIndex < 10_000 else {
                    truncated = true
                    break
                }
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      values.isSymbolicLink != true else { continue }
                if values.isRegularFile == true {
                    if let identity = Crypto.inode(of: entry.path) {
                        let key = "\(identity.0):\(identity.1)"
                        guard visited.insert(key).inserted else { continue }
                    }
                    total = CleanupAccounting.adding(total, Int64(values.fileSize ?? 0))
                } else if values.isDirectory == true {
                    stack.append((entry.path, current.depth + 1))
                }
            }
        }
        return DirectoryMeasurement(bytes: total, truncated: truncated)
    }

    public static func safetyNote(for category: DeveloperCacheCategory) -> String {
        switch category {
        case .archives, .xcodeDeviceSupport:
            return NSLocalizedString("devcat.note.review", comment: "")
        case .simulatorCache:
            return NSLocalizedString("devcat.note.simulator_cache", comment: "")
        case .docker, .macPorts:
            return NSLocalizedString("devcat.note.unavailable", comment: "")
        default:
            return NSLocalizedString("devcat.note.default", comment: "")
        }
    }
}
