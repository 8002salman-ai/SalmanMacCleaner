//
//  ScanModels.swift
//  SalmanMacCleaner
//
//  Core data model for the Aurora-scan architecture. Everything the deep
//  scan engine produces flows through these value types.
//

import Foundation

// MARK: - Scan modes

/// The four genuine scan modes. Each maps to a concrete set of roots and
/// rules via `ScanPolicy`.
public enum ScanMode: String, CaseIterable, Identifiable, Codable {
    case quick
    case balanced
    case deep
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quick: return NSLocalizedString("scan.mode.quick", comment: "")
        case .balanced: return NSLocalizedString("scan.mode.balanced", comment: "")
        case .deep: return NSLocalizedString("scan.mode.deep", comment: "")
        case .custom: return NSLocalizedString("scan.mode.custom", comment: "")
        }
    }

    public var summary: String {
        switch self {
        case .quick: return NSLocalizedString("scan.mode.quick.summary", comment: "")
        case .balanced: return NSLocalizedString("scan.mode.balanced.summary", comment: "")
        case .deep: return NSLocalizedString("scan.mode.deep.summary", comment: "")
        case .custom: return NSLocalizedString("scan.mode.custom.summary", comment: "")
        }
    }
}

// MARK: - Scan phases

/// The thirteen real phases a deep scan moves through. Progress is only ever
/// reported for work actually performed.
public enum ScanPhase: Int, CaseIterable, Codable, Comparable {
    case preparingPermissions = 0
    case discoveringVolumes
    case buildingInventory
    case readingMetadata
    case classifyingJunk
    case discoveringApplications
    case correlatingResources
    case detectingLeftovers
    case groupingDuplicates
    case hashingDuplicates
    case buildingStorageMap
    case calculatingReclaimable
    case finalizingSafety

    public static func < (lhs: ScanPhase, rhs: ScanPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .preparingPermissions: return NSLocalizedString("scan.phase.preparing", comment: "")
        case .discoveringVolumes: return NSLocalizedString("scan.phase.volumes", comment: "")
        case .buildingInventory: return NSLocalizedString("scan.phase.inventory", comment: "")
        case .readingMetadata: return NSLocalizedString("scan.phase.metadata", comment: "")
        case .classifyingJunk: return NSLocalizedString("scan.phase.classifying", comment: "")
        case .discoveringApplications: return NSLocalizedString("scan.phase.apps", comment: "")
        case .correlatingResources: return NSLocalizedString("scan.phase.correlating", comment: "")
        case .detectingLeftovers: return NSLocalizedString("scan.phase.leftovers", comment: "")
        case .groupingDuplicates: return NSLocalizedString("scan.phase.grouping", comment: "")
        case .hashingDuplicates: return NSLocalizedString("scan.phase.hashing", comment: "")
        case .buildingStorageMap: return NSLocalizedString("scan.phase.storage_map", comment: "")
        case .calculatingReclaimable: return NSLocalizedString("scan.phase.reclaimable", comment: "")
        case .finalizingSafety: return NSLocalizedString("scan.phase.finalizing", comment: "")
        }
    }

    public var isIndeterminate: Bool {
        switch self {
        case .buildingInventory, .readingMetadata, .buildingStorageMap:
            // Exact progress is unknowable until the scope size is known.
            return true
        default:
            return false
        }
    }
}

// MARK: - Scan scope

/// What a scan is allowed to touch. Constructed from user choices; never
/// broadened silently.
public struct ScanScope: Codable, Equatable {
    public var mode: ScanMode
    /// Explicit roots (Custom Scan / user-selected folders).
    public var explicitRoots: [String]
    /// Volumes to include (Deep Scan). Empty = startup data volume only.
    public var volumes: [String]
    public var includeHiddenFiles: Bool
    public var includePackageContents: Bool
    public var hashDuplicates: Bool
    public var minFileSize: Int64
    public var minFileAgeDays: Int
    public var categories: Set<String>
    /// Inventory-only scan: no cleanup analysis is produced.
    public var inventoryOnly: Bool

