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
