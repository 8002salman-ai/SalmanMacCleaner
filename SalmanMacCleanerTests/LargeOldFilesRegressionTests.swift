//
//  LargeOldFilesRegressionTests.swift
//  SalmanMacCleanerTests
//
//  Regression coverage for Large & Old Files: deterministic sort orders used
//  by the results list and the elapsed-time badge formatting. The traversal
//  itself is a live-filesystem scan covered by the fixture end-to-end tests.
//

import XCTest
@testable import SalmanMacCleaner

final class LargeOldFilesRegressionTests: XCTestCase {

    private let largeNew = ScannedItem(
        path: "/tmp/big-new.bin",
        size: 900,
        modificationDate: Date(timeIntervalSince1970: 1_800_000_000)
    )
    private let smallNew = ScannedItem(
        path: "/tmp/small-new.bin",
        size: 100,
        modificationDate: Date(timeIntervalSince1970: 1_800_000_100)
    )
    private let largeOld = ScannedItem(
        path: "/tmp/big-old.bin",
        size: 800,
        modificationDate: Date(timeIntervalSince1970: 1_500_000_000)
    )
    private let smallOld = ScannedItem(
        path: "/tmp/small-old.bin",
        size: 50,
        modificationDate: Date(timeIntervalSince1970: 1_400_000_000)
    )

    private var items: [ScannedItem] { [smallOld, largeNew, smallNew, largeOld] }

    func testSortBySizeDescending() {
        let sorted = LargeOldSortOption.sizeDescending.sort(items)
        XCTAssertEqual(sorted.map(\.size), [900, 800, 100, 50])
    }

    func testSortBySizeAscending() {
        let sorted = LargeOldSortOption.sizeAscending.sort(items)
        XCTAssertEqual(sorted.map(\.size), [50, 100, 800, 900])
    }

    func testSortByNewestFirst() {
        let sorted = LargeOldSortOption.newestFirst.sort(items)
        XCTAssertEqual(sorted.map(\.path), ["/tmp/small-new.bin", "/tmp/big-new.bin", "/tmp/big-old.bin", "/tmp/small-old.bin"])
    }

    func testSortByOldestFirst() {
        let sorted = LargeOldSortOption.oldestFirst.sort(items)
        XCTAssertEqual(sorted.map(\.path), ["/tmp/small-old.bin", "/tmp/big-old.bin", "/tmp/big-new.bin", "/tmp/small-new.bin"])
    }

    func testSortByNameIsDeterministicAndCaseInsensitive() {
        let sorted = LargeOldSortOption.name.sort(items)
        XCTAssertEqual(sorted.map(\.name), ["big-new.bin", "big-old.bin", "small-new.bin", "small-old.bin"])
    }

    func testSortIsStableForTies() {
        let a = ScannedItem(path: "/z/a", size: 10, modificationDate: Date(timeIntervalSince1970: 100))
        let b = ScannedItem(path: "/z/b", size: 10, modificationDate: Date(timeIntervalSince1970: 100))
        let byName = LargeOldSortOption.name.sort([b, a])
        XCTAssertEqual(byName.map(\.path), ["/z/a", "/z/b"])
    }

    func testElapsedFormatterRejectsNegativeValues() {
        XCTAssertEqual(LargeOldFilesView.formatElapsed(-5), "0:00")
        XCTAssertEqual(LargeOldFilesView.formatElapsed(0), "0:00")
        XCTAssertEqual(LargeOldFilesView.formatElapsed(0.4), "0:00")
        XCTAssertEqual(LargeOldFilesView.formatElapsed(42.7), "0:43")
        XCTAssertEqual(LargeOldFilesView.formatElapsed(65), "1:05")
        XCTAssertEqual(LargeOldFilesView.formatElapsed(3_661), "61:01")
    }
}