    public init(mode: ScanMode,
                explicitRoots: [String] = [],
                volumes: [String] = [],
                includeHiddenFiles: Bool = false,
                includePackageContents: Bool = false,
                hashDuplicates: Bool = true,
                minFileSize: Int64 = 0,
                minFileAgeDays: Int = 0,
                categories: Set<String> = [],
                inventoryOnly: Bool = false) {
        self.mode = mode
        self.explicitRoots = explicitRoots
        self.volumes = volumes
        self.includeHiddenFiles = includeHiddenFiles
        self.includePackageContents = includePackageContents
        self.hashDuplicates = hashDuplicates
        self.minFileSize = minFileSize
        self.minFileAgeDays = minFileAge
        self.categories = categories
        self.inventoryOnly = inventoryOnly
    }

    public var isIncrementalCandidate: Bool {
        mode == .balanced || mode == .deep
    }
}

// MARK: - Volumes

/// A discovered mounted volume (never a network share without explicit
/// opt-in).
public struct VolumeInfo: Identifiable, Equatable, Codable {
    public let id: String
    public var name: String
    public var mountPoint: String
    public var fileSystemType: String
    public var isInternal: Bool
    public var isLocal: Bool
    public var isRemovable: Bool
    public var isReadOnly: Bool
    public var isRoot: Bool
    public var totalCapacity: Int64
    public var available: Int64
    public var used: Int64
    public var purgeableEstimate: Int64
    public var requiresOptIn: Bool
    public var lastScanDate: Date?

    public init(id: String,
                name: String,
                mountPoint: String,
                fileSystemType: String = "unknown",
                isInternal: Bool,
                isLocal: Bool,
                isRemovable: Bool,
                isReadOnly: Bool,
                isRoot: Bool,
                totalCapacity: Int64,
                available: Int64,
                used: Int64,
                purgeableEstimate: Int64,
                requiresOptIn: Bool,
                lastScanDate: Date? = nil) {
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.isRoot = isRoot
        self.totalCapacity = totalCapacity
        self.available = available
        self.used = used
        self.purgeableEstimate = purgeableEstimate
        self.requiresOptIn = requiresOptIn
        self.lastScanDate = lastScanDate
    }
}

// MARK: - File records

/// Metadata collected for one filesystem entry. Inventory data only — a file
/// being recorded here never implies it is junk.
public struct FileRecord: Codable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var parent: String
    public var name: String
    public var isDirectory: Bool
    public var isPackage: Bool
    /// Logical (reported) size in bytes.
    public var logicalSize: Int64
    /// Allocated on-disk size in bytes — preferred for reclaim estimates.
    public var allocatedSize: Int64
    public var modified: Date?
    public var created: Date?
    public var device: Int32
    public var inode: UInt64
    public var ownerUID: UInt32
    public var permissions: Int32
    public var isSymlink: Bool
    public var isHidden: Bool
    public var isPurgeable: Bool
    public var isQuarantined: Bool
    public var bundleID: String?
    public var fileResourceID: String?

    public init(path: String,
                parent: String,
                name: String,
                isDirectory: Bool,
                isPackage: Bool = false,
                logicalSize: Int64,
                allocatedSize: Int64 = 0,
                modified: Date? = nil,
                created: Date? = nil,
                device: Int32 = 0,
                inode: UInt64 = 0,
                ownerUID: UInt32 = 0,
                permissions: Int32 = 0,
                isSymlink: Bool = false,
                isHidden: Bool = false,
                isPurgeable: Bool = false,
                isQuarantined: Bool = false,
                bundleID: String? = nil,
                fileResourceID: String? = nil) {
        self.path = path
        self.parent = parent
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modified = modified
        self.created = created
        self.device = device
        self.inode = inode
        self.ownerUID = ownerUID
        self.permissions = permissions
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        self.isPurgeable = isPurgeable
        self.isQuarantined = isQuarantined
        self.bundleID = bundleID
        self.fileResourceID = fileResourceID
    }
}

// MARK: - Junk classification

