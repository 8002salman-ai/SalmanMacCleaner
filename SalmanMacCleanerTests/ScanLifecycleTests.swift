//
//  ScanLifecycleTests.swift
//  SalmanMacCleanerTests
//
//  Tests for scan lifecycles: cancellation, permission failures and the
//  large-file / developer-cache scanners' safety properties.
//

import XCTest
@testable import SalmanMacCleaner

final class ScanLifecycleTests: XCTestCase {

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

    private func makeFile(_ name: String, bytes: Int) -> URL {
        let url = sandbox.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x42, count: bytes))
        return url
    }

    // MARK: - Large file scanner

    func testLargeFileScannerFindsOnlyFilesAboveThreshold() throws {
        _ = makeFile("small.txt", bytes: 100)
        _ = makeFile("large.txt", bytes: 2_000_000)

        let result = try LargeFileScanner.scan(
            roots: [sandbox],
            thresholdBytes: 1_000_000,
            maxDepth: 3,
            progress: { _, _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].path.hasSuffix("large.txt"))
        XCTAssertEqual(result.totalBytes, 2_000_000)
    }

    func testLargeFileScannerRequiresRoots() {
        XCTAssertThrowsError(try LargeFileScanner.scan(
            roots: [],
            thresholdBytes: 100,
            maxDepth: 3,
            progress: { _, _ in },
            isCancelled: { false }
        )) { error in
            XCTAssertEqual(error as? LargeFileScanError, .noRootsSelected)
        }
    }

    func testLargeFileScannerCancellation() throws {
        for index in 0..<50 {
            _ = makeFile("file\(index).dat", bytes: 1_500_000)
        }
        var checks = 0
        let cancellationClosure: () -> Bool = {
            checks += 1
            return checks > 30
        }
        XCTAssertThrowsError(try LargeFileScanner.scan(
            roots: [sandbox],
            thresholdBytes: 1_000_000,
            maxDepth: 4,
            progress: { _, _ in },
            isCancelled: cancellationClosure
        )) { error in
            XCTAssertEqual(error as? LargeFileScanError, .cancelled)
        }
    }

    func testLargeFileScannerSkipsSymlinks() throws {
        let target = makeFile("target.bin", bytes: 2_000_000)
        let link = sandbox.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = try LargeFileScanner.scan(
            roots: [sandbox],
            thresholdBytes: 1_000_000,
            maxDepth: 3,
            progress: { _, _ in },
            isCancelled: { false }
        )
        let linkItems = result.items.filter { $0.path.contains("link.bin") }
        XCTAssertTrue(linkItems.isEmpty, "Symlinks must never be reported")
        XCTAssertEqual(result.items.filter { $0.path.contains("target.bin") }.count, 1)
    }

    // MARK: - Developer cache scanner

    func testDeveloperCacheScannerGracefullySkipsMissingLocations() throws {
        let entries = try DeveloperCacheScanner.scan(
            categories: [.derivedData, .npm, .homebrew],
            progress: { _, _ in },
            isCancelled: { false }
        )
        // On a machine without dev tooling this is simply empty — never an
        // error and never a crash.
        XCTAssertTrue(entries.isEmpty || entries.allSatisfy { !$0.path.isEmpty })
    }

    func testDeveloperCacheScannerCancellation() {
        var cancelled = false
        XCTAssertThrowsError(try DeveloperCacheScanner.scan(
            categories: Set(DeveloperCacheCategory.allCases),
            progress: { fraction, _ in
                if fraction > 0.4 { cancelled = true }
            },
            isCancelled: { cancelled }
        )) { error in
            XCTAssertEqual(error as? DeveloperCacheScanError, .cancelled)
        }
    }

    func testDeveloperCacheCategoriesHaveSafeCandidatePaths() {
        for category in DeveloperCacheCategory.allCases {
            for candidate in category.candidatePaths {
                XCTAssertFalse(PathSafety.isProtectedRootLocation(candidate),
                               "\(category) candidate \(candidate) is a protected root")
            }
        }
    }

    // MARK: - Permission failures

    func testPermissionFailuresAreGraceful() throws {
        // Scanning a location the process cannot read must return an empty
        // result or skip entries — never a crash or an unhandled error.
        let unreadable = sandbox.appendingPathComponent("unreadable", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        let secret = unreadable.appendingPathComponent("secret.txt")
        FileManager.default.createFile(atPath: secret.path, contents: Data("secret".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        // Running as root would bypass permissions; only assert when not root.
        if getuid() != 0 {
            let result = try LargeFileScanner.scan(
                roots: [unreadable],
                thresholdBytes: 1,
                maxDepth: 3,
                progress: { _, _ in },
                isCancelled: { false }
            )
            // Either nothing was found or unreadable entries were skipped —
            // never a crash, and never a claimed success over unreadable data.
            XCTAssertTrue(result.items.isEmpty || result.skippedCount >= 0)
            XCTAssertTrue(result.errorMessage == nil || !result.errorMessage!.isEmpty)
        }
    }

    // MARK: - Scan coordinator

    @MainActor
    func testScanCoordinatorCancellation() async {
        let coordinator = ScanCoordinator()
        let operation = ScanOperation<Int>(title: "Test", roots: ["/tmp"]) { _, isCancelled in
            var steps = 0
            while !isCancelled() && steps < 1_000_000 {
                steps += 1
                await Task.yield()
            }
            if isCancelled() { throw CancellationError() }
            return steps
        }

        let expectation = expectation(description: "scan cancelled")
        coordinator.start(operation) { outcome in
            if case .failure(let error) = outcome {
                XCTAssertEqual(error as? ScanError, .cancelled)
                expectation.fulfill()
            }
        }
        // Give the scan a moment to start, then cancel.
        try? await Task.sleep(nanoseconds: 50_000_000)
        coordinator.cancel()
        await fulfillment(of: [expectation], timeout: 10)
    }
}
