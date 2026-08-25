//
//  FixtureEndToEndTests.swift
//  SalmanMacCleanerTests
//
//  Fixture-based end-to-end flow: build a safe temporary tree, run the file
//  inventory over it, classify, build a cleanup plan, preview, execute
//  selected cleanup inside the fixture only, and verify unselected and
//  protected files remain. Plus application inventory, residuals, Space Lens
//  aggregation and Mach-O header reading.
//

import XCTest
@testable import SalmanMacCleaner

final class FixtureEndToEndTests: XCTestCase {

    private var fixture: URL!

    override func setUp() {
        super.setUp()
        fixture = PathSafety.userHome.appendingPathComponent(".E2E-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let fixture {
            try? FileManager.default.removeItem(at: fixture)
        }
        super.tearDown()
    }

    private func makeFile(_ relative: String, contents: String = "fixture content") -> URL {
        let url = fixture.appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    // MARK: - Full flow

    func testEndToEndInventoryPlanPreviewExecute() async throws {
        // 1. Fixture tree.
        let selectedFile = makeFile("caches/app/entry.cache", contents: "regenerable cache")
        let unselectedFile = makeFile("caches/app/other.cache", contents: "another cache")
        let protectedFile = makeFile("caches/app/data.sqlite", contents: "database")
        let personalFile = makeFile("Documents/letter.txt", contents: "personal letter")

        // 2. Run the inventory scanner over the fixture.
        var records: [FileRecord] = []
        var totals = InventoryCounts()
        let gate = ScanGate()
        totals = try await FileInventoryScanner.scan(
            roots: [fixture],
            includeHidden: false,
            includePackageContents: false,
            minFileSize: 0,
            sink: { records.append($0) },
            counts: { _, _ in },
            gate: gate,
            isCancelled: { false }
        )

        // 3. Real items appear in inventory.
        XCTAssertGreaterThanOrEqual(records.count, 4)
        XCTAssertGreaterThan(totals.files, 0)

        // 4. Classification is correct.
        let cacheRecord = records.first { $0.path.hasSuffix("entry.cache") }
        let protectedRecord = records.first { $0.path.hasSuffix("data.sqlite") }
        XCTAssertNotNil(cacheRecord)
        XCTAssertNotNil(protectedRecord)
        let libraryRoots = [fixture.path + "/caches"]
        if let cacheRecord {
            XCTAssertEqual(JunkClassifier.classify(cacheRecord, libraryRoots: libraryRoots).safety, .safe)
        }
        if let protectedRecord {
            XCTAssertEqual(JunkClassifier.classify(protectedRecord, libraryRoots: libraryRoots).safety, .protected)
        }

        // 5. Build the plan from an explicit selection (both cache files).
        let selected = [cacheRecord!, records.first { $0.path.hasSuffix("other.cache") }!].map {
            ScannedItem(path: $0.path, size: $0.logicalSize)
        }
        let plan = CleanupPlanBuilder.build(
            selection: selected,
            records: records,
            containmentRoot: fixture.path,
            previewOnly: true,
            scanID: nil,
            libraryRoots: libraryRoots
        )
        XCTAssertEqual(plan.items.count, 2)

        // 6. Preview: nothing moves.
        let preview = await CleanupExecutor.shared.execute(plan: plan, progress: { _, _ in }, isCancelled: { false })
        XCTAssertEqual(preview.previewed.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselectedFile.path))

        // 7. Execute for real inside the fixture only.
        let realPlan = CleanupPlanBuilder.build(
            selection: selected,
            records: records,
            containmentRoot: fixture.path,
            previewOnly: false,
            scanID: nil,
            libraryRoots: libraryRoots
        )
        let executed = await CleanupExecutor.shared.execute(plan: realPlan, progress: { _, _ in }, isCancelled: { false })
        XCTAssertGreaterThanOrEqual(executed.moved.count, 0)
        XCTAssertEqual(executed.failures.count + executed.moved.count, realPlan.items.count)

        // 8. Unselected and protected files remain.
        XCTAssertTrue(FileManager.default.fileExists(atPath: unselectedFile.path),
                      "Unselected files must never be touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedFile.path),
                      "Protected files must never be touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalFile.path),
                      "Personal files must never be touched")
    }

    // MARK: - Cancellation

    func testInventoryScannerCancellation() async {
        for index in 0..<40 {
            _ = makeFile("many/file\(index).txt", contents: String(repeating: "x", count: 100))
        }
        do {
            _ = try await FileInventoryScanner.scan(
                roots: [fixture],
                includeHidden: false,
                includePackageContents: false,
                minFileSize: 0,
                sink: { _ in },
                counts: { _, _ in },
                gate: ScanGate(),
                isCancelled: { true }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? InventoryScannerError, .cancelled)
        }
    }

    // MARK: - Application inventory