/// Safety level assigned to every candidate. Only `.safe` may ever be
/// smart-selected.
public enum SafetyLevel: String, Codable, CaseIterable, Comparable {
    case safe
    case review
    case protected

    public static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        let order: [SafetyLevel: Int] = [.safe: 0, .review: 1, .protected: 2]
        return order[lhs, default: 0] < order[rhs, default: 0]
    }

    public var title: String {
        switch self {
        case .safe: return NSLocalizedString("safety.safe", comment: "")
        case .review: return NSLocalizedString("safety.review", comment: "")
        case .protected: return NSLocalizedString("safety.protected", comment: "")
        }
    }
}

/// Junk categories. Inventory and cleanup eligibility are separate concepts.
public enum JunkCategory: String, Codable, CaseIterable {
    case userCache
    case userLog
    case crashReport
    case diagnosticReport
    case savedState
    case tempFile
    case updateRemnant
    case brokenAlias
    case brokenLoginItem
    case brokenPreference
    case xcodeDerivedData
    case xcodeIndex
    case xcodeDeviceSupport
    case simulatorRuntime
    case simulatorCache
    case swiftPMCache
    case cocoapodsCache
    case npmCache
    case yarnCache
    case pnpmCache
    case gradleCache
    case mavenCache
    case cargoCache
    case pipCache
    case homebrewCache
    case installer
    case iosDeviceSupport
    case simulatorData
    case xcodeArchive
    case moduleCache
    case largeFile
    case oldFile
    case duplicateFile
    case appLeftover
    case unknown

    public var title: String {
        switch self {
        case .userCache: return NSLocalizedString("junk.user_cache", comment: "")
        case .userLog: return NSLocalizedString("junk.user_log", comment: "")
        case .crashReport: return NSLocalizedString("junk.crash_report", comment: "")
        case .diagnosticReport: return NSLocalizedString("junk.diagnostic", comment: "")
        case .savedState: return NSLocalizedString("junk.saved_state", comment: "")
        case .tempFile: return NSLocalizedString("junk.temp", comment: "")
        case .updateRemnant: return NSLocalizedString("junk.update_remnant", comment: "")
        case .brokenAlias: return NSLocalizedString("junk.broken_alias", comment: "")
        case .brokenLoginItem: return NSLocalizedString("junk.broken_login_item", comment: "")
        case .brokenPreference: return NSLocalizedString("junk.broken_preference", comment: "")
        case .xcodeDerivedData: return NSLocalizedString("junk.xcode_derived_data", comment: "")
        case .xcodeIndex: return NSLocalizedString("junk.xcode_index", comment: "")
        case .xcodeDeviceSupport: return NSLocalizedString("junk.xcode_device_support", comment: "")
        case .simulatorRuntime: return NSLocalizedString("junk.simulator_runtime", comment: "")
        case .simulatorCache: return NSLocalizedString("junk.simulator_cache", comment: "")
        case .swiftPMCache: return "SwiftPM " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .cocoapodsCache: return "CocoaPods " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .npmCache: return "npm " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .yarnCache: return "Yarn " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .pnpmCache: return "pnpm " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .gradleCache: return "Gradle " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .mavenCache: return "Maven " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .cargoCache: return "Cargo " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .pipCache: return "pip " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .homebrewCache: return "Homebrew " + NSLocalizedString("junk.cache_suffix", comment: "")
        case .installer: return NSLocalizedString("junk.installer", comment: "")
        case .iosDeviceSupport: return NSLocalizedString("junk.ios_device_support", comment: "")
        case .simulatorData: return NSLocalizedString("junk.simulator_data", comment: "")
        case .xcodeArchive: return NSLocalizedString("junk.xcode_archive", comment: "")
        case .moduleCache: return NSLocalizedString("junk.module_cache", comment: "")
        case .largeFile: return NSLocalizedString("junk.large_file", comment: "")
        case .oldFile: return NSLocalizedString("junk.old_file", comment: "")
        case .duplicateFile: return NSLocalizedString("junk.duplicate", comment: "")
        case .appLeftover: return NSLocalizedString("junk.app_leftover", comment: "")
        case .unknown: return NSLocalizedString("junk.unknown", comment: "")
        }
    }
}

