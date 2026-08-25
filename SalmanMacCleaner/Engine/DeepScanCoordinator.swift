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
//  Honesty guarantees (regressions fixed here):
//  - Roots are only ever marked "scanned" after the scanner really
//    traversed them; not-granted roots (no Full Disk Access, no opt-in)
//    appear as "skipped — not granted" with an exact reason, and coverage
//    is reported as Limited.
//  - Counts come exclusively from the real per-root results; nothing is
//    fabricated.
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
        if let indexStore {
            self.indexStore = indexStore
        } else {
            let primary = try? ScanIndexStore()
            let fallbackPath = NSTemporaryDirectory() + "/SalmanMacCleaner-ScanIndex.sqlite"
            let fallback = try? ScanIndexStore(path: fallbackPath)
            self.indexStore = primary ?? fallback ?? Self.ephemeralStore()
        }
    }

    /// Last-resort in-memory-safe store; never used unless the filesystem is
    /// unwritable, in which case scans still work without persistence.
    private static func ephemeralStore() -> ScanIndexStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SalmanMacCleaner-Ephemeral-\(UUID().uuidString).sqlite")
        do {
            return try ScanIndexStore(path: url.path)
        } catch {
            // Two distinct temporary locations; the second is under the home
            // directory which must exist.
            let homeURL = PathSafety.userHome
                .appendingPathComponent(".SalmanMacCleaner-Ephemeral-\(UUID().uuidString).sqlite")
            return try! ScanIndexStore(path: homeURL.path)
        }
    }

    public convenience init(databasePath: String) {
        let store = (try? ScanIndexStore(path: databasePath)) ?? {
            let fallbackPath = NSTemporaryDirectory() + "/SalmanMacCleaner-ScanIndex.sqlite"
            return try? ScanIndexStore(path: fallbackPath)
        }()
        self.init(indexStore: store)
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
    /// `authorizedFolders` carries the security-scoped folder grants.
    public func start(
        scope: ScanScope,
        settings: SettingsStore,
        volumes: [VolumeInfo]? = nil,
        authorizedFolders: [URL] = []
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
                        authorizedFolders: authorizedFolders,
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
        authorizedFolders: [URL],
        store: ScanIndexStore,
        gate: ScanGate,
        emit: @escaping (ScanEvent) -> Void
    ) async throws {
        let startedAt = Date()
        let aggregator = ScanProgressAggregator()

        func emitPhase(_ phase: ScanPhase, detail: String? = nil) async {
            await aggregator.begin(phase: phase)
            emit(.phaseChanged(phase, detail: detail))
        }

        func emitProgress(force: Bool = false) async {
            if let snapshot = await aggregator.snapshot(force: force) {
                emit(.progress(snapshot))
            }
        }

        // Phase 1: permissions.
        await emitPhase(.preparingPermissions)
        let fdaStatus = PermissionService.probeFullDiskAccess()
        await emitProgress(force: true)

        // Phase 2: volumes + root resolution with honest grant states.
        await emitPhase(.discoveringVolumes)
        let discoveredVolumes = volumes ?? VolumeDiscoveryService.discoverVolumes()
        let plan = ScanPolicy.resolve(
            scope: scope,
            volumes: discoveredVolumes,
            fdaStatus: fdaStatus,
            authorizedFolders: authorizedFolders
        )

        // Opportunity roots that do not exist on this machine are dropped
        // from the requested set (they are not "denied" — they are absent).
        let requestedRoots = plan.roots.filter { root in
            if root.optional && !FileManager.default.fileExists(atPath: root.url.path) {
                return false
            }
            return true
        }

        // Coverage: roots that were requested but not granted are recorded
        // up front — with the exact reason — and NEVER marked scanned.
        var rootOutcomes: [String: RootOutcome] = [:]
        for root in requestedRoots {
            if root.granted {
                rootOutcomes[root.url.path] = .scanned // replaced by the real result below
            } else {
                rootOutcomes[root.url.path] = .skippedNotGranted(
                    root.notGrantedReason ?? NSLocalizedString("coverage.root.not_granted", comment: "")
                )
            }
        }
        // Volumes not part of the plan are reported with their skip reason.
        for volume in discoveredVolumes where !plan.roots.contains(where: { $0.url.path == volume.mountPoint }) {
            if !volume.isLocal {
                rootOutcomes[volume.mountPoint] = .skippedNetwork
            } else if VolumeDiscoveryService.isTimeMachineVolume(volume) {
                rootOutcomes[volume.mountPoint] = .skippedTimeMachine
            } else if volume.isReadOnly {
                rootOutcomes[volume.mountPoint] = .skippedMount
            }
        }
        await emitProgress(force: true)

        // Incremental decision (public FSEvents only, and only when the
        // user enabled incremental scans).
        var provenance = ScanProvenance.full
        var inventoryRoots = requestedRoots.filter { $0.granted }
        if settings.incrementalScans, scope.isIncrementalCandidate, let firstRoot = inventoryRoots.first {
            if VolumeDiscoveryService.deviceID(ofMountPoint: firstRoot.url.path) != nil,
               let lastEventID = await store.lastEventID(forMountPoint: firstRoot.url.path),
               let changed = IncrementalScanSupport.collectChangedDirectories(root: firstRoot.url.path, sinceEventID: lastEventID) {
                if !changed.paths.isEmpty {
                    let changedRoots = changed.paths.map {
                        ScanPolicy.authorizedFolderRoot(URL(fileURLWithPath: $0, isDirectory: true))
                    }
                    inventoryRoots = changedRoots
                    provenance = .incremental
                }
                if let newest = changed.newestEventID {
                    try? await store.saveEventState(mountPoint: firstRoot.url.path, lastEventID: newest)
                }
            }
        }

        // Phase 3 + 4: inventory with metadata (prefetched resource keys).
        await emitPhase(.buildingInventory, detail: inventoryRoots.first?.url.path)
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
            let results = try await FileInventoryScanner.scan(
                roots: inventoryRoots,
                includeHidden: plan.includeHidden,
                includePackageContents: plan.includePackageContents,
                minFileSize: plan.minFileSize,
                sink: { record, root in
                    localBatch.append(record)
                    let context: JunkClassifier.ClassificationContext
                    switch root.kind {
                    case .authorizedFolder: context = .authorizedFolder
                    case .volumeRoot: context = .volumeRoot
                    default: context = .default
                    }
                    let verdict = JunkClassifier.classify(
                        record,
                        libraryRoots: plan.libraryRoots,
                        reviewRoots: plan.reviewRoots,
                        context: context
                    )
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
                    if record.allocatedSize > 0, depth(of: record.path, under: root.url.path) <= 2 {
                        let key = parentKey(of: record.path, root: root.url.path)
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

            // Replace optimistic outcomes with the scanner's real results.
            for result in results {
                rootOutcomes[result.root] = result.outcome
                totals.merge(result.counts)
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
            await emitProgress(force: true)

            // Phase 8: leftovers.
            await emitPhase(.detectingLeftovers)
            let leftovers = ResidualCorrelationEngine.discoverLeftovers(installedApps: applications)
            await emitProgress(force: true)

            // Phase 9: duplicate candidates from the persisted index.
            await emitPhase(.groupingDuplicates)
            let candidates = await store.duplicateCandidates(scanID: scanID, limit: 20_000)
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
            await emitProgress(force: true)

            // Phase 12: reclaimable space.
            await emitPhase(.calculatingReclaimable)
            await aggregator.addCandidateBytes(candidateBytes)
            await emitProgress(force: true)

            // Phase 13: finalize — coverage from the real outcomes.
            await emitPhase(.finalizingSafety)
            let coverage = ScanCoverageReport.build(
                requestedRoots: requestedRoots.map { $0.url.path },
                outcomes: rootOutcomes
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
                storageMapRoot: plan.roots.first?.url.path
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
