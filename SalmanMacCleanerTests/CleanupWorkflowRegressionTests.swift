//
//  CleanupWorkflowRegressionTests.swift
//  SalmanMacCleanerTests
//
//  Regression coverage for the cleanup workflow the user drives from the
//  results workspace and the uninstaller:
//
//    selection → plan → validator → executor → FileManager.trashItem
//
//  Every test is fixture-based inside a temporary folder in the user's home.
//  The invariants under test:
//
//    1. Preview Mode never moves anything and never reaches the Trash API.
//    2. A real run revalidates every item and moves it to the Trash — the
//       item still exists afterwards (in the Trash), it is never deleted.
//    3. Counts and bytes reconcile exactly:
//       selected == moved + previewed + failed + skipped + notProcessed.
//    4. Protected paths, symlinks, ownership changes, identity changes and
//       running apps are refused with an exact reason.
//    5. The uninstaller may move an explicitly granted bundle and explicitly
//       selected safe caches, while preferences and system apps are refused.
//

import XCTest
@testable import SalmanMacCleaner

/// Records every move request without touching the filesystem. Proves which
/// paths the executor hands to the Trash API — and that preview hands it none.
private final class MockTrashMover: TrashMover {

    struct MockRefusal: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var calls: [String] = []
    var refusal: Error?

    func moveToTrash(_ path: String) throws -> String {
        calls.append(path)
        if let refusal { throw refusal }
        return NSTemporaryDirectory() + "Trash/" + (path as NSString).lastPathComponent
    }
}

@MainActor
final class CleanupWorkflowRegressionTests: XCTestCase {

    private var sandbox: URL!