/// The classification verdict for one record.
public struct JunkVerdict: Codable, Equatable {
    public var category: JunkCategory
    public var safety: SafetyLevel
    public var reason: String
    public var autoSelectable: Bool
    public var regenerable: Bool
    public var sourceRule: String

    public init(category: JunkCategory,
                safety: SafetyLevel,
                reason: String,
                autoSelectable: Bool,
                regenerable: Bool,
                sourceRule: String) {
        self.category = category
        self.safety = safety
        self.reason = reason
        self.autoSelectable = autoSelectable
        self.regenerable = regenerable
        self.sourceRule = sourceRule
    }
}

// MARK: - Applications

/// One installed application (inventory only; system apps are protected).
public struct AppRecord: Identifiable, Equatable {
    public var id: String { bundlePath }
    public var name: String
    public var bundlePath: String
    public var bundleID: String?
    public var version: String?
    public var build: String?
    public var architectures: [String]
    public var isCodeSigned: Bool?
    public var isQuarantined: Bool
    public var isSystemApp: Bool
    public var isUserOwned: Bool
    public var isRunning: Bool
    public var bundleSize: Int64
    public var lastOpened: Date?
    public var vendorName: String?

    public init(name: String,
                bundlePath: String,
                bundleID: String?,
                version: String?,
                build: String?,
                architectures: [String],
                isCodeSigned: Bool?,
                isQuarantined: Bool,
                isSystemApp: Bool,
                isUserOwned: Bool,
                isRunning: Bool,
                bundleSize: Int64,
                lastOpened: Date? = nil,
                vendorName: String? = nil) {
        self.name = name
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.version = version
        self.build = build
        self.architectures = architectures
        self.isCodeSigned = isCodeSigned
        self.isQuarantined = isQuarantined
        self.isSystemApp = isSystemApp
        self.isUserOwned = isUserOwned
        self.isRunning = isRunning
        self.bundleSize = bundleSize
        self.lastOpened = lastOpened
        self.vendorName = vendorName
    }
}

/// A leftover (support file whose owning app is gone). Confidence is derived
/// from exact identifier matching — never loose substring matching.
public struct LeftoverCandidate: Identifiable, Equatable {
    public enum Confidence: String, Codable, CaseIterable, Comparable {
        case high
        case medium
        case cautious

        public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            let order: [Confidence: Int] = [.high: 0, .medium: 1, .cautious: 2]
            return order[lhs, default: 0] < order[rhs, default: 0]
        }

        public var title: String {
            switch self {
            case .high: return NSLocalizedString("confidence.high", comment: "")
            case .medium: return NSLocalizedString("confidence.medium", comment: "")
            case .cautious: return NSLocalizedString("confidence.cautious", comment: "")
            }
        }
    }

    public let id = UUID()
    public var groupID: String
    public var owningBundleID: String
    public var paths: [String]
    public var totalSize: Int64
    public var confidence: Confidence
    public var sourceRoot: String

    public init(groupID: String,
                owningBundleID: String,
                paths: [String],
                totalSize: Int64,
                confidence: Confidence,
                sourceRoot: String) {
        self.groupID = groupID
        self.owningBundleID = owningBundleID
        self.paths = paths
        self.totalSize = totalSize
        self.confidence = confidence
        self.sourceRoot = sourceRoot
    }
}

// MARK: - Duplicates

/// One duplicate group from the staged pipeline (size → sample → full hash →
/// inode identity).
public struct DuplicateCandidateGroup: Identifiable, Equatable {
    public let id = UUID()
    public var files: [ScannedItem]
    public var size: Int64
    public var hash: String
    public var apfsCloneUncertain: Bool

    public init(files: [ScannedItem], size: Int64, hash: String, apfsCloneUncertain: Bool = false) {
        self.files = files
        self.size = size
        self.hash = hash
        self.apfsCloneUncertain = apfsCloneUncertain
    }

    public var reclaimableEstimate: Int64 {
        guard files.count > 1 else { return 0 }
        return size * Int64(files.count - 1)
    }
}

