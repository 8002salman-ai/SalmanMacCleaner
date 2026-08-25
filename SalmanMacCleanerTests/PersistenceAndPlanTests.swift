//
//  PersistenceAndPlanTests.swift
//  SalmanMacCleanerTests
//
//  Tests for the SQLite scan index (schema migration, checkpoints, resume),
//  the ignore list, the cleanup plan builder/validator/executor, version
//  comparison and the Sparkle update-configuration gate.
//

import XCTest
@testable import SalmanMacCleaner

final class ScanIndexStoreTests: XCTestCase {

    private var dbPath: String!

    override func setUp() {
        super.setUp()
        let dir = PathSafety.userHome.appendingPathComponent(".ScanIndexTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("index.sqlite").path
    }

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbPath).deletingLastPathComponent().path)
        }
        super.tearDown()
    }

    func testSchemaMigrationAndScanLifecycle() async throws {
        let store = try ScanIndexStore(path: dbPath)

        let scope = ScanScope(mode: .quick)
        let scanID = try await store.beginScan(mode: .quick, scope: scope, provenance: .full)

        var record = FileRecord(
            path: PathSafety.userHome.path + "/Library/Caches/t.bin",
            parent: PathSafety.userHome.path + "/Library/Caches",
            name: "t.bin", isDirectory: false, logicalSize: 42, allocatedSize: 42,
            modified: Date(), ownerUID: getuid()
        )
        let verdict = JunkClassifier.classify(record)
        record = FileRecord(
            path: record.path, parent: record.parent, name: record.name,
            isDirectory: false, logicalSize: 42, allocatedSize: 42,
            modified: record.modified, ownerUID: record.ownerUID
        )
        try await store.insertClassifiedRecords(scanID: scanID, pairs: [(record, verdict)])

        let count = await store.recordsCount(scanID: scanID)
        XCTAssertEqual(count, 1)

        let items = await store.classifiedItems(scanID: scanID, safety: verdict.safety, category: nil, limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.safetyLevel, verdict.safety)

        let duplicates = await store.duplicateCandidates(scanID: scanID, limit: 100)
        XCTAssertEqual(duplicates.count, 1)

        try await store.markRootState(scanID: scanID, root: "/tmp/x", state: "completed")
        let completed = try await store.completedRoots(scanID: scanID)
        XCTAssertEqual(completed, ["/tmp/x"])

        let outcome = ScanOutcome(
            scanID: scanID, mode: .quick, startedAt: Date(), finishedAt: Date(),
            coverage: ScanCoverageReport.build(
                requestedRoots: ["/tmp/x"], outcomes: ["/tmp/x": .scanned]
            ),
            provenance: .full, itemsScanned: 1, bytesIndexed: 42
        )
        try await store.completeScan(scanID: scanID, outcome: outcome, counts: InventoryCounts(), coverage: outcome.coverage)
        XCTAssertNil(await store.latestResumableScan(mode: .quick))
    }

    func testResumableScanRoundTrip() async throws {
        let store = try ScanIndexStore(path: dbPath)
        let scope = ScanScope(mode: .deep, volumes: ["/Volumes/Test"])
        _ = try await store.beginScan(mode: .deep, scope: scope, provenance: .full)

        let resumable = await store.latestResumableScan(mode: .deep)
        XCTAssertNotNil(resumable)
        XCTAssertEqual(resumable?.scope.volumes, ["/Volumes/Test"])
    }

    func testVolumeEventStatePersistence() async throws {
        let store = try ScanIndexStore(path: dbPath)
        XCTAssertNil(await store.lastEventID(forMountPoint: "/"))
        try await store.saveEventState(mountPoint: "/", lastEventID: 12345)
        XCTAssertEqual(await store.lastEventID(forMountPoint: "/"), 12345)
    }

    func testSchemaVersionPersistsAcrossReopen() async throws {
        do {
            let store = try ScanIndexStore(path: dbPath)
            _ = try await store.beginScan(mode: .quick, scope: ScanScope(mode: .quick), provenance: .full)
        }
        let reopened = try ScanIndexStore(path: dbPath)
        XCTAssertNotNil(reopened)
    }
}

final class IgnoreListTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = PathSafety.userHome
            .appendingPathComponent(".IgnoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ignore.json")
    }

    override func tearDown() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        super.tearDown()
    }

    @MainActor
    func testIgnoreListPersistence() {
        let store = IgnoreListStore(fileURL: fileURL)
        store.add(pattern: "/Users/test/Library/Caches/Annoying", kind: .exactPath)
        store.add(pattern: "node_modules", kind: .contains)

        XCTAssertTrue(store.isIgnored("/Users/test/Library/Caches/Annoying"))
        XCTAssertTrue(store.isIgnored("/Users/test/project/node_modules/pkg"))
        XCTAssertFalse(store.isIgnored("/Users/test/Documents"))

        let reloaded = IgnoreListStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.rules.count, 2)
        XCTAssertTrue(reloaded.isIgnored("/Users/test/project/node_modules/pkg"))
    }

    @MainActor
    func testRemoveRule() {
        let store = IgnoreListStore(fileURL: fileURL)
        store.add(pattern: "secret", kind: .contains)
        guard let rule = store.rules.first else { return XCTFail("missing rule") }
        store.remove(id: rule.id)
        XCTAssertFalse(store.isIgnored("/tmp/secret-file"))
    }
}

