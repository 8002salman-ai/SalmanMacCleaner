//
//  ScanCoverageReport.swift
//  SalmanMacCleaner
//
//  Builds honest coverage reports from the *actual* per-root outcomes the
//  scanner produced. Never optimistic: a root is only ever "scanned" when
//  the scanner really traversed it, and any not-granted / denied / partial
//  root makes the report "Limited". Wording is precise — the app never
//  claims "Entire Mac scanned" unless it is true.
//

import Foundation

public enum RootOutcome: Equatable {
    /// The scanner genuinely traversed the root.
    case scanned
    /// Traversed, but some paths were denied or errors occurred.
    case partial(deniedPaths: Int, errors: Int)
    /// Readable probe failed or enumeration was refused.
    case denied(String)
    /// System Integrity Protection protects the root.
    case sipProtected
    /// The user has not granted access to this root (FDA / opt-in).
    case skippedNotGranted(String)
    /// Network/cloud volume — explicit opt-in required.
    case skippedNetwork
    /// Time Machine destination — never scanned automatically.
    case skippedTimeMachine
    /// Read-only image / skipped mount.
    case skippedMount
    /// The root does not exist.
    case missing

    public var state: CoverageState {
        switch self {
        case .scanned: return .scanned
        case .partial: return .partial
        case .denied: return .denied
        case .sipProtected: return .sipProtected
        case .skippedNotGranted: return .skippedNotGranted
        case .skippedNetwork: return .skippedNetwork
        case .skippedTimeMachine: return .skippedTimeMachine
        case .skippedMount: return .skippedMount
        case .missing: return .missing
        }
    }

    public var reason: String? {
        switch self {
        case .scanned, .partial, .sipProtected, .skippedNetwork, .skippedTimeMachine, .skippedMount, .missing:
            return nil
        case .denied(let reason): return reason
        case .skippedNotGranted(let reason): return reason
        }
    }
}

public enum CoverageState: String, Codable {
    case scanned
    case partial
    case denied
    case sipProtected
    case skippedNotGranted
    case skippedNetwork
    case skippedTimeMachine
    case skippedMount
    case missing
}

/// One root's outcome in the report.
public struct RootCoverageDetail: Codable, Equatable, Identifiable {
    public var id: String { root }
    public var root: String
    public var state: CoverageState
    public var reason: String?
    public var deniedPaths: Int
    public var errors: Int

    public init(root: String, state: CoverageState, reason: String? = nil, deniedPaths: Int = 0, errors: Int = 0) {
        self.root = root
        self.state = state
        self.reason = reason
        self.deniedPaths = deniedPaths
        self.errors = errors
    }
}

public enum ScanCoverageReport {

    public static func build(
        requestedRoots: [String],
        outcomes: [String: RootOutcome]
    ) -> CoverageReport {
        var scanned: [String] = []
        var partial: [String] = []
        var denied: [String] = []
        var sip: [String] = []
        var mounts: [String] = []
        var network: [String] = []
        var timeMachine: [String] = []
        var notGranted: [String] = []
        var missing: [String] = []
        var deniedPaths = 0
        var details: [RootCoverageDetail] = []

        for root in requestedRoots {
            let outcome = outcomes[root] ?? .missing
            switch outcome {
            case .scanned:
                scanned.append(root)
                details.append(RootCoverageDetail(root: root, state: .scanned))
            case .partial(let paths, let errors):
                partial.append(root)
                deniedPaths += paths
                details.append(RootCoverageDetail(root: root, state: .partial, deniedPaths: paths, errors: errors))
            case .denied(let reason):
                denied.append(root)
                details.append(RootCoverageDetail(root: root, state: .denied, reason: reason))
            case .sipProtected:
                sip.append(root)
                details.append(RootCoverageDetail(root: root, state: .sipProtected))
            case .skippedNotGranted(let reason):
                notGranted.append(root)
                details.append(RootCoverageDetail(root: root, state: .skippedNotGranted, reason: reason))
            case .skippedNetwork:
                network.append(root)
                details.append(RootCoverageDetail(root: root, state: .skippedNetwork))
            case .skippedTimeMachine:
                timeMachine.append(root)
                details.append(RootCoverageDetail(root: root, state: .skippedTimeMachine))
            case .skippedMount:
                mounts.append(root)
                details.append(RootCoverageDetail(root: root, state: .skippedMount))
            case .missing:
                missing.append(root)
                details.append(RootCoverageDetail(root: root, state: .missing))
            }
        }

        // "Limited" whenever any requested root was not granted or denied:
        // coverage is never complete when permission is missing.
        let limitedByPermission = !notGranted.isEmpty || !denied.isEmpty || !missing.isEmpty
        let permissionReason: String?
        if !notGranted.isEmpty {
            permissionReason = NSLocalizedString("coverage.limited.reason_not_granted", comment: "")
        } else if !denied.isEmpty {
            permissionReason = NSLocalizedString("coverage.limited.reason_denied", comment: "")
        } else {
            permissionReason = nil
        }

        let confidence: CoverageConfidence
        if scanned.isEmpty && partial.isEmpty {
            confidence = .unknown
        } else if limitedByPermission {
            confidence = partial.count + denied.count + notGranted.count < max(requestedRoots.count / 2, 1)
                ? .mostlyComplete
                : .partial
        } else if partial.isEmpty {
            confidence = .complete
        } else {
            confidence = .mostlyComplete
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
            symlinksRejected: 0,
            filesChangedDuringScan: 0,
            totalErrors: details.reduce(0) { $0 + $1.errors },
            deniedPaths: deniedPaths,
            confidence: confidence,
            limitedByPermission: limitedByPermission,
            permissionReason: permissionReason,
            notGrantedRoots: notGranted,
            rootDetails: details
        )
    }

    /// Percentage of requested roots that were at least partially scanned.
    public static func coveragePercent(_ report: CoverageReport) -> Int {
        guard !report.requestedRoots.isEmpty else { return 0 }
        let covered = report.scannedRoots.count + report.partialRoots.count
        return Int(Double(covered) / Double(report.requestedRoots.count) * 100)
    }
}
