//
//  HealthCheckService.swift
//  SalmanMacCleaner
//
//  Read-only aggregate health review used by Smart Care. Every factor is
//  measured from a real public API or a bounded scanner; this service never
//  creates a cleanup plan and never mutates the filesystem.
//

import Foundation

public enum HealthCheckStatus: String, Codable, Equatable {
    case good
    case attention
    case unavailable

    public var title: String {
        switch self {
        case .good: return NSLocalizedString("health.status.good", comment: "")
        case .attention: return NSLocalizedString("health.status.attention", comment: "")
        case .unavailable: return NSLocalizedString("health.status.unavailable", comment: "")
        }
    }
}

public enum HealthCheckFactorID: String, Codable, CaseIterable {
    case storage
    case trash
    case caches
    case applications
    case backgroundItems
    case permissions

    public var title: String {
        switch self {
        case .storage: return NSLocalizedString("health.factor.storage", comment: "")
        case .trash: return NSLocalizedString("health.factor.trash", comment: "")
        case .caches: return NSLocalizedString("health.factor.caches", comment: "")
        case .applications: return NSLocalizedString("health.factor.applications", comment: "")
        case .backgroundItems: return NSLocalizedString("health.factor.background", comment: "")
        case .permissions: return NSLocalizedString("health.factor.permissions", comment: "")
        }
    }

    public var destination: SidebarModule? {
        switch self {
        case .storage: return .spaceLens
        case .trash: return .trashBins
        case .caches: return .developerCaches
        case .applications: return .applications
        case .backgroundItems: return .startupItems
        case .permissions: return .permissions
        }
    }
}

public struct HealthCheckFactor: Identifiable, Codable, Equatable {
    public var id: HealthCheckFactorID
    public var status: HealthCheckStatus
    public var summary: String
    public var evidence: String
    public var measuredBytes: Int64?
    public var measuredCount: Int?

    public init(id: HealthCheckFactorID,
                status: HealthCheckStatus,
                summary: String,
                evidence: String,
                measuredBytes: Int64? = nil,
                measuredCount: Int? = nil) {
        self.id = id
        self.status = status
        self.summary = summary
        self.evidence = evidence
        self.measuredBytes = measuredBytes
        self.measuredCount = measuredCount
    }
}

public struct HealthCheckProgress: Equatable {
    public var completedFactors: Int
    public var totalFactors: Int
    public var currentFactor: HealthCheckFactorID?
    public var detail: String?
    public var fraction: Double

    public init(completedFactors: Int = 0,
                totalFactors: Int = HealthCheckFactorID.allCases.count,
                currentFactor: HealthCheckFactorID? = nil,
                detail: String? = nil,
                fraction: Double = 0) {
        self.completedFactors = completedFactors
        self.totalFactors = totalFactors
        self.currentFactor = currentFactor
        self.detail = detail
        self.fraction = min(max(fraction, 0), 1)
    }
}

public struct HealthCheckResult: Equatable {
    public var factors: [HealthCheckFactor]
    public var coverage: CoverageConfidence
    public var coverageMessage: String
    public var finishedAt: Date

    public init(factors: [HealthCheckFactor],
                coverage: CoverageConfidence,
                coverageMessage: String,
                finishedAt: Date = Date()) {
        self.factors = factors
        self.coverage = coverage
        self.coverageMessage = coverageMessage
        self.finishedAt = finishedAt
    }

    public var attentionCount: Int {
        factors.filter { $0.status == .attention }.count
    }

    public var overallStatus: HealthCheckStatus {
        if factors.isEmpty || factors.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
        return factors.contains(where: { $0.status == .attention }) ? .attention : .good
    }
}

public enum HealthCheckError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        NSLocalizedString("scan.error.cancelled", comment: "")
    }
}

public enum HealthCheckService {
    public typealias ProgressHandler = (HealthCheckProgress) -> Void