// MARK: - Progress & coverage

/// A point-in-time progress snapshot (cheap value type).
public struct ScanProgressSnapshot: Codable, Equatable {
    public var phase: ScanPhase
    public var currentPath: String?
    public var itemsScanned: Int
    public var foldersScanned: Int
    public var bytesIndexed: Int64
    public var candidateBytes: Int64
    public var elapsed: TimeInterval
    public var fraction: Double?
    public var deniedCount: Int
    public var errorCount: Int

    public init(phase: ScanPhase,
                currentPath: String? = nil,
                itemsScanned: Int = 0,
                foldersScanned: Int = 0,
                bytesIndexed: Int64 = 0,
                candidateBytes: Int64 = 0,
                elapsed: TimeInterval = 0,
                fraction: Double? = nil,
                deniedCount: Int = 0,
                errorCount: Int = 0) {
        self.phase = phase
        self.currentPath = currentPath
        self.itemsScanned = itemsScanned
        self.foldersScanned = foldersScanned
        self.bytesIndexed = bytesIndexed
        self.candidateBytes = candidateBytes
        self.elapsed = elapsed
        self.fraction = fraction
        self.deniedCount = deniedCount
        self.errorCount = errorCount
    }
}

/// Coverage confidence levels — never overstate what was scanned.
public enum CoverageConfidence: String, Codable {
    case complete
    case mostlyComplete
    case partial
    case unknown
}

/// Honest coverage reporting for a finished scan.
public struct CoverageReport: Codable, Equatable {
    public var requestedRoots: [String]
    public var scannedRoots: [String]
    public var partialRoots: [String]
    public var deniedRoots: [String]
    public var sipProtectedRoots: [String]
    public var skippedMounts: [String]
    public var skippedNetworkVolumes: [String]
    public var skippedTimeMachine: [String]
    public var symlinksRejected: Int
    public var filesChangedDuringScan: Int
    public var totalErrors: Int
    public var deniedPaths: Int
    public var confidence: CoverageConfidence

    public init(requestedRoots: [String] = [],
                scannedRoots: [String] = [],
                partialRoots: [String] = [],
                deniedRoots: [String] = [],
                sipProtectedRoots: [String] = [],
                skippedMounts: [String] = [],
                skippedNetworkVolumes: [String] = [],
                skippedTimeMachine: [String] = [],
                symlinksRejected: Int = 0,
                filesChangedDuringScan: Int = 0,
                totalErrors: Int = 0,
                deniedPaths: Int = 0,
                confidence: CoverageConfidence = .unknown) {
        self.requestedRoots = requestedRoots
        self.scannedRoots = scannedRoots
        self.partialRoots = partialRoots
        self.deniedRoots = deniedRoots
        self.sipProtectedRoots = sipProtectedRoots
        self.skippedMounts = skippedMounts
        self.skippedNetworkVolumes = skippedNetworkVolumes
        self.skippedTimeMachine = skippedTimeMachine
        self.symlinksRejected = symlinksRejected
        self.filesChangedDuringScan = filesChangedDuringScan
        self.totalErrors = totalErrors
        self.deniedPaths = deniedPaths
        self.confidence = confidence
    }

    /// Precise human wording — never "Entire Mac scanned" unless true.
    public var summaryText: String {
        var lines: [String] = []
        if deniedRoots.isEmpty && partialRoots.isEmpty && totalErrors == 0 {
            lines.append(NSLocalizedString("coverage.all_accessible", comment: ""))
        } else {
            lines.append(String(format: NSLocalizedString("coverage.some_inaccessible", comment: ""), deniedRoots.count + partialRoots.count))
        }
        if !sipProtectedRoots.isEmpty {
            lines.append(NSLocalizedString("coverage.sip_note", comment: ""))
        }
        return lines.joined(separator: " ")
    }
}

/// Incremental vs full provenance for a scan.
public enum ScanProvenance: String, Codable {
    case full
    case incremental
}

