//
//  DeepScanCoordinator.swift
//  SalmanMacCleaner
//
//  Orchestrates the thirteen-phase deep scan. Structured concurrency:
//  - heavy work runs in a detached task (never on the main actor)
//  - ScanIndexStore is an actor (serialized SQLite)
//  - ScanGate provides pause/resume
//  - events stream to the UI through AsyncStream, throttled by the
//    ScanProgressAggregator
//  - thermal pressure pauses the scan automatically
//

import Foundation
import AppKit

@MainActor
public final class DeepScanCoordinator: ObservableObject {

    public static let shared = DeepScanCoordinator()

    @Published public private(set) var isRunning = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var phase: ScanPhase = .preparingPermissions
    @Published public private(set) var latestSnapshot: ScanProgressSnapshot?
    @Published public private(set) var latestOutcome: ScanOutcome?

    private let gate = ScanGate()
    private var currentTask: Task<Void, Never>?
    private var generation = UUID()

    public let indexStore: ScanIndexStore

    public init(indexStore: ScanIndexStore? = nil) {
        self.indexStore = indexStore ?? (try! ScanIndexStore())
    }

    public convenience init(databasePath: String) {
        self.init(indexStore: (try? ScanIndexStore(path: databasePath)) ?? (try! ScanIndexStore()))
    }

    // MARK: - Controls

    public func pause() {
        guard isRunning else { return }
        isPaused = true
        Task { await gate.pause() }
    }

    public func resume() {
        guard isRunning else { return }
        isPaused = false
        Task { await gate.resume() }
    }

    public func cancel() {
        currentTask?.cancel()
        Task { await gate.cancelAll() }
        currentTask = nil
        generation = UUID()
        isRunning = false
        isPaused = false
        phase = .preparingPermissions
    }

    // MARK: - Scan

