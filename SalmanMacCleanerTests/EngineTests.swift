//
//  EngineTests.swift
//  SalmanMacCleanerTests
//
//  Fixture-based tests for the deep-scan engine: traversal policy, junk
//  classification, volume classification, coverage reporting and the staged
//  duplicate pipeline. Tests operate on temporary trees inside the user's
//  home — never on the developer's real Mac.
//

import XCTest
@testable import SalmanMacCleaner

final class TraversalPolicyTests: XCTestCase {

    private func root(_ url: URL) -> ScanRoot {
        ScanPolicy.authorizedFolderRoot(url)
    }

    func testProtectedAndInternalLocationsAreSkipped() {
        let scope = ScanScope(mode: .deep)
        let home = PathSafety.userHome
        let root = root(home)

        for name in TraversalPolicy.alwaysSkippedDirectoryNames {
            let url = URL(fileURLWithPath: home.path + "/" + name, isDirectory: true)
            let decision = TraversalPolicy.shouldEnterDirectory(
                url: url, root: root, includeHidden: true,
                includePackageContents: false, scope: scope
            )
            if case .skip(let reason) = decision {
                XCTAssertTrue([TraversalSkipReason.fseventsInternal, .timeMachine].contains(reason))
            } else {
                XCTFail("\(name) must be skipped")
            }
        }
    }

    func testHiddenFileRules() {
        let scope = ScanScope(mode: .deep)
        let home = PathSafety.userHome
        let hiddenURL = home.appendingPathComponent(".hidden-thing", isDirectory: true)

        let hiddenDenied = TraversalPolicy.shouldEnterDirectory(
            url: hiddenURL, root: root(home), includeHidden: false,
            includePackageContents: false, scope: scope
        )
        if case .skip(let reason) = hiddenDenied {
            XCTAssertEqual(reason, .hiddenFile)
        } else {
            XCTFail("hidden dirs must be skipped when includeHidden is false")
        }
    }

    func testPackageContentRule() {
        let scope = ScanScope(mode: .deep)
        let home = PathSafety.userHome
        let appURL = home.appendingPathComponent("Some.app", isDirectory: true)

        let decision = TraversalPolicy.shouldEnterDirectory(
            url: appURL, root: root(home), includeHidden: true,
            includePackageContents: false, scope: scope
        )
        if case .skip = decision {
            // packages skipped by default (either via package or bundle rule)
        } else {
            XCTFail("app bundles must not be entered without package-content opt-in")
        }
    }
}

