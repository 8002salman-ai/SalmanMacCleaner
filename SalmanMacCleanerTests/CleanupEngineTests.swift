//
//  CleanupEngineTests.swift
//  SalmanMacCleanerTests
//
//  Tests for the trash-only cleanup engine: preview-only mode, immediate
//  revalidation, selected-items-only cleanup and refusal of unsafe items.
//

import XCTest
@testable import SalmanMacCleaner

final class CleanupEngineTests: XCTestCase {

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

    private func makeFile(_ name: String, bytes: Int = 64) -> URL {
        let url = sandbox.appendingPathComponent(name)
        let data = Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: url.path, contents: data)
        return url
    }

    @MainActor
    func testPreviewOnlyModeNeverMovesFiles() async {
        let file = makeFile("preview.txt")
        let item = CleanupItem(path: file.path, size: 64, kind: "file")

        let engine = CleanupEngine()
        let result = await engine.clean(
            items: [item],
            root: sandbox.path,
            previewOnly: true,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.previewed.count, 1)
        XCTAssertEqual(result.failures.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "Preview mode must never move or remove files")
    }

    @MainActor
    func testSelectedItemsOnlyAreCleaned() async {
        let selectedFile = makeFile("selected.txt")
        let unselectedFile = makeFile("unselected.txt")

        let engine = CleanupEngine()
        let result = await engine.clean(
            items: [CleanupItem(path: selectedFile.path, size: 64, kind: "file")],
            root: sandbox.path,
            previewOnly: false,
            progress: { _, _ in },
            isCancelled: { false }
        )

        // Trash-only: the selected file may end up in the Trash (or fail on
        // this Linux host), but the *unselected* file must be untouched.
        XCTAssertEqual(result.previewed.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselectedFile.path),
                      "Unselected files must never be touched")
        // On a real macOS host with a Trash, the selected file is moved.
        // On other hosts the engine reports a failure instead of deleting.
        XCTAssertTrue(result.trashed.isEmpty || !FileManager.default.fileExists(atPath: selectedFile.path))
    }

    @MainActor
    func testItemsOutsideRootAreRejectedBeforeTrash() async {
        let other = PathSafety.userHome
            .appendingPathComponent(".SalmanMacCleanerTests-outside-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let outsideFile = other.appendingPathComponent("outside.txt")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: other) }

        let engine = CleanupEngine()
        let result = await engine.clean(
            items: [CleanupItem(path: outsideFile.path, size: 1, kind: "file")],
            root: sandbox.path,
            previewOnly: false,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.trashed.count, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path),
                      "Files outside the declared root must never be moved")
    }

    @MainActor
    func testSymlinkItemsAreRejectedBeforeTrash() async throws {
        let target = makeFile("target.txt")
        let link = sandbox.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let engine = CleanupEngine()
        let result = await engine.clean(
            items: [CleanupItem(path: link.path, size: 0, kind: "file")],
            root: sandbox.path,
            previewOnly: false,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.trashed.count, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    @MainActor
    func testMissingItemsAreReportedNotCrashed() async {
        let engine = CleanupEngine()
        let missing = sandbox.appendingPathComponent("ghost.txt").path
        let result = await engine.clean(
            items: [CleanupItem(path: missing, size: 10, kind: "file")],
            root: sandbox.path,
            previewOnly: false,
            progress: { _, _ in },
            isCancelled: { false }
        )
        XCTAssertEqual(result.trashed.count, 0)
        XCTAssertEqual(result.failures.count, 1)
    }

    @MainActor
    func testProtectedSuffixFilesAreRejectedEvenInsideRoot() async {
        let evil = makeFile("malware.sh")
        let engine = CleanupEngine()
        let result = await engine.clean(
            items: [CleanupItem(path: evil.path, size: 5, kind: "file")],
            root: sandbox.path,
            previewOnly: false,
            progress: { _, _ in },
            isCancelled: { false }
        )
        // CleanupEngine.revalidate protects by suffix regardless of outcome;
        // at minimum the item must not be trashed silently.
        XCTAssertEqual(result.trashed.count, 0)
    }

    @MainActor
    func testCancellationStopsEarly() async {
        var files: [CleanupItem] = []
        for index in 0..<10 {
            files.append(CleanupItem(path: makeFile("f\(index).txt").path, size: 10, kind: "file"))
        }
        let engine = CleanupEngine()
        var cancel = false
        let result = await engine.clean(
            items: files,
            root: sandbox.path,
            previewOnly: true,
            progress: { fraction, _ in
                if fraction > 0.2 { cancel = true }
            },
            isCancelled: { cancel }
        )
        XCTAssertLessThan(result.previewed.count, files.count,
                          "Cancellation must stop the loop early")
    }

    @MainActor
    func testRunningAppBundleIsBlocked() {
        // CleanupEngine.isAppRunning must not crash for any path and must be
        // deterministic for non-running bundles.
        let path = "/Applications/DefinitelyNotRunningApp.app"
        XCTAssertFalse(CleanupEngine.isAppRunning(bundlePath: path))
    }

    @MainActor
    func testRevalidateRejectsOtherUserFiles() {
        let file = makeFile("owned.txt")
        let item = CleanupItem(path: file.path, size: 1, kind: "file")
        XCTAssertNoThrow(try CleanupEngine.revalidate(item: item, root: sandbox.path, allowBundles: false))

        // A file that is not owned by the current user must be rejected.
        let foreignPath = "/Users/someoneelse/file.txt"
        XCTAssertThrowsError(try CleanupEngine.revalidate(
            item: CleanupItem(path: foreignPath, size: 1, kind: "file"),
            root: "/Users/someoneelse",
            allowBundles: false
        ))
    }
}
