//
//  DeepScanRegressionTests.swift
//  SalmanMacCleanerTests
//
//  Regression suite for the "Deep Scan completed with Items scanned: 1,
//  Zero KB candidates" defect. Every test builds a temporary fixture tree
//  inside the user's home and asserts the *real* inventory behavior:
//  - more than one file is inventoried
//  - the scan root itself is never counted as a file
//  - cache/log fixture files classify as SAFE junk candidates
//  - protected files are skipped
//  - inaccessible roots are reported as skipped/denied — never "scanned"
//  - coverage is Limited without permission and Complete only after every
//    intended accessible root was genuinely scanned
//

import XCTest
@testable import SalmanMacCleaner

final class DeepScanRegressionTests: XCTestCase {

    private var fixture: URL!

    override func setUp() {
        super.setUp()
        fixture = PathSafety.userHome
            .appendingPathComponent(".DeepScanRegression-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let fixture {
            // Restore permissions first so the fixture can be removed.
            for path in allPaths(under: fixture) {
                _ = chmod(path, 0o755)
            }
            try? FileManager.default.removeItem(at: fixture)
        }
        super.tearDown()
    }

    private func allPaths(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return enumerator.compactMap { ($0 as? String).map { root.path + "/" + $0 } }
    }

    @discardableResult
    private func makeFile(_ relative: String, contents: String, modifiedAgo days: TimeInterval = 30) -> URL {
        let url = fixture.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        let attributes: [FileAttributeKey: Any] = [
            .modificationDate: Date().addingTimeInterval(-days * 86_400)
        ]
        try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        return url
    }

    // MARK: - The exact regression