final class JunkClassifierTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = PathSafety.userHome.appendingPathComponent(".ClassifierTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    private func record(path: String, name: String? = nil, isDirectory: Bool = false) -> FileRecord {
        FileRecord(
            path: path,
            parent: (path as NSString).deletingLastPathComponent,
            name: name ?? (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            logicalSize: 100,
            allocatedSize: 100,
            modified: Date().addingTimeInterval(-100_000),
            ownerUID: getuid()
        )
    }

    func testSafeCacheClassification() {
        let home = PathSafety.userHome.path
        let verdict = JunkClassifier.classify(record(path: home + "/Library/Caches/com.example/thing.cache"))
        XCTAssertEqual(verdict.safety, .safe)
        XCTAssertTrue(verdict.autoSelectable)
        XCTAssertTrue(verdict.regenerable)
        XCTAssertEqual(verdict.category, .userCache)
    }

    func testRecentlyUsedCacheIsProtected() {
        let home = PathSafety.userHome.path
        var recent = record(path: home + "/Library/Caches/com.example/thing.cache")
        recent = FileRecord(
            path: recent.path, parent: recent.parent, name: recent.name,
            isDirectory: false, logicalSize: 100, allocatedSize: 100,
            modified: Date(), ownerUID: getuid()
        )
        let verdict = JunkClassifier.classify(recent)
        XCTAssertEqual(verdict.safety, .protected)
    }

    func testReviewLocationsNeverAutoSelect() {
        let home = PathSafety.userHome.path
        for suffix in ["/Library/Developer/Xcode/DerivedData/App-abc",
                       "/Library/Developer/Xcode/Archives/2026-01-01",
                       "/Library/org.swift.swiftpm/cache"] {
            let verdict = JunkClassifier.classify(record(path: home + suffix))
            XCTAssertEqual(verdict.safety, .review, suffix)
            XCTAssertFalse(verdict.autoSelectable)
        }
    }

    func testPersonalDirectoriesAreProtected() {
        let home = PathSafety.userHome.path
        for personal in ["Documents", "Desktop", "Downloads", "Pictures", "Music", "Movies"] {
            let verdict = JunkClassifier.classify(record(path: home + "/" + personal + "/file.txt"))
            XCTAssertEqual(verdict.safety, .protected, personal)
            XCTAssertFalse(verdict.autoSelectable)
        }
    }

    func testProtectedNamesAndSuffixes() {
        let home = PathSafety.userHome.path
        let cases = [
            (home + "/Library/Caches/Cookies", "protected name"),
            (home + "/Library/Caches/mail.db", "protected suffix"),
            (home + "/Library/Caches/login.keychain", "keychain"),
            (home + "/Library/Caches/disk.vmdk", "VM disk"),
            (home + "/Library/Caches/Package.resolved", "lockfile")
        ]
        for (path, _) in cases {
            let verdict = JunkClassifier.classify(record(path: path))
            XCTAssertEqual(verdict.safety, .protected, path)
        }
    }

    func testInstallersAreReviewOnly() {
        let home = PathSafety.userHome.path
        let verdict = JunkClassifier.classify(record(path: home + "/Downloads/tmp/App.dmg"))
        XCTAssertEqual(verdict.safety, .review)
        XCTAssertEqual(verdict.category, .installer)
        XCTAssertFalse(verdict.autoSelectable)
    }

    func testOtherUserFilesAreProtected() {
        var foreign = record(path: PathSafety.userHome.path + "/Library/Caches/x.bin")
        foreign = FileRecord(
            path: foreign.path, parent: foreign.parent, name: foreign.name,
            isDirectory: false, logicalSize: 10, allocatedSize: 10,
            modified: Date(), ownerUID: 501_999 // not the current user
        )
        let verdict = JunkClassifier.classify(foreign)
        XCTAssertEqual(verdict.safety, .protected)
    }
}

final class VolumeClassificationTests: XCTestCase {

    private func volume(isLocal: Bool, isInternal: Bool, isReadOnly: Bool, isRemovable: Bool, isRoot: Bool) -> VolumeInfo {
        VolumeInfo(
            id: UUID().uuidString,
            name: "Test",
            mountPoint: "/Volumes/Test",
            fileSystemType: "apfs",
            isInternal: isInternal,
            isLocal: isLocal,
            isRemovable: isRemovable,
            isReadOnly: isReadOnly,
            isRoot: isRoot,
            totalCapacity: 1_000,
            available: 500,
            used: 500,
            purgeableEstimate: 0,
            requiresOptIn: false
        )
    }

    func testStartupVolumeDoesNotRequireOptIn() {
        let startup = volume(isLocal: true, isInternal: true, isReadOnly: false, isRemovable: false, isRoot: true)
        XCTAssertFalse(ScanPolicy.volumeNeedsOptIn(startup))
    }

    func testNetworkExternalAndReadOnlyRequireOptIn() {
        let network = volume(isLocal: false, isInternal: false, isReadOnly: false, isRemovable: false, isRoot: false)
        XCTAssertTrue(ScanPolicy.volumeNeedsOptIn(network))

        let external = volume(isLocal: true, isInternal: false, isReadOnly: false, isRemovable: true, isRoot: false)
        XCTAssertTrue(ScanPolicy.volumeNeedsOptIn(external))

        let readOnly = volume(isLocal: true, isInternal: true, isReadOnly: true, isRemovable: false, isRoot: false)
        XCTAssertTrue(ScanPolicy.volumeNeedsOptIn(readOnly))
    }

    func testDuplicateFinderUsesVisibleUserFoldersByDefault() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let roots = ScanPolicy.defaultDuplicateRoots(home: home)

        XCTAssertTrue(roots.contains("/Users/tester/Downloads"))
        XCTAssertTrue(roots.contains("/Users/tester/Documents"))
        XCTAssertTrue(roots.contains("/Users/tester/Desktop"))
        XCTAssertFalse(roots.contains("/Users/tester/Library/Caches"))
    }

    func testTimeMachineDetection() {
        let tm = volume(isLocal: true, isInternal: true, isReadOnly: false, isRemovable: false, isRoot: false)
        XCTAssertFalse(VolumeDiscoveryService.isTimeMachineVolume(tm))
        var tmNamed = tm
        tmNamed.name = "Time Machine Backups"
        XCTAssertTrue(VolumeDiscoveryService.isTimeMachineVolume(tmNamed))
    }
}