    override func setUp() {
        super.setUp()
        sandbox = PathSafety.userHome.appendingPathComponent(
            ".CleanupRegression-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A cache-like file. Backdated so the classifier treats it as an
    /// unused, regenerable cache (fresh files are "in use" and protected).
    private func makeFile(_ relative: String,
                          contents: String = "regenerable cache payload",
                          ageDays: TimeInterval = 30) -> URL {
        let url = sandbox.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeBundle(_ name: String) -> URL {
        let bundle = sandbox.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: contents.appendingPathComponent("Info.plist").path,
            contents: Data("<plist/>".utf8)
        )
        return bundle
    }

    private func records(for urls: [URL]) -> [FileRecord] {
        urls.compactMap { MetadataCollector.collect(url: $0) }
    }

    private func selection(for records: [FileRecord]) -> [ScannedItem] {
        records.map { ScannedItem(path: $0.path, size: $0.allocatedSize, isDirectory: $0.isDirectory) }
    }

    private func totalAllocated(_ records: [FileRecord]) -> Int64 {
        records.reduce(Int64(0)) { $0 + $1.allocatedSize }
    }

    // MARK: - 1. Preview Mode never moves

    func testPreviewOnMovesNothingAndNeverReachesTheTrashAPI() async throws {
        let files = [makeFile("caches/one.cache"), makeFile("caches/two.cache"), makeFile("caches/three.cache")]
        let found = records(for: files)
        XCTAssertEqual(found.count, 3, "fixture must be readable")

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )
        XCTAssertEqual(draft.plan.items.count, 3)

        let mover = MockTrashMover()
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertTrue(mover.calls.isEmpty, "Preview Mode must never call the Trash API")
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.previewed.count, 3)
        XCTAssertEqual(result.movedBytes, 0)
        XCTAssertEqual(result.previewedBytes, totalAllocated(found))
        XCTAssertTrue(result.reconciles)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "Preview Mode must leave every file in place")
        }
    }

    func testPreviewOnWithTheRealMoverStillMovesNothing() async throws {
        let files = [makeFile("caches/real-one.cache"), makeFile("caches/real-two.cache")]
        let found = records(for: files)
        let plan = CleanupPlanBuilder.build(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )

        // The production executor with the production mover: preview must be
        // inert even when the real FileManager.trashItem is available.
        let result = await CleanupExecutor().execute(
            plan: plan,
            libraryRoots: [sandbox.path],
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.previewed.count, 2)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(result.trashDestinations.isEmpty)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    // MARK: - 2. A real run moves to the Trash

    func testRunOffMovesEverySelectedItemWithTheMockMover() async throws {
        let files = [makeFile("caches/a.cache"), makeFile("caches/b.cache"), makeFile("caches/c.cache")]
        let found = records(for: files)
        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )

        let mover = MockTrashMover()
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(mover.calls.sorted(), files.map { $0.path }.sorted(),
                       "Exactly the selected items may be handed to the Trash API")
        XCTAssertEqual(result.moved.count, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.movedBytes, totalAllocated(found), "Moved bytes must be exact")
        XCTAssertEqual(result.trashDestinations.count, 3)
        XCTAssertTrue(result.reconciles)
        XCTAssertFalse(result.previewOnly)
    }

    func testRunOffMovesSelectedFilesToTheRealTrashAndNothingIsDeleted() async throws {
        let files = [makeFile("caches/trash-me-one.cache"), makeFile("caches/trash-me-two.cache")]
        let unselected = makeFile("caches/keep-me.cache")
        let found = records(for: files)
        let plan = CleanupPlanBuilder.build(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )
        XCTAssertEqual(plan.items.count, 2)

        let result = await CleanupExecutor().execute(
            plan: plan,
            libraryRoots: [sandbox.path],
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.failedCount, 0, "fixture items must move: \(result.failures)")
        XCTAssertEqual(result.moved.count, 2)
        XCTAssertEqual(result.movedBytes, totalAllocated(found))
        XCTAssertEqual(result.trashDestinations.count, 2)

        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "The selected item must be gone from its original location")
        }
        // Trash-only: the item still exists — inside the Trash, restorable.
        for destination in result.trashDestinations.values {
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination),
                          "trashItem must leave a restorable item at \(destination)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselected.path),
                      "Unselected items must never be touched")
    }

    func testMoverRefusalIsReportedWithAReasonAndNeverCountedAsMoved() async throws {
        let files = [makeFile("caches/refused-one.cache"), makeFile("caches/refused-two.cache")]
        let found = records(for: files)
        let plan = CleanupPlanBuilder.build(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )

        let mover = MockTrashMover()
        mover.refusal = MockTrashMover.MockRefusal(message: "The volume does not support the Trash")
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: plan,
            libraryRoots: [sandbox.path],
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.moved.count, 0)
        XCTAssertEqual(result.movedBytes, 0)
        XCTAssertEqual(result.failedCount, 2)
        XCTAssertEqual(Set(result.failures.map { $0.path }), Set(files.map { $0.path }))
        for failure in result.failures {
            XCTAssertTrue(failure.reason.contains("does not support the Trash"),
                          "the exact refusal reason must be reported, got: \(failure.reason)")
        }
        XCTAssertTrue(result.reconciles)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    // MARK: - 3. Exact counts, bytes and reconciliation

    func testCountsAndBytesReconcileAcrossPlannedSkippedAndFailed() async throws {
        let safeOne = makeFile("caches/count-one.cache")
        let safeTwo = makeFile("caches/count-two.cache")
        let keychain = makeFile("caches/login.keychain-db", contents: "credentials")
        let inUse = makeFile("caches/fresh.cache", ageDays: 0)
        let ghost = sandbox.appendingPathComponent("caches/does-not-exist.cache")

        let readable = records(for: [safeOne, safeTwo, keychain, inUse])
        XCTAssertEqual(readable.count, 4)
        var chosen = selection(for: readable)
        chosen.append(ScannedItem(path: ghost.path, size: 4096))

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: chosen,
            records: readable,
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )

        XCTAssertEqual(draft.selectedCount, 5, "every selection is accounted for")
        XCTAssertEqual(draft.plan.items.count, 2, "only the two safe caches may be planned")
        XCTAssertEqual(draft.rejections.count, 3)
        XCTAssertTrue(draft.reconciles)
        XCTAssertEqual(
            Set(draft.rejections.map { $0.path }),
            Set([keychain.path, inUse.path, ghost.path])
        )
        // The ghost's bytes come from the selection, the others from metadata.
        XCTAssertEqual(
            draft.selectedBytes,
            totalAllocated(readable) + 4096
        )

        let result = await CleanupExecutor().execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.selectedCount, 5)
        XCTAssertEqual(result.previewed.count, 2)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedBytes, totalAllocated([keychain, inUse].compactMap { MetadataCollector.collect(url: $0) }) + 4096)
        XCTAssertTrue(result.reconciles, "selected == moved + previewed + failed + skipped + notProcessed")
        XCTAssertTrue(result.summary.contains("Previewed 2 item(s)"), "summary: \(result.summary)")
        XCTAssertFalse(result.reasons().isEmpty, "skip reasons must be reported")
    }

    // MARK: - 4. Safety guards with exact reasons

    func testProtectedItemsAreRefusedAndNeverReachTheMover() async throws {
        // The scan's junk root is the fixture's Library/Caches; everything
        // else (personal documents, credentials, databases) stays protected.
        let cachesRoot = sandbox.appendingPathComponent("Library/Caches").path
        let keychain = makeFile("Library/Caches/com.fixture.app/login.keychain-db", contents: "credentials")
        let database = makeFile("Library/Caches/com.fixture.app/History", contents: "browser history")
        let personal = makeFile("Documents/letter.txt", contents: "personal letter")
        let found = records(for: [keychain, database, personal])
        XCTAssertEqual(found.count, 3)

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [cachesRoot]
        )
        XCTAssertTrue(draft.plan.items.isEmpty, "protected selections must never be planned")
        XCTAssertEqual(draft.rejections.count, 3)

        let mover = MockTrashMover()
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: draft.plan,
            libraryRoots: [cachesRoot],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )
        XCTAssertTrue(mover.calls.isEmpty)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertEqual(result.moved.count, 0)
        for file in [keychain, database, personal] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testSymlinksAreNeverMoved() async throws {
        let target = makeFile("caches/link-target.cache")
        let link = sandbox.appendingPathComponent("caches/alias.cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard let linkRecord = MetadataCollector.collect(url: link) else {
            return XCTFail("symlink fixture must be readable")
        }

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: [ScannedItem(path: link.path, size: linkRecord.allocatedSize)],
            records: [linkRecord],
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )
        XCTAssertTrue(draft.plan.items.isEmpty, "a symlink must never enter a plan")
        XCTAssertEqual(draft.rejections.count, 1)
        XCTAssertTrue(draft.rejections.first?.reason.contains(link.path) == true)

        // Defense in depth: even a hand-built item is refused by the validator.
        let item = PlannedCleanupItem(
            path: link.path,
            expectedSize: linkRecord.allocatedSize,
            expectedModified: linkRecord.modified,
            expectedOwner: linkRecord.ownerUID,
            expectedDevice: linkRecord.device,
            expectedInode: linkRecord.inode,
            category: .userCache,
            safety: .safe,
            containmentRoot: sandbox.path,
            action: .moveToTrash
        )
        let validation = CleanupSafetyValidator.validate(
            item: item,
            allowBundles: false,
            libraryRoots: [sandbox.path]
        )
        guard case .failure(let failure) = validation else {
            return XCTFail("a symlink must fail validation")
        }
        XCTAssertTrue(failure.errorDescription?.contains(link.path) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testOwnershipAndIdentityChangesAreRefused() throws {
        let file = makeFile("caches/guarded.cache")
        guard let record = MetadataCollector.collect(url: file) else {
            return XCTFail("fixture must be readable")
        }

        // Ownership: the plan recorded a different owner than the file has now.
        let wrongOwner = PlannedCleanupItem(
            path: file.path,
            expectedSize: record.allocatedSize,
            expectedModified: record.modified,
            expectedOwner: record.ownerUID + 1,
            expectedDevice: record.device,
            expectedInode: record.inode,
            category: .userCache,
            safety: .safe,
            containmentRoot: sandbox.path,
            action: .moveToTrash
        )
        guard case .failure(let ownershipFailure) = CleanupSafetyValidator.validate(
            item: wrongOwner,
            allowBundles: false,
            libraryRoots: [sandbox.path]
        ) else {
            return XCTFail("an ownership mismatch must be refused")
        }
        XCTAssertEqual(ownershipFailure, .ownershipChanged(file.path))

        // Identity: the file was replaced after the scan (inode changed).
        let identityItem = PlannedCleanupItem(
            path: file.path,
            expectedSize: record.allocatedSize,
            expectedModified: record.modified,
            expectedOwner: record.ownerUID,
            expectedDevice: record.device,
            expectedInode: record.inode,
            category: .userCache,
            safety: .safe,
            containmentRoot: sandbox.path,
            action: .moveToTrash
        )
        try FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: Data("swapped".utf8))
        guard case .failure(let identityFailure) = CleanupSafetyValidator.validate(
            item: identityItem,
            allowBundles: false,
            libraryRoots: [sandbox.path]
        ) else {
            return XCTFail("a replaced file must be refused")
        }
        XCTAssertEqual(identityFailure, .identityChanged(file.path))
    }

    func testItemsOutsideTheContainmentRootAreRefusedWithAReason() async throws {
        let file = makeFile("caches/outside.cache")
        guard let record = MetadataCollector.collect(url: file) else {
            return XCTFail("fixture must be readable")
        }
        // A containment root that does not hold the item.
        let unrelatedRoot = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)

        let item = PlannedCleanupItem(
            path: file.path,
            expectedSize: record.allocatedSize,
            expectedModified: record.modified,
            expectedOwner: record.ownerUID,
            expectedDevice: record.device,
            expectedInode: record.inode,
            category: .userCache,
            safety: .safe,
            containmentRoot: unrelatedRoot.path,
            action: .moveToTrash
        )
        let mover = MockTrashMover()
        let plan = CleanupPlan(items: [item], previewOnly: false)
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: plan,
            libraryRoots: [sandbox.path],
            progress: { _, _ in },
            isCancelled: { false }
        )
        XCTAssertTrue(mover.calls.isEmpty)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertTrue(result.reconciles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - 5. Cancellation

    func testCancellationReportsExactlyWhatRanAndWhatDidNot() async throws {
        let files = (0..<4).map { makeFile("caches/cancel-\($0).cache") }
        let found = records(for: files)
        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selection(for: found),
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )
        XCTAssertEqual(draft.plan.items.count, 4)

        var checks = 0
        let result = await CleanupExecutor().execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: {
                checks += 1
                return checks > 1
            }
        )

        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.moved.count, 1, "exactly one item may move before cancellation")
        XCTAssertEqual(result.notProcessed, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(result.reconciles)
        XCTAssertTrue(result.summary.contains("cancelled"), "summary: \(result.summary)")

        let moved = Set(result.moved)
        let remaining = files.filter { !moved.contains($0.path) }
        XCTAssertEqual(remaining.count, 3)
        for file in remaining {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }

    // MARK: - 6. Uninstaller: explicit bundle grant

    func testBundleIsRefusedWithoutTheExplicitGrant() throws {
        let bundle = makeBundle("Fixture.app")

        // Without allowBundles the bundle is not even planned.
        guard let record = MetadataCollector.collect(url: bundle) else {
            return XCTFail("bundle fixture must be readable")
        }
        let denied = CleanupPlanBuilder.buildDetailed(
            selection: [ScannedItem(path: bundle.path, size: record.allocatedSize, isDirectory: true)],
            records: [record],
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )
        XCTAssertTrue(denied.plan.items.isEmpty)
        XCTAssertEqual(denied.rejections.count, 1)

        // With allowBundles but no authorized root the validator still refuses.
        let granted = CleanupPlanBuilder.buildDetailed(
            selection: [ScannedItem(path: bundle.path, size: record.allocatedSize, isDirectory: true)],
            records: [record],
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path],
            allowBundles: true
        )
        XCTAssertEqual(granted.plan.items.count, 1)

        let validation = CleanupSafetyValidator.validate(
            item: granted.plan.items[0],
            allowBundles: true,
            libraryRoots: [sandbox.path],
            authorizedRoots: []
        )
        guard case .failure(let failure) = validation else {
            return XCTFail("a bundle without an authorized root must be refused")
        }
        XCTAssertEqual(failure, .protectedName(bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testUninstallerMovesTheGrantedBundleAndSelectedCachesOnly() async throws {
        let bundle = makeBundle("Removable.app")
        let cache = makeFile("Library/Caches/com.fixture.removable/payload.cache")
        let preferences = makeFile("Library/Preferences/com.fixture.removable.plist")

        let cachesRoot = sandbox.appendingPathComponent("Library/Caches").path
        let bundlePath = URL(fileURLWithPath: bundle.path).standardizedFileURL.path

        let chosen = [
            ScannedItem(path: bundle.path, size: 0, isDirectory: true),
            ScannedItem(path: cache.path, size: 0),
            ScannedItem(path: preferences.path, size: 0)
        ]
        let found = records(for: [bundle, cache, preferences])
        let draft = CleanupPlanBuilder.buildDetailed(
            selection: chosen,
            records: found,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [cachesRoot],
            allowBundles: true,
            authorizedRoots: [bundlePath]
        )

        // The bundle and its cache are planned; preferences are preserved.
        XCTAssertEqual(Set(draft.plan.items.map { $0.path }), Set([bundlePath, cache.path]))
        XCTAssertEqual(draft.rejections.count, 1)
        XCTAssertEqual(draft.rejections.first?.path, preferences.path)
        XCTAssertTrue(draft.reconciles)
        // The grant is the bundle itself — never a wider root.
        XCTAssertEqual(draft.plan.items.first { $0.path == bundlePath }?.containmentRoot, bundlePath)

        let result = await CleanupExecutor().execute(
            plan: draft.plan,
            allowBundles: true,
            libraryRoots: [cachesRoot],
            authorizedRoots: [bundlePath],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.failedCount, 0, "granted bundle + cache must move: \(result.failures)")
        XCTAssertEqual(Set(result.moved), Set([bundlePath, cache.path]))
        XCTAssertEqual(result.moved.count, 2)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(result.reconciles)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.path),
                      "Preferences must be preserved")
        for path in [bundlePath, cache.path] {
            let destination = result.trashDestinations[path]
            XCTAssertNotNil(destination)
            if let destination {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination),
                              "the uninstalled item must be restorable from the Trash")
            }
        }
    }

    func testSystemAppsAreNeverEligible() {
        XCTAssertTrue(CleanupSafetyValidator.isSystemBundle("/System/Applications/Calculator.app"))
        XCTAssertTrue(CleanupSafetyValidator.isSystemBundle("/System/Library/CoreServices/Finder.app"))
        XCTAssertFalse(CleanupSafetyValidator.isSystemBundle("/Applications/ThirdParty.app"))
        XCTAssertFalse(CleanupSafetyValidator.isSystemBundle(PathSafety.userHome.path + "/Applications/Mine.app"))
    }

    func testPrivilegedRemoveActionIsNeverAvailable() {
        XCTAssertFalse(CleanupAction.privilegedRemove.isAvailable)
        XCTAssertTrue(CleanupAction.moveToTrash.isAvailable)
    }

    // MARK: - 7. Results workspace bookkeeping

    private func makeModel() throws -> ResultsWorkspaceModel {
        let store = try ScanIndexStore(path: sandbox.appendingPathComponent("index.sqlite").path)
        return ResultsWorkspaceModel(coordinator: DeepScanCoordinator(indexStore: store))
    }

    private func classified(_ record: FileRecord) -> ClassifiedRecord {
        ClassifiedRecord(
            path: record.path,
            name: record.name,
            logicalSize: record.logicalSize,
            allocatedSize: record.allocatedSize,
            modified: record.modified,
            category: "userCache",
            safety: "safe",
            reason: "fixture"
        )
    }

    func testMovedItemsLeaveTheResultsAndTotalsFollow() throws {
        let first = makeFile("caches/ws-one.cache")
        let second = makeFile("caches/ws-two.cache")
        let found = records(for: [first, second])
        XCTAssertEqual(found.count, 2)

        let model = try makeModel()
        model.outcome = ScanOutcome(
            scanID: 7,
            mode: .quick,
            startedAt: Date(),
            finishedAt: Date(),
            coverage: CoverageReport(scannedRoots: [sandbox.path]),
            provenance: .full,
            itemsScanned: 2,
            bytesIndexed: totalAllocated(found),
            safeBytes: totalAllocated(found)
        )
        model.items = found.map { classified($0) }
        model.selection = Set(found.map { $0.path })

        let movedBytes = found[0].allocatedSize
        let result = ExecutedCleanupResult(
            moved: [found[0].path],
            bytesReclaimed: movedBytes,
            movedBytes: movedBytes,
            previewOnly: false,
            trashDestinations: [found[0].path: NSTemporaryDirectory() + "Trash/ws-one.cache"],
            selectedCount: 2
        )
        model.applyExecuted(result)

        XCTAssertEqual(model.items.map { $0.path }, [found[1].path],
                       "a moved item must disappear from the results")
        XCTAssertEqual(model.selection, Set([found[1].path]))
        XCTAssertEqual(model.outcome?.itemsScanned, 1)
        XCTAssertEqual(model.outcome?.bytesIndexed, totalAllocated(found) - movedBytes)
        XCTAssertEqual(model.outcome?.safeBytes, totalAllocated(found) - movedBytes)
        XCTAssertEqual(model.report?.moved, [found[0].path])
    }

    func testPreviewRunLeavesResultsAndTotalsUntouched() throws {
        let file = makeFile("caches/ws-preview.cache")
        let found = records(for: [file])
        let model = try makeModel()
        model.outcome = ScanOutcome(
            scanID: 8,
            mode: .quick,
            startedAt: Date(),
            finishedAt: Date(),
            coverage: CoverageReport(scannedRoots: [sandbox.path]),
            provenance: .full,
            itemsScanned: 1,
            bytesIndexed: totalAllocated(found),
            safeBytes: totalAllocated(found)
        )
        model.items = found.map { classified($0) }
        model.selection = Set(found.map { $0.path })

        let result = ExecutedCleanupResult(
            previewed: [file.path],
            bytesReclaimed: totalAllocated(found),
            previewedBytes: totalAllocated(found),
            previewOnly: true,
            selectedCount: 1
        )
        model.applyExecuted(result)

        XCTAssertEqual(model.items.count, 1, "a preview must not remove anything")
        XCTAssertEqual(model.selection, Set([file.path]))
        XCTAssertEqual(model.outcome?.itemsScanned, 1)
        XCTAssertEqual(model.outcome?.safeBytes, totalAllocated(found))
    }

    func testWorkspaceDraftReportsSelectionsThatAreNoLongerListed() throws {
        let file = makeFile("caches/ws-listed.cache")
        let found = records(for: [file])
        let model = try makeModel()
        model.outcome = ScanOutcome(
            scanID: 9,
            mode: .quick,
            startedAt: Date(),
            finishedAt: Date(),
            coverage: CoverageReport(scannedRoots: [sandbox.path]),
            provenance: .full,
            itemsScanned: 1,
            bytesIndexed: totalAllocated(found),
            safeBytes: totalAllocated(found)
        )
        model.items = found.map { classified($0) }
        model.selection = Set([file.path, sandbox.appendingPathComponent("gone.cache").path])

        let draft = model.buildDraft(previewOnly: true, libraryRoots: [sandbox.path])
        XCTAssertEqual(draft.selectedCount, 2)
        XCTAssertEqual(draft.plan.items.count, 1)
        XCTAssertEqual(draft.rejections.count, 1)
        XCTAssertTrue(draft.reconciles,
                      "the bar's 2 selections must reconcile with 1 planned + 1 skipped")
    }

    // MARK: - 8. Double-counting, Canonicalization & Feature Invariants

    func testParentChildDoubleCountingPruningAndAccounting() async throws {
        let parentDir = sandbox.appendingPathComponent("caches/ParentFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let child1 = makeFile("caches/ParentFolder/child1.cache", contents: "payload 1")
        let child2 = makeFile("caches/ParentFolder/child2.cache", contents: "payload 2")
        let child3 = makeFile("caches/ParentFolder/sub/child3.cache", contents: "payload 3")

        guard let parentRecord = MetadataCollector.collect(url: parentDir),
              let r1 = MetadataCollector.collect(url: child1),
              let r2 = MetadataCollector.collect(url: child2),
              let r3 = MetadataCollector.collect(url: child3) else {
            return XCTFail("fixtures must be readable")
        }

        let allRecords = [parentRecord, r1, r2, r3]
        let allSelected = allRecords.map { ScannedItem(path: $0.path, size: $0.allocatedSize, isDirectory: $0.isDirectory) }

        // When parent and descendants are both in selection, descendants must be pruned
        let draft = CleanupPlanBuilder.buildDetailed(
            selection: allSelected,
            records: allRecords,
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )

        XCTAssertEqual(draft.plan.items.count, 1, "Only the parent directory must be planned")
        XCTAssertEqual(draft.plan.items.first?.path, parentDir.standardizedFileURL.path)
        XCTAssertEqual(draft.selectedCount, 1, "Pruned selection count must be 1")
        XCTAssertTrue(draft.reconciles)

        let mover = MockTrashMover()
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(mover.calls.count, 1, "Only the parent directory moves to Trash")
        XCTAssertEqual(result.moved.count, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.reconciles)
    }

    func testCanonicalDuplicatePathsDeduplication() throws {
        let file = makeFile("caches/canonical-test.cache")
        guard let record = MetadataCollector.collect(url: file) else {
            return XCTFail("fixture must be readable")
        }

        let variations = [
            ScannedItem(path: file.path, size: record.allocatedSize),
            ScannedItem(path: file.path + "/.", size: record.allocatedSize),
            ScannedItem(path: file.deletingLastPathComponent().path + "/../caches/" + file.lastPathComponent, size: record.allocatedSize)
        ]

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: variations,
            records: [record],
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )

        XCTAssertEqual(draft.selectedCount, 1, "Duplicate canonical path representations must collapse into 1 item")
        XCTAssertEqual(draft.plan.items.count, 1)
        XCTAssertEqual(draft.rejections.count, 0)
        XCTAssertTrue(draft.reconciles)
    }

    func testHardLinksWithIdenticalInodesAreDeduplicated() throws {
        let original = makeFile("caches/original.cache", contents: "unique payload")
        let link = sandbox.appendingPathComponent("caches/hardlink.cache")
        try FileManager.default.linkItem(at: original, to: link)

        guard let r1 = MetadataCollector.collect(url: original),
              let r2 = MetadataCollector.collect(url: link) else {
            return XCTFail("fixtures must be readable")
        }

        XCTAssertEqual(r1.inode, r2.inode, "hard links must have identical inode")

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: [ScannedItem(path: r1.path, size: r1.allocatedSize), ScannedItem(path: r2.path, size: r2.allocatedSize)],
            records: [r1, r2],
            containmentRoot: sandbox.path,
            previewOnly: true,
            libraryRoots: [sandbox.path]
        )

        XCTAssertEqual(draft.selectedCount, 2)
        XCTAssertEqual(draft.plan.items.count, 1, "Only one inode representative is planned")
        XCTAssertEqual(draft.rejections.count, 1, "Duplicate inode is rejected")
        XCTAssertTrue(draft.reconciles)
    }

    func testSuccessfulAndFailedTrashMovesExactReconciliation() async throws {
        let f1 = makeFile("caches/success1.cache")
        let f2 = makeFile("caches/success2.cache")
        let f3 = makeFile("caches/refused.cache")

        guard let r1 = MetadataCollector.collect(url: f1),
              let r2 = MetadataCollector.collect(url: f2),
              let r3 = MetadataCollector.collect(url: f3) else {
            return XCTFail("fixtures must be readable")
        }

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: [ScannedItem(path: r1.path, size: r1.allocatedSize),
                        ScannedItem(path: r2.path, size: r2.allocatedSize),
                        ScannedItem(path: r3.path, size: r3.allocatedSize)],
            records: [r1, r2, r3],
            containmentRoot: sandbox.path,
            previewOnly: false,
            libraryRoots: [sandbox.path]
        )

        // Custom mover that fails on f3
        final class SelectiveMover: TrashMover {
            let failPath: String
            init(failPath: String) { self.failPath = failPath }
            func moveToTrash(_ path: String) throws -> String {
                if path == failPath {
                    throw NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSLocalizedDescriptionKey: "File is locked"])
                }
                return NSTemporaryDirectory() + "Trash/" + (path as NSString).lastPathComponent
            }
        }

        let mover = SelectiveMover(failPath: f3.path)
        let result = await CleanupExecutor(trashMover: mover).execute(
            plan: draft.plan,
            libraryRoots: [sandbox.path],
            skipped: draft.rejections,
            selectedCount: draft.selectedCount,
            progress: { _, _ in },
            isCancelled: { false }
        )

        XCTAssertEqual(result.selectedCount, 3)
        XCTAssertEqual(result.moved.count, 2)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.notProcessed, 0)
        XCTAssertTrue(result.reconciles, "selected == moved + failed + skipped + notProcessed")
        XCTAssertEqual(result.movedBytes, r1.allocatedSize + r2.allocatedSize)
    }

    func testCleanupEvictsMovedDirectoryAndAllDescendantsFromIndex() async throws {
        let store = try ScanIndexStore(path: sandbox.appendingPathComponent("test-index.sqlite").path)
        let scanID = try await store.beginScan(mode: .quick, scope: ScanScope(mode: .quick), provenance: .full)

        let parentDir = sandbox.appendingPathComponent("caches/ParentBundle", isDirectory: true)
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let child1 = makeFile("caches/ParentBundle/data1.cache")
        let child2 = makeFile("caches/ParentBundle/data2.cache")

        guard let pr = MetadataCollector.collect(url: parentDir),
              let cr1 = MetadataCollector.collect(url: child1),
              let cr2 = MetadataCollector.collect(url: child2) else {
            return XCTFail("fixtures must be readable")
        }

        try await store.insertClassifiedRecords(scanID: scanID, pairs: [
            (pr, JunkVerdict(category: .userCache, safety: .safe, reason: "parent cache", autoSelectable: true, regenerable: true, sourceRule: "test")),
            (cr1, JunkVerdict(category: .userCache, safety: .safe, reason: "child cache 1", autoSelectable: true, regenerable: true, sourceRule: "test")),
            (cr2, JunkVerdict(category: .userCache, safety: .safe, reason: "child cache 2", autoSelectable: true, regenerable: true, sourceRule: "test"))
        ])

        let initialTotals = await store.recalculateTotals(scanID: scanID)
        XCTAssertEqual(initialTotals.itemsScanned, 3)

        // Evict the parent folder
        await store.deleteRecordsAndDescendants(scanID: scanID, paths: [pr.path])
        let remainingTotals = await store.recalculateTotals(scanID: scanID)
        XCTAssertEqual(remainingTotals.itemsScanned, 0, "Evicting parent directory must also evict all descendant records")
        XCTAssertEqual(remainingTotals.safeBytes, 0)
    }

    func testRegeneratedOldCachesAreSafeWhileFreshFilesAreProtected() {
        let oldCache = makeFile("caches/old.cache", contents: "old payload", ageDays: 30)
        let freshCache = makeFile("caches/fresh.cache", contents: "fresh payload", ageDays: 0)

        guard let oldRecord = MetadataCollector.collect(url: oldCache),
              let freshRecord = MetadataCollector.collect(url: freshCache) else {
            return XCTFail("fixtures must be readable")
        }

        let libraryRoots = [sandbox.appendingPathComponent("caches").path]
        let oldVerdict = JunkClassifier.classify(oldRecord, libraryRoots: libraryRoots)
        let freshVerdict = JunkClassifier.classify(freshRecord, libraryRoots: libraryRoots)

        XCTAssertEqual(oldVerdict.safety, .safe)
        XCTAssertTrue(oldVerdict.autoSelectable)
        XCTAssertEqual(freshVerdict.safety, .protected, "Fresh files (< 1 day old) are protected against accidental deletion")
    }

    func testFDARefreshAndStateClassification() {
        let snapshot = PermissionService.probeSnapshot()
        XCTAssertNotEqual(snapshot.lastCheck, .distantPast)
        XCTAssertFalse(snapshot.coverageImpact.isEmpty)
        XCTAssertTrue(FullDiskAccessStatus.allCases.contains(snapshot.fullDiskAccess))
    }

    func testSpaceLensExplicitStatesNeverShowZeroKBForUnscanned() {
        let unscannedTarget = SpaceLensTargetRoot(name: "TestRoot", path: "/UnscannedPath", icon: "folder.fill")
        XCTAssertEqual(unscannedTarget.state, .notScanned)
        XCTAssertEqual(unscannedTarget.state.title, "Not scanned")
        XCTAssertFalse(unscannedTarget.state.title.contains("0 KB"), "Unscanned roots must never display 0 KB")

        let deniedState = SpaceLensRootState.denied(reason: "EPERM")
        XCTAssertEqual(deniedState.title, "Access denied")
        XCTAssertFalse(deniedState.title.contains("0 KB"))

        let measuredState = SpaceLensRootState.measured(bytes: 1024 * 1024 * 50, fileCount: 120)
        XCTAssertTrue(measuredState.title.contains("MB") || measuredState.title.contains("50"))
    }

    func testSpaceLensBubblePackingProportions() {
        let child1 = SpaceLensNode(name: "Large", path: "/large", allocatedBytes: 100_000_000, isDirectory: true)
        let child2 = SpaceLensNode(name: "Medium", path: "/medium", allocatedBytes: 40_000_000, isDirectory: true)
        let child3 = SpaceLensNode(name: "Small", path: "/small", allocatedBytes: 5_000_000, isDirectory: true)

        let root = SpaceLensNode(name: "Root", path: "/", allocatedBytes: 0, isDirectory: true, children: [child1, child2, child3])
        let layout = BubblePacker.layout(node: root, in: CGSize(width: 600, height: 600))

        let b1 = layout.first { $0.source.name == "Large" }
        let b2 = layout.first { $0.source.name == "Medium" }
        let b3 = layout.first { $0.source.name == "Small" }

        XCTAssertNotNil(b1)
        XCTAssertNotNil(b2)
        XCTAssertNotNil(b3)

        if let b1, let b2, let b3 {
            XCTAssertGreaterThan(b1.frame.width, b2.frame.width)
            XCTAssertGreaterThan(b2.frame.width, b3.frame.width)
        }
    }

    func testSystemProtectedPathsAreNeverPlannedForRemoval() {
        XCTAssertTrue(SpaceLensEngine.isSystemPath("/System"))
        XCTAssertTrue(SpaceLensEngine.isSystemPath("/usr/bin"))
        XCTAssertTrue(SpaceLensEngine.isSystemPath("/sbin/launchd"))
        XCTAssertFalse(SpaceLensEngine.isSystemPath(PathSafety.userHome.path))

        XCTAssertTrue(CleanupSafetyValidator.isSystemBundle("/System/Applications/Safari.app"))
        XCTAssertFalse(CleanupSafetyValidator.isSystemBundle("/Applications/Safari.app"))
    }
}