    func testDeepScanOfFixtureInventoriesEveryFileAndNeverCountsTheRoot() async throws {
        // 25 files: cache entries, logs, a large file, duplicates.
        for index in 0..<10 {
            _ = makeFile("Library/Caches/com.fixture.app/cache-\(index).bin",
                         contents: String(repeating: "c", count: 100 + index))
        }
        for index in 0..<5 {
            _ = makeFile("Library/Logs/com.fixture.app/app-\(index).log",
                         contents: "log line \(index)")
        }
        _ = makeFile("Library/Caches/com.fixture.app/large.bin",
                     contents: String(repeating: "L", count: 200_000))
        _ = makeFile("Library/Caches/com.fixture.app/dup-a.txt", contents: "identical duplicate payload")
        _ = makeFile("Library/Caches/com.fixture.app/dup-b.txt", contents: "identical duplicate payload")
        _ = makeFile("Library/Caches/com.fixture.app/data.sqlite", contents: "protected database")
        for index in 0..<6 {
            _ = makeFile("project/file-\(index).txt", contents: "plain file \(index)")
        }

        var records: [FileRecord] = []
        let gate = ScanGate()
        let root = ScanPolicy.authorizedFolderRoot(fixture)
        let results = try await FileInventoryScanner.scan(
            roots: [root],
            includeHidden: false,
            includePackageContents: false,
            minFileSize: 0,
            sink: { record, _ in records.append(record) },
            counts: { _, _ in },
            gate: gate,
            isCancelled: { false }
        )

        // Regression: must be far more than one item.
        XCTAssertGreaterThan(records.count, 20, "Deep scan must inventory the real fixture files")

        // Regression: the scan root itself must never be recorded as a file.
        XCTAssertFalse(records.contains { $0.path == fixture.path },
                       "The scan root must not be counted as a scanned item")
        XCTAssertFalse(records.contains { $0.path == fixture.path && !$0.isDirectory },
                       "The scan root must never masquerade as a file")

        // Honest outcome: the granted fixture root is genuinely scanned.
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.root, fixture.path)
        switch result.outcome {
        case .scanned:
            break
        case .partial:
            break
        default:
            XCTFail("A readable fixture root must be scanned or partially scanned, got \(result.outcome)")
        }
        XCTAssertEqual(result.counts.files, records.count)
    }

    func testFixtureCacheAndLogFilesClassifySafe() async throws {
        let cacheFile = makeFile("Library/Caches/com.fixture.app/cache.bin", contents: "cache content")
        let logFile = makeFile("Library/Logs/com.fixture.app/app.log", contents: "log content")
        let plainFile = makeFile("project/data.txt", contents: "plain content")
        let protectedFile = makeFile("Library/Caches/com.fixture.app/mail.db", contents: "database")

        let libraryRoots = [fixture.path + "/Library/Caches", fixture.path + "/Library/Logs"]
        let records = [cacheFile, logFile, plainFile, protectedFile].compactMap {
            MetadataCollector.collect(url: $0)
        }
        XCTAssertEqual(records.count, 4)

        let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })
        let cacheVerdict = JunkClassifier.classify(byPath[cacheFile.path]!, libraryRoots: libraryRoots)
        XCTAssertEqual(cacheVerdict.safety, .safe, "Fixture cache files must classify SAFE")
        XCTAssertTrue(cacheVerdict.autoSelectable)

        let logVerdict = JunkClassifier.classify(byPath[logFile.path]!, libraryRoots: libraryRoots)
        XCTAssertEqual(logVerdict.safety, .safe, "Fixture log files must classify SAFE")

        let plainVerdict = JunkClassifier.classify(byPath[plainFile.path]!, libraryRoots: libraryRoots)
        XCTAssertNotEqual(plainVerdict.safety, .safe, "Non-cache files must never be SAFE")

        let protectedVerdict = JunkClassifier.classify(byPath[protectedFile.path]!, libraryRoots: libraryRoots)
        XCTAssertEqual(protectedVerdict.safety, .protected, "Protected database files must be skipped")
    }

    func testProtectedFilesAreSkippedByTheCleanupPlan() async throws {
        let safeFile = makeFile("Library/Caches/com.fixture.app/safe.bin", contents: "safe")
        let cookiesFile = makeFile("Library/Caches/com.fixture.app/Cookies", contents: "session data")
        let keychainFile = makeFile("Library/Caches/com.fixture.app/login.keychain-db", contents: "keychain")

        let records = [safeFile, cookiesFile, keychainFile].compactMap {
            MetadataCollector.collect(url: $0)
        }
        let libraryRoots = [fixture.path + "/Library/Caches"]
        let selection = records.map { ScannedItem(path: $0.path, size: $0.logicalSize) }
        let plan = CleanupPlanBuilder.build(
            selection: selection,
            records: records,
            containmentRoot: fixture.path,
            previewOnly: true
        )
        XCTAssertEqual(plan.items.count, 1, "Only the SAFE item may enter the plan")
        XCTAssertEqual(plan.items.first?.path, safeFile.path)

        // And the classifier must never mark them SAFE either.
        for record in records where record.path != safeFile.path {
            let verdict = JunkClassifier.classify(record, libraryRoots: libraryRoots)
            XCTAssertEqual(verdict.safety, .protected)
        }
    }

    func testInaccessibleRootIsReportedSkippedNeverScanned() async throws {
        // A root that exists but cannot be read must never be marked scanned.
        let blocked = fixture.appendingPathComponent("blocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        _ = makeFile("blocked/hidden-inside.txt", contents: "inaccessible")
        XCTAssertEqual(chmod(blocked.path, 0o000), 0, "chmod must succeed in the test sandbox")

        let root = ScanPolicy.authorizedFolderRoot(blocked)
        let results = try await FileInventoryScanner.scan(
            roots: [root],
            includeHidden: false,
            includePackageContents: false,
            minFileSize: 0,
            sink: { _, _ in },
            counts: { _, _ in },
            gate: ScanGate(),
            isCancelled: { false }
        )
        let result = try XCTUnwrap(results.first)
        switch result.outcome {
        case .denied(let reason):
            XCTAssertFalse(reason.isEmpty, "The denial must carry an exact reason")
        case .partial:
            break // traversal reached the root but children were denied
        case .scanned:
            XCTFail("An unreadable root must never be reported as scanned")
        default:
            XCTFail("Unexpected outcome \(result.outcome)")
        }
        XCTAssertEqual(result.counts.files, 0, "An unreadable root yields no inventory")
    }

    func testMissingRootIsReportedNotGrantedOrDenied() async throws {
        let missing = fixture.appendingPathComponent("does-not-exist", isDirectory: true)
        let root = ScanPolicy.authorizedFolderRoot(missing)
        let results = try await FileInventoryScanner.scan(
            roots: [root],
            includeHidden: false,
            includePackageContents: false,
            minFileSize: 0,
            sink: { _, _ in },
            counts: { _, _ in },
            gate: ScanGate(),
            isCancelled: { false }
        )
        let result = try XCTUnwrap(results.first)
        if case .scanned = result.outcome {
            XCTFail("A missing root must never be reported as scanned")
        }
    }

    func testCoverageIsLimitedWithoutPermissionAndCompleteOnlyAfterRealScans() async throws {
        // Simulate what the coordinator does: not-granted roots are recorded
        // up front, real scanner results replace the granted ones.
        var outcomes: [String: RootOutcome] = [
            "/Users/test": .scanned,
            "/": .skippedNotGranted("Full Disk Access not granted")
        ]
        let limited = ScanCoverageReport.build(requestedRoots: ["/Users/test", "/"], outcomes: outcomes)
        XCTAssertTrue(limited.limitedByPermission, "Missing permission must mean Limited coverage")
        XCTAssertNotEqual(limited.confidence, .complete)

        // After permission is granted and the volume root is really scanned,
        // coverage becomes complete.
        outcomes["/"] = .scanned
        let complete = ScanCoverageReport.build(requestedRoots: ["/Users/test", "/"], outcomes: outcomes)
        XCTAssertFalse(complete.limitedByPermission)
        XCTAssertEqual(complete.confidence, .complete)
    }

    func testDeepScanPolicyIncludesHomeByDefaultAndReportsVolumeWithoutPermission() {
        let volumes = [
            VolumeInfo(id: "/", name: "Macintosh HD", mountPoint: "/", fileSystemType: "apfs",
                       isInternal: true, isLocal: true, isRemovable: false, isReadOnly: false,
                       isRoot: true, totalCapacity: 1_000, available: 500, used: 500,
                       purgeableEstimate: 0, requiresOptIn: false)
        ]
        let scope = ScanScope(mode: .deep, volumes: ["/"])
        let plan = ScanPolicy.resolve(
            scope: scope,
            volumes: volumes,
            fdaStatus: .limitedAccess,
            authorizedFolders: []
        )

        // Home root is always granted.
        let homeRoot = plan.roots.first { $0.kind == .userHome }
        XCTAssertNotNil(homeRoot)
        XCTAssertTrue(homeRoot?.granted ?? false)

        // The startup volume root exists but is NOT granted without FDA.
        let volumeRoot = plan.roots.first { $0.kind == .volumeRoot }
        XCTAssertNotNil(volumeRoot)
        XCTAssertFalse(volumeRoot?.granted ?? true, "Volume root without FDA must not be granted")
        XCTAssertTrue(volumeRoot?.notGrantedReason?.contains("Full Disk Access") ?? false)
        XCTAssertTrue(plan.isCoverageLimited)

        // With FDA the volume root becomes granted and coverage full.
        let grantedPlan = ScanPolicy.resolve(
            scope: scope,
            volumes: volumes,
            fdaStatus: .likelyFullAccess,
            authorizedFolders: []
        )
        let grantedVolume = grantedPlan.roots.first { $0.kind == .volumeRoot }
        XCTAssertTrue(grantedVolume?.granted ?? false)
        XCTAssertFalse(grantedPlan.isCoverageLimited)
    }

    func testQuickScanRootsAreAllGrantedAndCoverCaches() {
        let plan = ScanPolicy.resolve(
            scope: ScanScope(mode: .quick),
            volumes: [],
            fdaStatus: .limitedAccess,
            authorizedFolders: []
        )
        XCTAssertFalse(plan.roots.isEmpty)
        XCTAssertTrue(plan.roots.allSatisfy { $0.granted },
                      "Quick Scan roots are user-owned and must always be granted")
        XCTAssertTrue(plan.libraryRoots.contains(PathSafety.userHome.path + "/Library/Caches"))
        XCTAssertTrue(plan.libraryRoots.contains(PathSafety.userHome.path + "/Library/Logs"))
    }

    func testAuthorizedFolderRootIsGrantedEvenOutsideHome() {
        let external = URL(fileURLWithPath: "/Volumes/External/Data", isDirectory: true)
        let root = ScanPolicy.authorizedFolderRoot(external)
        XCTAssertTrue(root.granted)
        XCTAssertTrue(root.allowsOutsideHome)
    }

    func testVolumeRootDeviceGroupSpansDataVolume() {
        let volumes = [
            VolumeInfo(id: "/", name: "Macintosh HD", mountPoint: "/", fileSystemType: "apfs",
                       isInternal: true, isLocal: true, isRemovable: false, isReadOnly: false,
                       isRoot: true, totalCapacity: 1_000, available: 500, used: 500,
                       purgeableEstimate: 0, requiresOptIn: false)
        ]
        let plan = ScanPolicy.resolve(
            scope: ScanScope(mode: .deep, volumes: ["/"]),
            volumes: volumes,
            fdaStatus: .likelyFullAccess,
            authorizedFolders: []
        )
        let root = plan.roots.first { $0.kind == .volumeRoot }
        XCTAssertNotNil(root)
        let systemDevice = PathSafety.deviceID(of: "/").map { Int32(clamping: $0) }
        let dataDevice = PathSafety.deviceID(of: PathSafety.userHome.path).map { Int32(clamping: $0) }
        if let systemDevice {
            XCTAssertTrue(root?.expectedDevices.contains(systemDevice) ?? false)
        }
        if let dataDevice {
            // On APFS with a sealed system volume these differ; either way the
            // data volume device must be part of the granted group so user
            // files are not rejected as cross-volume.
            XCTAssertTrue(root?.expectedDevices.contains(dataDevice) ?? false)
        }
    }

    func testInventoryCountsMerge() {
        var totals = InventoryCounts()
        var part = InventoryCounts()
        part.files = 5
        part.bytesIndexed = 100
        totals.merge(part)
        totals.merge(part)
        XCTAssertEqual(totals.files, 10)
        XCTAssertEqual(totals.bytesIndexed, 200)
    }
}
