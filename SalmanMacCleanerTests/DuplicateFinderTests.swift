//
//  DuplicateFinderTests.swift
//  SalmanMacCleanerTests
//
//  Tests for streaming hashing and duplicate grouping, including hard links.
//

import XCTest
@testable import SalmanMacCleaner

final class DuplicateFinderTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = PathSafety.userHome.appendingPathComponent(".SalmanMacCleanerTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Streaming hashes

    func testStreamingHashMatchesKnownVector() throws {
        let file = makeFile("vector.txt", contents: "abc")
        let digest = Crypto.sha256Hex(ofFileAt: file.path)
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStreamingHashIsContentDependent() throws {
        let a = makeFile("a.bin", contents: "same same")
        let b = makeFile("b.bin", contents: "same same")
        let c = makeFile("c.bin", contents: "different!")
        let hashA = Crypto.sha256Hex(ofFileAt: a.path)
        let hashB = Crypto.sha256Hex(ofFileAt: b.path)
        let hashC = Crypto.sha256Hex(ofFileAt: c.path)
        XCTAssertEqual(hashA, hashB)
        XCTAssertNotEqual(hashA, hashC)
    }

    func testStreamingHashOfLargeFileIsChunked() throws {
        // 3 MiB of data — larger than the 1 MiB chunk — exercises the loop.
        let big = sandbox.appendingPathComponent("big.bin")
        let data = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: big)

        let digest = Crypto.sha256Hex(ofFileAt: big.path)
        XCTAssertNotNil(digest)
        XCTAssertEqual(digest?.count, 64)
    }

    func testStreamingHashCancellation() {
        let file = makeFile("cancel.txt", contents: String(repeating: "x", count: 5000))
        var cancelled = false
        let result = Crypto.sha256(ofFileAt: file.path, isCancelled: { cancelled })
        XCTAssertNotNil(try? result.get())

        cancelled = true
        let cancelledResult = Crypto.sha256(ofFileAt: file.path, isCancelled: { cancelled })
        if case .failure(let error) = cancelledResult {
            XCTAssertEqual(error, .cancelled)
        } else {
            XCTFail("Expected cancellation error")
        }
    }

    // MARK: - Duplicate grouping

    func testDuplicateGroupingFindsExactDuplicates() throws {
        _ = makeFile("one.txt", contents: "duplicate content here")
        _ = makeFile("two.txt", contents: "duplicate content here")
        _ = makeFile("unique.txt", contents: "unique content")

        let groups = try DuplicateFinder.scan(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )

        let duplicateGroups = groups.filter { $0.files.count > 1 }
        XCTAssertEqual(duplicateGroups.count, 1, "Exactly one duplicate group expected")
        XCTAssertEqual(duplicateGroups.first?.files.count, 2)
        XCTAssertEqual(duplicateGroups.first?.reclaimableBytes, Int64("duplicate content here".count))
    }

    func testScanReportMarksDepthLimitedCoverage() throws {
        let nested = sandbox.appendingPathComponent("nested/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = makeFile("nested/deeper/file.txt", contents: "depth limited payload")

        let report = try DuplicateFinder.scanReport(
            roots: [sandbox],
            maxDepth: 0,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertTrue(report.isPartial, "Unvisited child directories must be reported as partial coverage")
        XCTAssertTrue(report.truncated)
        XCTAssertGreaterThanOrEqual(report.directoriesVisited, 1)
    }

    func testDuplicateGroupsHaveKeeperAndRemovableFiles() throws {
        _ = makeFile("a.txt", contents: "keeper content 123")
        _ = makeFile("b.txt", contents: "keeper content 123")

        let groups = try DuplicateFinder.scan(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )
        guard let group = groups.first(where: { $0.files.count > 1 }) else {
            return XCTFail("Expected a duplicate group")
        }
        XCTAssertNotNil(group.keeper)
        XCTAssertEqual(group.removableFiles.count, 1)
        XCTAssertEqual(group.reclaimableBytes, group.size)
    }

    // MARK: - Modified dates, considered bytes and live stats

    func testDuplicateScanCapturesModifiedDatesAndConsideredBytes() throws {
        _ = makeFile("a.txt", contents: "dated content one")
        _ = makeFile("b.txt", contents: "dated content one")
        _ = makeFile("c.txt", contents: "solo content ok")

        guard let expectedBytes = try? FileManager.default
            .contentsOfDirectory(at: sandbox, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(Int64(0), { sum, url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                return CleanupAccounting.adding(sum, Int64(values?.fileSize ?? 0))
            }) else {
            return XCTFail("Unable to measure sandbox bytes")
        }

        let report = try DuplicateFinder.scanReport(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(report.filesConsidered, 3)
        XCTAssertEqual(report.bytesConsidered, expectedBytes)
        XCTAssertTrue(report.groups.allSatisfy { group in
            group.files.allSatisfy { $0.modificationDate != nil }
        }, "Every reported duplicate must carry its measured modification date")
    }

    func testLiveStatsAreReportedDuringScan() throws {
        for index in 0..<12 {
            _ = makeFile("stats\(index).txt", contents: "shared live stats payload \(index)")
        }
        var latest = DuplicateScanStats()
        latest = DuplicateScanStats(filesConsidered: -1, bytesConsidered: -1)

        _ = try DuplicateFinder.scanReport(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false },
            onStats: { stats in latest = stats }
        )

        XCTAssertGreaterThanOrEqual(latest.filesConsidered, 12)
        XCTAssertGreaterThan(latest.bytesConsidered, 0)
    }

    // MARK: - Symlinks

    func testSymlinksAreNeverFollowedOrReported() throws {
        let real = makeFile("real.txt", contents: "symlink target content")
        let alias = sandbox.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        // A symlinked directory pointing at another folder with duplicates
        // must not be traversed.
        let source = sandbox.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try Data("mirrored content".utf8).write(to: source.appendingPathComponent("dup1.txt"))
        _ = try Data("mirrored content".utf8).write(to: source.appendingPathComponent("dup2.txt"))
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("linked-dir"),
            withDestinationURL: source
        )

        let report = try DuplicateFinder.scanReport(
            roots: [sandbox],
            maxDepth: 5,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )

        let allPaths = report.groups.flatMap { $0.files.map(\.path) }
        XCTAssertFalse(allPaths.contains { $0.hasSuffix("/alias.txt") },
                       "A symlink to a file must never be reported as a duplicate copy")
        XCTAssertFalse(allPaths.contains { $0.contains("/linked-dir/") },
                       "A symlinked directory must never be traversed")
        // The two real copies inside `source` are the only inode set.
        let mirrorSize = Int64(Data("mirrored content".utf8).count)
        let mirrorGroup = report.groups.first { $0.size == mirrorSize && $0.files.count == 2 }
        XCTAssertTrue(mirrorGroup?.files.allSatisfy({ $0.path.contains("/source/") }) == true)
    }

    // MARK: - Default roots and keeper behavior

    func testDefaultDuplicateRootsAreTheVisibleUserFolders() {
        XCTAssertEqual(
            ScanPolicy.defaultDuplicateRoots(home: PathSafety.userHome),
            [
                PathSafety.userHome.path + "/Desktop",
                PathSafety.userHome.path + "/Documents",
                PathSafety.userHome.path + "/Downloads",
                PathSafety.userHome.path + "/Pictures",
                PathSafety.userHome.path + "/Movies",
                PathSafety.userHome.path + "/Music"
            ]
        )
    }

    @MainActor
    func testDuplicateResultsNeverAutoSelectACopy() {
        let viewModel = DuplicatesViewModel()
        XCTAssertTrue(viewModel.selection.isEmpty,
                      "Scan results must start with no copy selected; the keeper is never auto-selected")
        XCTAssertTrue(viewModel.groups.isEmpty)
        XCTAssertFalse(viewModel.isScanning, "No scan may start automatically")
    }

    // MARK: - Sorting, Select All and Deselect All

    @MainActor
    func testDuplicateSortingSelectAllAndDeselectAll() throws {
        let small = ScannedItem(path: "/a/small.bin", size: 10, modificationDate: Date(timeIntervalSince1970: 100))
        let smallCopy = ScannedItem(path: "/b/small.bin", size: 10, modificationDate: Date(timeIntervalSince1970: 200))
        let big = ScannedItem(path: "/a/big.bin", size: 1_000, modificationDate: Date(timeIntervalSince1970: 300))
        let bigCopy = ScannedItem(path: "/b/big.bin", size: 1_000, modificationDate: Date(timeIntervalSince1970: 400))
        let bigThird = ScannedItem(path: "/c/big.bin", size: 1_000, modificationDate: Date(timeIntervalSince1970: 500))

        let smallGroup = DuplicateGroup(files: [small, smallCopy], size: 10, hash: "small")
        let bigGroup = DuplicateGroup(files: [big, bigCopy, bigThird], size: 1_000, hash: "big")

        let viewModel = DuplicatesViewModel()
        viewModel.groups = [smallGroup, bigGroup]
        viewModel.sortOption = .reclaimable
        XCTAssertEqual(viewModel.visibleGroups.first?.hash, "big",
                       "The group with the most reclaimable space must come first")

        viewModel.selectAllRemovable()
        XCTAssertEqual(viewModel.selection.count, 3, "Keeper copies must never be selected by Select All")
        if let smallKeeper = smallGroup.keeper {
            XCTAssertFalse(viewModel.selection.contains(smallKeeper.id))
        }
        if let bigKeeper = bigGroup.keeper {
            XCTAssertFalse(viewModel.selection.contains(bigKeeper.id))
        }
        // Selected removable copies are distinct paths (no inode identity in
        // this fixture), so all three count: 1000 + 1000 + 10.
        XCTAssertEqual(viewModel.selectedBytes, 2_010)

        viewModel.deselectAll()
        XCTAssertTrue(viewModel.selection.isEmpty)
    }

    // MARK: - Hard links

    func testHardLinksAreNotReportedAsReclaimableDuplicates() throws {
        let original = makeFile("original.txt", contents: "hard link shared content")
        let hardLink = sandbox.appendingPathComponent("hardlink.txt")
        try FileManager.default.linkItem(at: original, to: hardLink)

        let groups = try DuplicateFinder.scan(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { _, _ in },
            isCancelled: { false }
        )

        // Hard links share (device, inode): they must not form a group that
        // promises reclaimable space.
        let hardLinkGroups = groups.filter { group in
            group.files.count > 1 && group.reclaimableBytes > 0
        }
        XCTAssertTrue(hardLinkGroups.isEmpty,
                      "Hard links to the same inode must not be offered as reclaimable duplicates")
    }

    func testDuplicateScanRequiresRoots() {
        XCTAssertThrowsError(try DuplicateFinder.scan(
            roots: [],
            maxDepth: 3,
            progress: { _, _ in },
            isCancelled: { false }
        )) { error in
            XCTAssertEqual(error as? DuplicateScanError, .noRootsSelected)
        }
    }

    // MARK: - Cancellation

    func testDuplicateScanCancellation() throws {
        for index in 0..<20 {
            _ = makeFile("dup\(index).txt", contents: "cancellation shared content number \(index)")
        }
        var cancelled = false
        XCTAssertThrowsError(try DuplicateFinder.scan(
            roots: [sandbox],
            maxDepth: 3,
            minimumSize: 1,
            progress: { fraction, _ in
                if fraction > 0.3 { cancelled = true }
            },
            isCancelled: { cancelled }
        )) { error in
            XCTAssertEqual(error as? DuplicateScanError, .cancelled)
        }
    }
}