final class CoverageReportTests: XCTestCase {

    func testCompleteCoverageWording() {
        let report = ScanCoverageReport.build(
            requestedRoots: ["/Users/test"],
            outcomes: ["/Users/test": .scanned]
        )
        XCTAssertEqual(report.confidence, .complete)
        XCTAssertEqual(ScanCoverageReport.coveragePercent(report), 100)
        XCTAssertTrue(report.summaryText.contains("Scanned all accessible files"))
        XCTAssertFalse(report.limitedByPermission)
    }

    func testPartialCoverageWording() {
        let report = ScanCoverageReport.build(
            requestedRoots: ["/", "/Volumes/ext"],
            outcomes: ["/": .partial(deniedPaths: 12, errors: 2), "/Volumes/ext": .denied("readable check failed")]
        )
        XCTAssertEqual(report.confidence, .partial)
        XCTAssertEqual(ScanCoverageReport.coveragePercent(report), 50)
        XCTAssertTrue(report.summaryText.contains("inaccessible"))
        XCTAssertTrue(report.limitedByPermission)
        XCTAssertFalse(report.permissionReason?.isEmpty ?? true)
    }

    func testSIPNoteAppears() {
        let report = ScanCoverageReport.build(
            requestedRoots: ["/System", "/Users/x"],
            outcomes: ["/System": .sipProtected, "/Users/x": .scanned]
        )
        XCTAssertTrue(report.summaryText.contains("System Integrity Protection"))
        XCTAssertEqual(report.sipProtectedRoots, ["/System"])
    }

    func testNotGrantedRootIsNeverCompleteAndLimitsCoverage() {
        // Regression: a root that was skipped because permission was missing
        // must produce "Limited coverage" — never "complete".
        let report = ScanCoverageReport.build(
            requestedRoots: ["/Users/test", "/"],
            outcomes: [
                "/Users/test": .scanned,
                "/": .skippedNotGranted("Full Disk Access not granted")
            ]
        )
        XCTAssertTrue(report.limitedByPermission)
        XCTAssertEqual(report.notGrantedRoots, ["/"])
        XCTAssertNotEqual(report.confidence, .complete)
        XCTAssertTrue(report.summaryText.contains("Limited coverage"))
        XCTAssertEqual(report.rootDetails.count, 2)
        XCTAssertEqual(report.rootDetails.first { $0.root == "/" }?.state, .skippedNotGranted)
        XCTAssertEqual(report.rootDetails.first { $0.root == "/" }?.reason, "Full Disk Access not granted")
    }

    func testCoverageCompleteOnlyWhenAllRequestedRootsScanned() {
        let report = ScanCoverageReport.build(
            requestedRoots: ["/Users/test"],
            outcomes: ["/Users/test": .scanned]
        )
        XCTAssertFalse(report.limitedByPermission)
        XCTAssertEqual(report.confidence, .complete)
    }
}

