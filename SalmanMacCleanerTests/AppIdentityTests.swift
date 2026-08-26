//
//  AppIdentityTests.swift
//  SalmanMacCleanerTests
//
//  Regression coverage for the v1.2.0 product rename: the visible app name
//  must be 8002CleanUp everywhere (bundle/display name, identity constant,
//  version badge) and the version must be the next release after the
//  previously installed 1.1.7 (7).
//

import XCTest
@testable import SalmanMacCleaner

final class AppIdentityTests: XCTestCase {

    func testVisibleApplicationNameIs8002CleanUp() {
        XCTAssertEqual(AppIdentity.displayName, "8002CleanUp")
    }

    func testBundleDisplayNameAndNameAre8002CleanUp() throws {
        try ensureHostedInApp()
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertEqual(name, "8002CleanUp")
        XCTAssertEqual(displayName, "8002CleanUp")
    }

    func testVersionIsNextReleaseAfter117() throws {
        try ensureHostedInApp()
        // 1.1.7 (build 7) was the previous installed version; the next
        // release must be 1.2.0 (build 8).
        XCTAssertEqual(AppIdentity.shortVersion, "1.2.0")
        XCTAssertEqual(AppIdentity.buildNumber, "8")
    }

    func testVersionBadgeIsVisibleAndConsistent() {
        XCTAssertTrue(AppIdentity.versionBadge.hasPrefix("v"))
        XCTAssertTrue(AppIdentity.versionBadge.contains(AppIdentity.shortVersion))
        XCTAssertTrue(AppIdentity.helpText.contains(AppIdentity.displayName))
        XCTAssertTrue(AppIdentity.helpText.contains(AppIdentity.versionBadge))
    }

    func testNextVersionIsStrictlyGreaterThanPrevious() {
        XCTAssertNotNil(VersionComparator.parse(AppIdentity.shortVersion))
        XCTAssertTrue(VersionComparator.isNewer(candidate: AppIdentity.shortVersion, current: "1.1.7"),
                      "\(AppIdentity.shortVersion) must be strictly greater than 1.1.7")
    }

    /// Bundle-metadata assertions are only meaningful when the test runner is
    /// hosted inside the 8002CleanUp app bundle (TEST_HOST).
    private func ensureHostedInApp() throws {
        if Bundle.main.bundleIdentifier == "com.salman.SalmanMacCleaner" { return }
        throw XCTSkip("Not hosted in the app bundle; bundle metadata is unavailable.")
    }
}