    /// Runs six read-only checks. The callback is invoked at factor boundaries
    /// and during developer-cache traversal, so the UI can show aggregate
    /// progress rather than an indeterminate spinner.
    public static func run(
        permissionStatus: FullDiskAccessStatus,
        progress: @escaping ProgressHandler,
        isCancelled: @escaping () -> Bool
    ) throws -> HealthCheckResult {
        let factors = HealthCheckFactorID.allCases
        var results: [HealthCheckFactor] = []
        var coverageLimited = permissionStatus != .granted

        for (index, factor) in factors.enumerated() {
            try checkCancellation(isCancelled)
            report(index: index, factor: factor, detail: factor.title, progress: progress)

            let result: HealthCheckFactor
            switch factor {
            case .storage:
                result = try storageFactor(isCancelled: isCancelled, coverageLimited: &coverageLimited)
            case .trash:
                result = try trashFactor(isCancelled: isCancelled, coverageLimited: &coverageLimited)
            case .caches:
                result = try cachesFactor(index: index, total: factors.count, progress: progress, isCancelled: isCancelled, coverageLimited: &coverageLimited)
            case .applications:
                result = try applicationsFactor(isCancelled: isCancelled)
            case .backgroundItems:
                result = try backgroundFactor(isCancelled: isCancelled)
            case .permissions:
                result = permissionsFactor(permissionStatus)
            }
            results.append(result)
            report(index: index + 1, factor: nil, detail: result.summary, progress: progress)
        }

        let coverage: CoverageConfidence = coverageLimited ? .partial : .complete
        let coverageMessage = coverageLimited
            ? NSLocalizedString("health.coverage.limited", comment: "")
            : NSLocalizedString("health.coverage.complete", comment: "")
        return HealthCheckResult(
            factors: results,
            coverage: coverage,
            coverageMessage: coverageMessage
        )
    }

    private static func checkCancellation(_ isCancelled: @escaping () -> Bool) throws {
        if isCancelled() { throw HealthCheckError.cancelled }
    }

    private static func report(index: Int,
                               factor: HealthCheckFactorID?,
                               detail: String?,
                               progress: @escaping ProgressHandler) {
        let total = HealthCheckFactorID.allCases.count
        progress(HealthCheckProgress(
            completedFactors: min(index, total),
            totalFactors: total,
            currentFactor: factor,
            detail: detail,
            fraction: Double(min(index, total)) / Double(total)
        ))
    }

    private static func storageFactor(isCancelled: @escaping () -> Bool,
                                      coverageLimited: inout Bool) throws -> HealthCheckFactor {
        guard let snapshot = StorageOverview.snapshot(isCancelled: isCancelled), snapshot.totalCapacity > 0 else {
            coverageLimited = true
            try checkCancellation(isCancelled)
            return HealthCheckFactor(
                id: .storage,
                status: .unavailable,
                summary: NSLocalizedString("health.storage.unavailable", comment: ""),
                evidence: NSLocalizedString("health.storage.unavailable.detail", comment: "")
            )
        }
        let status: HealthCheckStatus = snapshot.availableFraction < 0.10 ? .attention : .good
        let summary = String(format: NSLocalizedString("health.storage.summary", comment: ""),
                             FileUtilities.formattedBytes(snapshot.available))
        let evidence = String(format: NSLocalizedString("health.storage.evidence", comment: ""),
                              Int(snapshot.availableFraction * 100))
        return HealthCheckFactor(id: .storage,
                                 status: status,
                                 summary: summary,
                                 evidence: evidence,
                                 measuredBytes: snapshot.available)
    }

    private static func trashFactor(isCancelled: @escaping () -> Bool,
                                    coverageLimited: inout Bool) throws -> HealthCheckFactor {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            coverageLimited = true
            return HealthCheckFactor(id: .trash,
                                     status: .unavailable,
                                     summary: NSLocalizedString("health.trash.unavailable", comment: ""),
                                     evidence: NSLocalizedString("health.trash.unavailable.detail", comment: ""))
        }