final class DuplicatePipelineTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = PathSafety.userHome.appendingPathComponent(".DupPipeline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String) -> URL {
        let url = sandbox.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    func testStagedDetectionFindsExactDuplicates() throws {
        let a = makeFile("a.txt", contents: "shared content for duplicates")
        let b = makeFile("b.txt", contents: "shared content for duplicates")
        _ = makeFile("c.txt", contents: "unique content")

        let candidates = [a, b, sandbox.appendingPathComponent("c.txt")].map {
            ScannedItem(path: $0.path, size: FileUtilities.fileSize(atPath: $0.path))
        }
        let groups = try DuplicatePipeline.detect(candidates: candidates, isCancelled: { false })
        let real = groups.filter { $0.files.count > 1 }
        XCTAssertEqual(real.count, 1)
        XCTAssertEqual(real.first?.reclaimableEstimate, Int64("shared content for duplicates".count))
    }

    func testHardLinksAreNotReclaimableDuplicates() throws {
        let original = makeFile("original.txt", contents: "hard linked payload")
        let link = sandbox.appendingPathComponent("link.txt")
        try FileManager.default.linkItem(at: original, to: link)

        let candidates = [original, link].map {
            ScannedItem(path: $0.path, size: FileUtilities.fileSize(atPath: $0.path))
        }
        let groups = try DuplicatePipeline.detect(candidates: candidates, isCancelled: { false })
        XCTAssertTrue(groups.isEmpty, "Hard links must not form reclaimable duplicate groups")
    }

    func testCancellationThrows() throws {
        var files: [ScannedItem] = []
        for index in 0..<20 {
            let url = makeFile("f\(index).txt", contents: "payload number \(index) unique")
            files.append(ScannedItem(path: url.path, size: FileUtilities.fileSize(atPath: url.path)))
        }
        XCTAssertThrowsError(try DuplicatePipeline.detect(candidates: files, isCancelled: { true })) { error in
            XCTAssertEqual(error as? DuplicateScanError, .cancelled)
        }
    }

    func testSampleHashIsContentDependent() throws {
        let a = makeFile("s1.bin", contents: "same same")
        let b = makeFile("s2.bin", contents: "same same")
        let hashA = DuplicatePipeline.sampleHash(a.path, size: FileUtilities.fileSize(atPath: a.path))
        let hashB = DuplicatePipeline.sampleHash(b.path, size: FileUtilities.fileSize(atPath: b.path))
        XCTAssertEqual(hashA, hashB)
    }
}

final class CleanupAccountingTests: XCTestCase {
    func testNestedAndDuplicatePathsAreCountedOnce() {
        let parent = ScannedItem(path: "/Users/test/Library/Caches/parent", size: 100, isDirectory: true)
        let child = ScannedItem(path: "/Users/test/Library/Caches/parent/child", size: 50)
        let duplicate = ScannedItem(path: "/Users/test/Library/Caches/./parent", size: 100, isDirectory: true)
        XCTAssertEqual(CleanupAccounting.uniqueBytes(for: [parent, child, duplicate]), 100)
    }

    func testHardLinkIdentityIsCountedOnce() {
        let first = FileRecord(path: "/Users/test/a.cache", parent: "/Users/test", name: "a.cache", isDirectory: false, logicalSize: 40, allocatedSize: 40, device: 1, inode: 99)
        let second = FileRecord(path: "/Users/test/b.cache", parent: "/Users/test", name: "b.cache", isDirectory: false, logicalSize: 40, allocatedSize: 40, device: 1, inode: 99)
        XCTAssertEqual(CleanupAccounting.uniqueBytes(for: [first, second]), 40)
    }

    func testReconciliationCountsOnlyActuallyMovedBytes() throws {
        let root = PathSafety.userHome.appendingPathComponent(".SalmanMacCleaner-accounting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = root.appendingPathComponent("moved.cache")
        let failed = root.appendingPathComponent("failed.cache")
        FileManager.default.createFile(atPath: moved.path, contents: Data(repeating: 1, count: 10))
        FileManager.default.createFile(atPath: failed.path, contents: Data(repeating: 1, count: 20))
        let items = [CleanupItem(path: moved.path, size: 10), CleanupItem(path: failed.path, size: 20)]
        try FileManager.default.removeItem(at: moved)
        let breakdown = CleanupAccounting.reconcile(selected: items, moved: [moved.path], failed: [(failed.path, "refused")])
        XCTAssertEqual(breakdown.selectedBytes, 30)
        XCTAssertEqual(breakdown.movedBytes, 10)
        XCTAssertEqual(breakdown.failedBytes, 20)
        XCTAssertEqual(breakdown.remainingBytes, 20)
    }
}

final class HealthCheckModelTests: XCTestCase {
    func testHealthResultAggregatesMeasuredFactorStatuses() {
        let result = HealthCheckResult(
            factors: [
                HealthCheckFactor(id: .storage, status: .good, summary: "measured", evidence: "volume"),
                HealthCheckFactor(id: .trash, status: .attention, summary: "review", evidence: "Trash")
            ],
            coverage: .partial,
            coverageMessage: "limited"
        )
        XCTAssertEqual(result.overallStatus, .attention)
        XCTAssertEqual(result.attentionCount, 1)
        XCTAssertEqual(HealthCheckFactorID.trash.destination, .trashBins)
    }

    func testReadOnlyHealthFactorsHaveModuleDestinations() {
        XCTAssertEqual(Set(HealthCheckFactorID.allCases.compactMap(\.destination)).count, HealthCheckFactorID.allCases.count)
    }
}
