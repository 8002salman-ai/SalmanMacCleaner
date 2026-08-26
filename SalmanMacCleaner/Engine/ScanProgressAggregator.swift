//
//  ScanProgressAggregator.swift
//  SalmanMacCleaner
//
//  Actor that aggregates scanner counters into throttled progress snapshots.
//  Progress is only ever derived from real counters — never timers.
//

import Foundation

public actor ScanProgressAggregator {

    private var counters = InventoryCounts()
    private var phase: ScanPhase = .preparingPermissions
    private var currentPath: String?
    private var startedAt = Date()
    private var lastEmit = Date.distantPast
    private var explicitFraction: Double?
    /// Candidate (junk) bytes discovered so far.
    private var candidateBytes: Int64 = 0

    public init() {}

    public func begin(phase: ScanPhase) {
        self.phase = phase
        self.counters = InventoryCounts()
        self.candidateBytes = 0
        self.currentPath = nil
        self.explicitFraction = nil
        self.startedAt = Date()
        self.lastEmit = Date.distantPast
    }

    public func setCurrentPath(_ path: String?) {
        currentPath = path
    }

    public func setFraction(_ fraction: Double?) {
        explicitFraction = fraction
    }

    public func addCandidateBytes(_ bytes: Int64) {
        candidateBytes = CleanupAccounting.adding(candidateBytes, bytes)
    }

    public func merge(counts: InventoryCounts) {
        counters.files += counts.files
        counters.folders += counts.folders
        counters.bytesIndexed = CleanupAccounting.adding(counters.bytesIndexed, counts.bytesIndexed)
        counters.denied += counts.denied
        counters.errors += counts.errors
        counters.symlinksRejected += counts.symlinksRejected
        counters.changedDuringScan += counts.changedDuringScan
        counters.truncated += counts.truncated
    }

    /// Returns a snapshot at most every 0.1 s to keep UI updates batched.
    public func snapshot(force: Bool = false) -> ScanProgressSnapshot? {
        let now = Date()
        if !force && now.timeIntervalSince(lastEmit) < 0.1 {
            return nil
        }
        lastEmit = now
        return ScanProgressSnapshot(
            phase: phase,
            currentPath: currentPath,
            itemsScanned: counters.files,
            foldersScanned: counters.folders,
            bytesIndexed: counters.bytesIndexed,
            candidateBytes: candidateBytes,
            elapsed: now.timeIntervalSince(startedAt),
            fraction: explicitFraction,
            deniedCount: counters.denied,
            errorCount: counters.errors
        )
    }

    public func finalCounts() -> InventoryCounts {
        counters
    }
}