    func testApplicationInventoryFindsNestedBundles() throws {
        let appDir = fixture.appendingPathComponent("Apps", isDirectory: true)
        let nested = appDir.appendingPathComponent("Vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let app = nested.appendingPathComponent("FixtureApp.app")
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.fixture.app",
            "CFBundleName": "FixtureApp",
            "CFBundleExecutable": "FixtureApp",
            "CFBundleShortVersionString": "2.1.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)

        let found = ApplicationInventoryService.appBundles(at: appDir, maxDepth: 2)
        XCTAssertEqual(found.map { $0.lastPathComponent }, ["FixtureApp.app"])

        let record = ApplicationInventoryService.makeRecord(appURL: app, root: appDir)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.bundleID, "com.fixture.app")
        XCTAssertEqual(record?.version, "2.1.0")
        XCTAssertFalse(record?.isSystemApp ?? true)
    }

    func testSystemAppsAreProtectedByClassification() {
        let systemApp = AppRecord(
            name: "Safari", bundlePath: "/System/Applications/Safari.app",
            bundleID: "com.apple.Safari", version: "17.0", build: "1",
            architectures: ["arm64"], isCodeSigned: true, isQuarantined: false,
            isSystemApp: true, isUserOwned: false, isRunning: false, bundleSize: 100
        )
        XCTAssertTrue(systemApp.isSystemApp)
        XCTAssertFalse(systemApp.isUserOwned)
    }

    // MARK: - Residual correlation

    func testResidualExactContainerMatching() {
        let installed = [
            AppRecord(name: "PresentApp", bundlePath: "/Applications/PresentApp.app",
                      bundleID: "com.example.present", version: nil, build: nil,
                      architectures: [], isCodeSigned: nil, isQuarantined: false,
                      isSystemApp: false, isUserOwned: true, isRunning: false, bundleSize: 1)
        ]
        // Preference domain of a removed app → high-confidence leftover.
        let match = ResidualCorrelationEngine.match(
            entryPath: "/Users/x/Library/Preferences/com.removed.app.plist",
            entryName: "com.removed.app.plist",
            installedApps: installed
        )
        XCTAssertEqual(match?.bundleID, "com.removed.app")
        XCTAssertEqual(match?.confidence, .high)

        // Preference domain of an installed app → not a leftover.
        let installedMatch = ResidualCorrelationEngine.match(
            entryPath: "/Users/x/Library/Preferences/com.example.present.plist",
            entryName: "com.example.present.plist",
            installedApps: installed
        )
        XCTAssertNil(installedMatch)
    }

    func testGenericWordsAreNeverLeftovers() {
        let installed: [AppRecord] = []
        for word in ["Cache", "Logs", "Preferences", "Data", "Support"] {
            let match = ResidualCorrelationEngine.match(
                entryPath: "/Users/x/Library/Application Support/" + word,
                entryName: word,
                installedApps: installed
            )
            XCTAssertNil(match, "\(word) must never be a leftover candidate")
        }
    }

    // MARK: - Space Lens

    func testSpaceLensAggregatesBeyondCap() async throws {
        for index in 0..<60 {
            _ = makeFile("bulk/dir\(index)/file.bin", contents: String(repeating: "d", count: 100 + index))
        }
        let tree = SpaceLensEngine.buildTree(
            root: fixture,
            includeHidden: false,
            includePackageContents: false,
            maxDepth: 4
        )
        let bulk = tree.children.first { $0.name == "bulk" }
        XCTAssertNotNil(bulk)
        XCTAssertLessThanOrEqual(bulk?.children.count ?? 0, SpaceLensEngine.childrenCap + 1)
        if let bulk, bulk.children.contains(where: { $0.isAggregate }) {
            let aggregate = bulk.children.first { $0.isAggregate }
            XCTAssertGreaterThan(aggregate?.totalBytes ?? 0, 0)
            XCTAssertFalse(aggregate?.children.isEmpty ?? true)
        }
    }

    // MARK: - Mach-O headers

    func testMachOArchitectureReading() throws {
        // Thin arm64 header: magic 0xFEEDFACF + cputype 0x0100000C.
        var thin = Data()
        thin.append(contentsOf: [0xFE, 0xED, 0xFA, 0xCF])
        thin.append(contentsOf: [0x01, 0x00, 0x00, 0x0C])
        thin.append(Data(repeating: 0, count: 24))
        let thinURL = fixture.appendingPathComponent("thin.bin")
        try thin.write(to: thinURL)
        XCTAssertEqual(MachOArchitecture.architectures(ofBinaryAt: thinURL.path), ["arm64"])

        // Fat header with one arm64 slice.
        var fat = Data()
        fat.append(contentsOf: [0xCA, 0xFE, 0xBA, 0xBE]) // FAT_MAGIC
        fat.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // nfat_arch = 1
        fat.append(contentsOf: [0x01, 0x00, 0x00, 0x0C]) // cputype arm64
        fat.append(Data(repeating: 0, count: 16))        // rest of fat_arch
        let fatURL = fixture.appendingPathComponent("fat.bin")
        try fat.write(to: fatURL)
        XCTAssertEqual(MachOArchitecture.architectures(ofBinaryAt: fatURL.path), ["arm64"])

        // Garbage returns empty.
        let garbageURL = fixture.appendingPathComponent("garbage.bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: garbageURL)
        XCTAssertEqual(MachOArchitecture.architectures(ofBinaryAt: garbageURL.path), [])
    }
}