/// Final outcome of a scan session.
public struct ScanOutcome: Codable, Equatable {
    public var scanID: Int64
    public var mode: ScanMode
    public var startedAt: Date
    public var finishedAt: Date
    public var coverage: CoverageReport
    public var provenance: ScanProvenance
    public var itemsScanned: Int
    public var bytesIndexed: Int64
    public var safeBytes: Int64
    public var reviewBytes: Int64
    public var protectedBytes: Int64
    public var applicationCount: Int
    public var leftoverGroupCount: Int
    public var duplicateGroupCount: Int
    public var duplicateBytesEstimate: Int64
    public var storageMapRoot: String?

    public init(scanID: Int64,
                mode: ScanMode,
                startedAt: Date,
                finishedAt: Date,
                coverage: CoverageReport,
                provenance: ScanProvenance,
                itemsScanned: Int,
                bytesIndexed: Int64,
                safeBytes: Int64 = 0,
                reviewBytes: Int64 = 0,
                protectedBytes: Int64 = 0,
                applicationCount: Int = 0,
                leftoverGroupCount: Int = 0,
                duplicateGroupCount: Int = 0,
                duplicateBytesEstimate: Int64 = 0,
                storageMapRoot: String? = nil) {
        self.scanID = scanID
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.coverage = coverage
        self.provenance = provenance
        self.itemsScanned = itemsScanned
        self.bytesIndexed = bytesIndexed
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.protectedBytes = protectedBytes
        self.applicationCount = applicationCount
        self.leftoverGroupCount = leftoverGroupCount
        self.duplicateGroupCount = duplicateGroupCount
        self.duplicateBytesEstimate = duplicateBytesEstimate
        self.storageMapRoot = storageMapRoot
    }
}

// MARK: - Events

/// Incremental events streamed from the coordinator to the UI.
public enum ScanEvent {
    case phaseChanged(ScanPhase, detail: String?)
    case progress(ScanProgressSnapshot)
    case coverageUpdated(CoverageReport)
    case inventoryBatch(count: Int, bytes: Int64)
    case outcome(ScanOutcome)
    case failed(String)
}

/// One cleanup item inside an immutable cleanup plan.
public struct PlannedCleanupItem: Codable, Equatable, Identifiable {
    public let id: UUID
    public var path: String
    public var expectedSize: Int64
    public var expectedModified: Date?
    public var expectedOwner: UInt32
    public var expectedDevice: Int32
    public var expectedInode: UInt64
    public var category: JunkCategory
    public var safety: SafetyLevel
    public var containmentRoot: String
    public var action: CleanupAction

    public init(id: UUID = UUID(),
                path: String,
                expectedSize: Int64,
                expectedModified: Date?,
                expectedOwner: UInt32,
                expectedDevice: Int32,
                expectedInode: UInt64,
                category: JunkCategory,
                safety: SafetyLevel,
                containmentRoot: String,
                action: CleanupAction) {
        self.id = id
        self.path = path
        self.expectedSize = expectedSize
        self.expectedModified = expectedModified
        self.expectedOwner = expectedOwner
        self.expectedDevice = expectedDevice
        self.expectedInode = expectedInode
        self.category = category
        self.safety = safety
        self.containmentRoot = containmentRoot
        self.action = action
    }
}

public enum CleanupAction: String, Codable {
    case moveToTrash
    /// Never executed in this version; reserved for a future signed helper.
    case privilegedRemove

    public var isAvailable: Bool {
        switch self {
        case .moveToTrash: return true
        case .privilegedRemove: return false
        }
    }
}

/// The immutable cleanup plan built from the user's explicit selection.
public struct CleanupPlan: Codable, Equatable {
    public var items: [PlannedCleanupItem]
    public var createdAt: Date
    public var previewOnly: Bool
    public var scanID: Int64?

    public init(items: [PlannedCleanupItem], previewOnly: Bool, scanID: Int64? = nil) {
        self.items = items
        self.createdAt = Date()
        self.previewOnly = previewOnly
        self.scanID = scanID
    }

    public var totalBytes: Int64 {
        items.reduce(0) { $0 + $1.expectedSize }
    }
}