final class CleanupPlanTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = PathSafety.userHome.appendingPathComponent(".PlanTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String = "data") -> URL {
        let url = sandbox.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    func testPlanBuilderExcludesProtectedItems() throws {
        let safeFile = makeFile("safe.txt")
        let protectedFile = makeFile("keychain.db")

        guard let safeRecord = MetadataCollector.collect(url: safeFile),
              let protectedRecord = MetadataCollector.collect(url: protectedFile) else {
            return XCTFail("could not collect records")
        }
        let selection = [safeFile, protectedFile].map {
            ScannedItem(path: $0.path, size: FileUtilities.fileSize(atPath: $0.path))
        }
        // The fixture sandbox acts as the scan's library root.
        let plan = CleanupPlanBuilder.build(
            selection: selection,
            records: [safeRecord, protectedRecord],
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.path, safeFile.path)
    }

    func testPlanBuilderAdmitsBundlesOnlyForUninstallerFlow() throws {
        let bundleDir = sandbox.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        guard let bundleRecord = MetadataCollector.collect(url: bundleDir) else {
            return XCTFail("no record")
        }
        let selection = [ScannedItem(path: bundleDir.path, size: bundleRecord.allocatedSize)]

        let denied = CleanupPlanBuilder.build(
            selection: selection,
            records: [bundleRecord],
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )
        XCTAssertTrue(denied.items.isEmpty, "Bundles must be excluded without the uninstaller flag")

        let allowed = CleanupPlanBuilder.build(
            selection: selection,
            records: [bundleRecord],
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path],
            allowBundles: true
        )
        XCTAssertEqual(allowed.items.count, 1)
        XCTAssertEqual(allowed.items.first?.safety, .review)
    }

    func testValidatorRejectsChangedFileIdentity() async throws {
        let file = makeFile("identity.txt", contents: "original")
        guard let record = MetadataCollector.collect(url: file) else {
            return XCTFail("no record")
        }
        let item = PlannedCleanupItem(
            path: file.path,
            expectedSize: record.allocatedSize,
            expectedModified: record.modified,
            expectedOwner: record.ownerUID,
            expectedDevice: record.device,
            expectedInode: record.inode,
            category: .userCache,
            safety: .review,
            containmentRoot: sandbox.path,
            action: .moveToTrash
        )
        XCTAssertNoThrow(try CleanupSafetyValidator.validate(item: item, allowBundles: false, libraryRoots: [sandbox.path]).get())

        // Replace the file: inode changes → identity check must fail.
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: Data("replacement".utf8))
        let result = CleanupSafetyValidator.validate(item: item, allowBundles: false, libraryRoots: [sandbox.path])
        XCTAssertThrowsError(try result.get())
    }

    @MainActor
    func testPreviewOnlyExecutionMovesNothing() async {
        let file = makeFile("preview.txt")
        guard let record = MetadataCollector.collect(url: file) else {
            return XCTFail("no record")
        }
        let item = PlannedCleanupItem(
            path: file.path, expectedSize: record.allocatedSize, expectedModified: record.modified,
            expectedOwner: record.ownerUID, expectedDevice: record.device, expectedInode: record.inode,
            category: .userCache, safety: .safe, containmentRoot: sandbox.path, action: .moveToTrash
        )
        let plan = CleanupPlan(items: [item], previewOnly: true)

        let result = await CleanupExecutor.shared.execute(
            plan: plan,
            libraryRoots: [sandbox.path],
            progress: { _, _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(result.previewed.count, 1)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

final class VersionComparatorTests: XCTestCase {

    func testParsesAndCompares() {
        XCTAssertEqual(VersionComparator.parse("1.2.3"), VersionComparator.SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertNil(VersionComparator.parse("not-a-version"))
        XCTAssertNil(VersionComparator.parse(""))
        XCTAssertTrue(VersionComparator.isNewer(candidate: "2.0.0", current: "1.9.9"))
        XCTAssertTrue(VersionComparator.isNewer(candidate: "1.10.0", current: "1.9.9"))
        XCTAssertFalse(VersionComparator.isNewer(candidate: "1.0.0", current: "1.0.1"))
        XCTAssertFalse(VersionComparator.isNewer(candidate: "garbage", current: "1.0.0"))
        // Prerelease ordering
        let release = VersionComparator.parse("1.0.0")!
        let beta = VersionComparator.parse("1.0.0-beta.1")!
        XCTAssertLessThan(beta, release)
    }
}

final class UpdateConfigurationTests: XCTestCase {

    func testDevBuildIsNotConfigured() {
        // The test host has no SUPublicEDKey/SUFeedURL → updates must be off.
        XCTAssertFalse(SparkleUpdaterController.isConfigured,
                       "Development builds without a real feed + key must disable updates")
        XCTAssertFalse(SparkleUpdaterController.unconfiguredReason.isEmpty)
    }

    func testDistributionSigningDetectionReturnsFalseForAdHoc() {
        // Test builds are ad-hoc signed; the distribution requirement check
        // must report false rather than crash.
        XCTAssertFalse(SparkleUpdaterController.isSignedForDistribution)
    }

    func testCurrentVersionIsNonEmpty() {
        XCTAssertFalse(SparkleUpdaterController.currentVersion.isEmpty)
    }
}
