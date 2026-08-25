//
//  SettingsHistoryTests.swift
//  SalmanMacCleanerTests
//
//  Tests for settings defaults/persistence and the local cleanup history
//  (JSON/CSV export, preview markers, corruption tolerance).
//

import XCTest
@testable import SalmanMacCleaner

final class SettingsHistoryTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsHistoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Settings defaults

    @MainActor
    func testDryRunIsOnByDefault() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.dryRun, "Dry-run must be ON by default")
    }

    @MainActor
    func testConfirmationIsOnByDefault() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.confirmBeforeCleanup)
    }

    @MainActor
    func testDefaultThresholdAndDepth() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.largeFileThresholdMB, 500)
        XCTAssertEqual(settings.maxScanDepth, 6)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertTrue(settings.excludedPatterns.isEmpty)
    }

    @MainActor
    func testSettingsPersistAndRoundTrip() {
        let first = SettingsStore(defaults: defaults)
        first.dryRun = false
        first.largeFileThresholdMB = 750
        first.maxScanDepth = 3
        first.excludedPatterns = ["Cache", "node_modules"]
        first.appearance = .dark
        first.confirmBeforeCleanup = false

        let second = SettingsStore(defaults: defaults)
        XCTAssertFalse(second.dryRun)
        XCTAssertEqual(second.largeFileThresholdMB, 750)
        XCTAssertEqual(second.maxScanDepth, 3)
        XCTAssertEqual(second.excludedPatterns, ["Cache", "node_modules"])
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertFalse(second.confirmBeforeCleanup)
    }

    @MainActor
    func testResetAllRestoresSafeDefaults() {
        let settings = SettingsStore(defaults: defaults)
        settings.dryRun = false
        settings.maxScanDepth = 12
        settings.excludedPatterns = ["x"]
        settings.resetAll()

        XCTAssertTrue(settings.dryRun)
        XCTAssertEqual(settings.maxScanDepth, 6)
        XCTAssertTrue(settings.excludedPatterns.isEmpty)
        XCTAssertEqual(settings.appearance, .system)
    }

    @MainActor
    func testExclusionMatchingIsCaseInsensitive() {
        let settings = SettingsStore(defaults: defaults)
        settings.excludedPatterns = ["CACHE"]
        XCTAssertTrue(settings.isExcluded("/Users/x/Library/cache-folder"))
        XCTAssertTrue(settings.isExcluded("/users/x/MyCacheThing"))
        XCTAssertFalse(settings.isExcluded("/Users/x/Documents"))
        XCTAssertFalse(settings.isExcluded(""))
    }

    // MARK: - History

    @MainActor
    func testHistoryRecordsAndPersistsEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        store.record(HistoryEntry(
            action: "Preview",
            category: "largeFiles",
            itemCount: 3,
            bytes: 1234,
            dryRun: true,
            root: "/tmp/root"
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.entries[0].isPreview)

        let reloaded = HistoryStore(fileURL: url)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].bytes, 1234)
        XCTAssertEqual(reloaded.entries[0].category, "largeFiles")
    }

    @MainActor
    func testHistoryJSONExportIsValidAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        store.record(HistoryEntry(action: "Clean", category: "duplicates", itemCount: 2, bytes: 4096, dryRun: false, root: "/tmp/x"))

        guard let data = store.exportData(format: .json) else {
            return XCTFail("JSON export failed")
        }
        let decoded = try JSONDecoder().decode([HistoryEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(decoded[0].dryRun)
    }

    @MainActor
    func testHistoryCSVExportHasHeaderAndRow() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-csv-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        store.record(HistoryEntry(action: "Trash", category: "developerCaches", itemCount: 1, bytes: 8, dryRun: false, root: "/tmp/y"))

        guard let data = store.exportData(format: .csv),
              let csv = String(data: data, encoding: .utf8) else {
            return XCTFail("CSV export failed")
        }
        XCTAssertTrue(csv.hasPrefix("id,date,action,category,item_count,bytes,dry_run,root"))
        XCTAssertTrue(csv.contains("developerCaches"))
        XCTAssertTrue(csv.contains("dry_run"))
    }

    @MainActor
    func testHistorySurvivesCorruptFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-corrupt-\(UUID().uuidString).json")
        try? Data("not json at all {{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        XCTAssertTrue(store.entries.isEmpty, "Corrupt history must start fresh, not crash")
    }

    @MainActor
    func testHistoryClearEmptiesEntries() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-clear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = HistoryStore(fileURL: url)
        store.record(HistoryEntry(action: "x", category: "c", itemCount: 1, bytes: 1, dryRun: true, root: "/tmp"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }
}