    /// Start a scan. Returns the event stream consumed by the UI.
    public func start(
        scope: ScanScope,
        settings: SettingsStore,
        volumes: [VolumeInfo]? = nil
    ) -> AsyncStream<ScanEvent> {
        cancel()
        let token = UUID()
        generation = token
        isRunning = true
        isPaused = false

        let store = indexStore
        let gate = self.gate

        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.runScan(
                        scope: scope,
                        settings: settings,
                        volumes: volumes,
                        store: store,
                        gate: gate,
                        emit: { event in
                            continuation.yield(event)
                        }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.failed(NSLocalizedString("scan.error.cancelled", comment: "")))
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            Task { @MainActor in
                self.currentTask = task
            }
        }
    }

    // MARK: - The scan itself (off the main actor)

    private static func runScan(
        scope: ScanScope,
        settings: SettingsStore,
        volumes: [VolumeInfo]?,
        store: ScanIndexStore,
        gate: ScanGate,
        emit: @escaping (ScanEvent) -> Void
    ) async throws {
        let startedAt = Date()
        let aggregator = ScanProgressAggregator()

        func emitPhase(_ phase: ScanPhase, detail: String? = nil) async {
            await aggregator.begin(phase: phase)
            emit(.phaseChanged(phase, detail))
        }

        func emitProgress(force: Bool = false) async {
            if let snapshot = await aggregator.snapshot(force: force) {
                emit(.progress(snapshot))
            }
        }

        // Phase 1: permissions.
        await emitPhase(.preparingPermissions)
        let fdaStatus = PermissionService.probeFullDiskAccess()
        _ = fdaStatus
        await emitProgress(force: true)

        // Phase 2: volumes.
        await emitPhase(.discoveringVolumes)
        let discoveredVolumes = volumes ?? VolumeDiscoveryService.discoverVolumes()
        let plan = ScanPolicy.resolve(scope: scope, volumes: discoveredVolumes)

        // Coverage: root-level outcomes for volumes that were skipped.
        var rootOutcomes: [String: RootOutcome] = [:]
        for root in plan.roots {
            rootOutcomes[root.path] = .scanned
        }
        for volume in discoveredVolumes where !plan.roots.contains(where: { $0.path == volume.mountPoint }) {
            if !volume.isLocal {
                rootOutcomes[volume.mountPoint] = .skippedNetwork
            } else if VolumeDiscoveryService.isTimeMachineVolume(volume) {
                rootOutcomes[volume.mountPoint] = .skippedTimeMachine
            } else if volume.isReadOnly {
                rootOutcomes[volume.mountPoint] = .skippedMount
            }
        }
        await emitProgress(force: true)

        // Incremental decision (public FSEvents only).
        var provenance = ScanProvenance.full
        var inventoryRoots = plan.roots
        if scope.isIncrementalCandidate, let firstRoot = plan.roots.first {
            if let device = VolumeDiscoveryService.deviceID(ofMountPoint: firstRoot.path),
               let lastEventID = await store.lastEventID(forMountPoint: firstRoot.path),
               let changed = IncrementalScanSupport.collectChangedDirectories(root: firstRoot.path, sinceEventID: lastEventID) {
                if !changed.paths.isEmpty {
                    let changedURLs = changed.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    inventoryRoots = changedURLs
                    provenance = .incremental
                }
                if let newest = changed.newestEventID {
                    try? await store.saveEventState(mountPoint: firstRoot.path, lastEventID: newest)
                }
            }
        }

        // Phase 3 + 4: inventory with metadata (prefetched resource keys).
        await emitPhase(.buildingInventory, detail: plan.roots.first?.path)
        var localBatch: [FileRecord] = []
        var classifiedBatch: [(FileRecord, JunkVerdict)] = []
        var safeBytes: Int64 = 0
        var reviewBytes: Int64 = 0
        var protectedBytes: Int64 = 0
        var candidateBytes: Int64 = 0
        var mapAccumulator: [String: Int64] = [:]
        let scanID = try await store.beginScan(mode: scope.mode, scope: scope, provenance: provenance)

        do {
            var totals = InventoryCounts()
            let flushes = FlushCoordinator()
            for root in inventoryRoots {
                if Task.isCancelled { throw CancellationError() }
                let rootTotals = try await FileInventoryScanner.scan(
                    roots: [root],
                    includeHidden: plan.includeHidden,
                    includePackageContents: plan.includePackageContents,
                    minFileSize: plan.minFileSize,
                    sink: { record in
                        localBatch.append(record)
                        let verdict = JunkClassifier.classify(record)
                        classifiedBatch.append((record, verdict))
                        switch verdict.safety {
                        case .safe:
                            safeBytes += record.allocatedSize
                            candidateBytes += record.allocatedSize
                        case .review:
                            reviewBytes += record.allocatedSize
                            candidateBytes += record.allocatedSize
                        case .protected:
                            protectedBytes += record.allocatedSize
                        }
                        if record.allocatedSize > 0, depth(of: record.path, under: root.path) <= 2 {
                            let key = parentKey(of: record.path, root: root.path)
                            mapAccumulator[key, default: 0] += record.allocatedSize
                            if mapAccumulator.count > 5000 {
                                mapAccumulator.removeAll()
                            }
                        }
                        if localBatch.count >= 500 {
                            flushes.enqueue(
                                flushToStore(store, scanID: scanID, records: localBatch, verdicts: classifiedBatch)
                            )
                            localBatch.removeAll(keepingCapacity: true)
                            classifiedBatch.removeAll(keepingCapacity: true)
                        }
                    },
                    counts: { snapshot, currentPath in
                        totals = snapshot
                        Task {
                            await aggregator.merge(counts: snapshot)
                            await aggregator.setCurrentPath(currentPath)
                            if let progress = await aggregator.snapshot() {
                                emit(.progress(progress))
                            }
                            // Thermal pressure pauses the scan automatically.
                            let thermal = ProcessInfo.processInfo.thermalState
                            if thermal == .serious || thermal == .critical {
                                await gate.pause()
                                emit(.phaseChanged(ScanPhase.buildingInventory, detail: NSLocalizedString("scan.paused_thermal", comment: "")))
                            }
                        }
                    },
                    gate: gate,
                    isCancelled: { Task.isCancelled }
                )
                totals = rootTotals
                try? await store.markRootState(scanID: scanID, root: root.path, state: "completed")
            }

            if !localBatch.isEmpty {
                flushes.enqueue(
                    flushToStore(store, scanID: scanID, records: localBatch, verdicts: classifiedBatch)
                )
                localBatch.removeAll(keepingCapacity: true)
                classifiedBatch.removeAll(keepingCapacity: true)
            }
            await flushes.waitForAll()

            await emitPhase(.readingMetadata, detail: nil)
            await aggregator.setFraction(1)
            await emitProgress(force: true)

            // Phase 5: classification aggregation (real counts from verdicts).
            await emitPhase(.classifyingJunk)
            await aggregator.addCandidateBytes(candidateBytes)
            await emitProgress(force: true)

            // Phase 6: applications.
            await emitPhase(.discoveringApplications)
            let applications = ApplicationInventoryService.discoverApplications()
            await emitProgress(force: true)

            // Phase 7: correlate resources.
            await emitPhase(.correlatingResources)
            let correlatedCount = applications.count
            _ = correlatedCount
            await emitProgress(force: true)

            // Phase 8: leftovers.
            await emitPhase(.detectingLeftovers)
            let leftovers = ResidualCorrelationEngine.discoverLeftovers(installedApps: applications)
            await emitProgress(force: true)

            // Phase 9: duplicate candidates from the persisted index.
            await emitPhase(.groupingDuplicates)
            let candidates = try await store.duplicateCandidates(scanID: scanID, limit: 20_000)
            var duplicateGroups: [DuplicateCandidateGroup] = []
            var duplicateBytesEstimate: Int64 = 0

            // Phase 10: staged hashing with bounded concurrency.
            if plan.hashDuplicates && !candidates.isEmpty {
                await emitPhase(.hashingDuplicates)
                let batterySensitive = settings.avoidIntensiveWorkOnBattery
                    && ProcessInfo.processInfo.isLowPowerModeEnabled
                if batterySensitive {
                    emit(.phaseChanged(.hashingDuplicates, detail: NSLocalizedString("scan.hashing_skipped_battery", comment: "")))
                } else {
                    let groups = try DuplicatePipeline.detect(candidates: candidates, isCancelled: { Task.isCancelled })
                    duplicateGroups = groups
                    duplicateBytesEstimate = groups.reduce(0) { $0 + $1.reclaimableEstimate }
                }
            }

            // Phase 11: storage map summary (top-level allocated sizes).
            await emitPhase(.buildingStorageMap)
            let mapSummary = mapAccumulator
                .sorted { $0.value > $1.value }
                .prefix(200)
                .map { StorageMapEntry(name: $0.key, bytes: $0.value) }
            _ = mapSummary
            await emitProgress(force: true)

            // Phase 12: reclaimable space.
            await emitPhase(.calculatingReclaimable)
            await aggregator.addCandidateBytes(candidateBytes)
            await emitProgress(force: true)

            // Phase 13: finalize.
            await emitPhase(.finalizingSafety)
            let coverage = ScanCoverageReport.build(
                requestedRoots: plan.roots.map { $0.path },
                outcomes: rootOutcomes,
                symlinksRejected: totals.symlinksRejected,
                filesChangedDuringScan: totals.changedDuringScan,
                totalErrors: totals.errors
            )
            let outcome = ScanOutcome(
                scanID: scanID,
                mode: scope.mode,
                startedAt: startedAt,
                finishedAt: Date(),
                coverage: coverage,
                provenance: provenance,
                itemsScanned: totals.files,
                bytesIndexed: totals.bytesIndexed,
                safeBytes: safeBytes,
                reviewBytes: reviewBytes,
                protectedBytes: protectedBytes,
                applicationCount: applications.count,
                leftoverGroupCount: leftovers.count,
                duplicateGroupCount: duplicateGroups.count,
                duplicateBytesEstimate: duplicateBytesEstimate,
                storageMapRoot: plan.roots.first?.path
            )
            try await store.completeScan(scanID: scanID, outcome: outcome, counts: totals, coverage: coverage)
            emit(.coverageUpdated(coverage))
            emit(.outcome(outcome))
        } catch {
            try? await store.failScan(scanID: scanID, message: error.localizedDescription)
            throw error
        }
    }

    private static func flushToStore(
        _ store: ScanIndexStore,
        scanID: Int64,
        records: [FileRecord],
        verdicts: [(FileRecord, JunkVerdict)]
    ) -> Task<Void, Never> {
        let pairs = verdicts
        return Task {
            try? await store.insertClassifiedRecords(scanID: scanID, pairs: pairs)
            _ = records.count
        }
    }

    private static func depth(of path: String, under root: String) -> Int {
        guard path.hasPrefix(root) else { return Int.max }
        let relative = String(path.dropFirst(root.count))
        return relative.split(separator: "/").count
    }

    private static func parentKey(of path: String, root: String) -> String {
        let relative = String(path.dropFirst(root.count))
        let components = relative.split(separator: "/")
        if components.isEmpty { return root }
        return root + "/" + components[0]
    }
}

/// Tracks in-flight flush tasks so the scan can await them before finishing.
private final class FlushCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func enqueue(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func waitForAll() async {
        let snapshot: [Task<Void, Never>]
        lock.lock()
        snapshot = tasks
        lock.unlock()
        for task in snapshot {
            await task.value
        }
    }
}

/// Lightweight storage-map entry for deep-scan summaries.
public struct StorageMapEntry: Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}