        var bytes: Int64 = 0
        var count = 0
        for entry in entries {
            try checkCancellation(isCancelled)
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true else { continue }
            count += 1
            if values.isDirectory == true {
                let measurement = StorageOverview.directoryMeasurement(
                    url: entry,
                    depth: 8,
                    isCancelled: isCancelled
                )
                coverageLimited = coverageLimited
                    || measurement.truncated
                    || measurement.inaccessibleEntries > 0
                bytes = CleanupAccounting.adding(bytes, measurement.bytes)
                try checkCancellation(isCancelled)
            } else {
                bytes = CleanupAccounting.adding(bytes, Int64(values.fileSize ?? 0))
            }
        }
        let status: HealthCheckStatus = count > 0 ? .attention : .good
        let summary = count > 0
            ? String(format: NSLocalizedString("health.trash.summary", comment: ""), count, FileUtilities.formattedBytes(bytes))
            : NSLocalizedString("health.trash.clear", comment: "")
        return HealthCheckFactor(id: .trash,
                                 status: status,
                                 summary: summary,
                                 evidence: NSLocalizedString("health.trash.evidence", comment: ""),
                                 measuredBytes: bytes,
                                 measuredCount: count)
    }

    private static func cachesFactor(index: Int,
                                     total: Int,
                                     progress: @escaping ProgressHandler,
                                     isCancelled: @escaping () -> Bool,
                                     coverageLimited: inout Bool) throws -> HealthCheckFactor {
        let categories = DeveloperCacheScanner.detectedCategories()
        guard !categories.isEmpty else {
            return HealthCheckFactor(id: .caches,
                                     status: .good,
                                     summary: NSLocalizedString("health.caches.clear", comment: ""),
                                     evidence: NSLocalizedString("health.caches.evidence.none", comment: ""),
                                     measuredBytes: 0,
                                     measuredCount: 0)
        }
        let report = try DeveloperCacheScanner.scanReport(
            categories: categories,
            maxAgeDays: 90,
            progress: { fraction, detail in
                let aggregate = (Double(index) + fraction) / Double(total)
                progress(HealthCheckProgress(
                    completedFactors: index,
                    totalFactors: total,
                    currentFactor: .caches,
                    detail: detail,
                    fraction: aggregate
                ))
            },
            isCancelled: isCancelled
        )
        coverageLimited = coverageLimited || !report.deniedPaths.isEmpty || !report.truncatedPaths.isEmpty
        let bytes = report.entries.reduce(Int64(0)) { CleanupAccounting.adding($0, $1.size) }
        let status: HealthCheckStatus = bytes > 0 ? .attention : .good
        let summary = bytes > 0
            ? String(format: NSLocalizedString("health.caches.summary", comment: ""), FileUtilities.formattedBytes(bytes))
            : NSLocalizedString("health.caches.clear", comment: "")
        let evidence: String
        if !report.deniedPaths.isEmpty || !report.truncatedPaths.isEmpty {
            evidence = String(format: NSLocalizedString("health.caches.partial", comment: ""),
                              report.deniedPaths.count + report.truncatedPaths.count)
        } else {
            evidence = String(format: NSLocalizedString("health.caches.evidence", comment: ""), report.entries.count)
        }
        return HealthCheckFactor(id: .caches,
                                 status: status,
                                 summary: summary,
                                 evidence: evidence,
                                 measuredBytes: bytes,
                                 measuredCount: report.entries.count)
    }

    private static func applicationsFactor(isCancelled: @escaping () -> Bool) throws -> HealthCheckFactor {
        try checkCancellation(isCancelled)
        let apps = ApplicationInventoryService.discoverApplications()
        try checkCancellation(isCancelled)
        return HealthCheckFactor(
            id: .applications,
            status: apps.isEmpty ? .unavailable : .good,
            summary: String(format: NSLocalizedString("health.apps.summary", comment: ""), apps.count),
            evidence: NSLocalizedString("health.apps.evidence", comment: ""),
            measuredCount: apps.count
        )
    }

    private static func backgroundFactor(isCancelled: @escaping () -> Bool) throws -> HealthCheckFactor {
        try checkCancellation(isCancelled)
        let items = StartupManager.discover()
        try checkCancellation(isCancelled)
        let broken = items.filter(\.isBroken).count
        let status: HealthCheckStatus = broken > 0 ? .attention : .good
        let summary = broken > 0
            ? String(format: NSLocalizedString("health.background.summary", comment: ""), broken)
            : String(format: NSLocalizedString("health.background.clear", comment: ""), items.count)
        return HealthCheckFactor(id: .backgroundItems,
                                 status: status,
                                 summary: summary,
                                 evidence: NSLocalizedString("health.background.evidence", comment: ""),
                                 measuredCount: items.count)
    }

    private static func permissionsFactor(_ status: FullDiskAccessStatus) -> HealthCheckFactor {
        let factorStatus: HealthCheckStatus = status == .granted ? .good : .attention
        return HealthCheckFactor(id: .permissions,
                                 status: factorStatus,
                                 summary: status.title,
                                 evidence: status.explanation)
    }
}
