//
//  ScanCoverageReport.swift
//  SalmanMacCleaner
//
//  Builds honest coverage reports from root-level outcomes. Wording is
//  precise: the app never claims "Entire Mac scanned" unless it is true.
//

import Foundation

public enum RootOutcome: Equatable {
    case scanned
    case partial(deniedPaths: Int, errors: Int)
    case denied
    case sipProtected
    case skippedNetwork
    case skippedTimeMachine
    case skippedMount
    case missing
}

public enum ScanCoverageReport {

    public static func build(
        requestedRoots: [String],
        outcomes: [String: RootOutcome],
        symlinksRejected: Int,
        filesChangedDuringScan: Int,
        totalErrors: Int
    ) -> CoverageReport {
        var scanned: [String] = []
        var partial: [String] = []
        var denied: [String] = []
        var sip: [String] = []
        var mounts: [String] = []
        var network: [String] = []
        var timeMachine: [String] = []
        var deniedPaths = 0

        for root in requestedRoots {
            switch outcomes[root] ?? .missing {
            case .scanned:
                scanned.append(root)
            case .partial(let paths, let errors):
                partial.append(root)
                deniedPaths += paths
            case .denied:
                denied.append(root)
            case .sipProtected:
                sip.append(root)
            case .skippedNetwork:
                network.append(root)
            case .skippedTimeMachine:
                timeMachine.append(root)
            case .skippedMount:
                mounts.append(root)
            case .missing:
                denied.append(root)
            }
        }

        let confidence: CoverageConfidence
        if scanned.isEmpty {
            confidence = .unknown
        } else if denied.isEmpty && partial.isEmpty && totalErrors == 0 {
            confidence = .complete
        } else if partial.count + denied.count < max(requestedRoots.count / 2, 1) {
            confidence = .mostlyComplete
        } else {
            confidence = .partial
        }

        return CoverageReport(
            requestedRoots: requestedRoots,
            scannedRoots: scanned,
            partialRoots: partial,
            deniedRoots: denied,
            sipProtectedRoots: sip,
            skippedMounts: mounts,
            skippedNetworkVolumes: network,
            skippedTimeMachine: timeMachine,
            symlinksRejected: symlinksRejected,
            filesChangedDuringScan: filesChangedDuringScan,
            totalErrors: totalErrors,
            deniedPaths: deniedPaths,
            confidence: confidence
        )
    }

    /// Percentage of requested roots that were at least partially scanned.
    public static func coveragePercent(_ report: CoverageReport) -> Int {
        guard !report.requestedRoots.isEmpty else { return 0 }
        let covered = report.scannedRoots.count + report.partialRoots.count
        return Int(Double(covered) / Double(report.requestedRoots.count) * 100)
    }
}
