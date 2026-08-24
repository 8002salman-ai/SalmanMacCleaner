//
//  StartupManagerTests.swift
//  SalmanMacCleanerTests
//
//  Tests for the read-only startup manager.
//

import XCTest
@testable import SalmanMacCleaner

final class StartupManagerTests: XCTestCase {

    func testModificationsAreDisabledInVersion1() {
        XCTAssertFalse(StartupManager.modificationsAllowed,
                       "Version 1 must never modify startup items")
    }

    func testReadOnlyExplanationIsNonEmpty() {
        XCTAssertFalse(StartupManager.readOnlyExplanation.isEmpty)
    }

    func testDiscoveryNeverThrows() {
        // On machines without visible login items this returns an empty array
        // (or a partial list) — it must never throw or crash.
        let items = StartupManager.discover()
        XCTAssertTrue(items.allSatisfy { !$0.name.isEmpty })
    }

    func testLaunchAgentLabelParsesPlainPlist() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.example.agent</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/true</string>
            </array>
        </dict>
        </plist>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-\(UUID().uuidString).plist")
        try plist.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(StartupManager.launchAgentLabel(at: url.path), "com.example.agent")
    }

    func testLaunchAgentLabelHandlesMissingFile() {
        XCTAssertNil(StartupManager.launchAgentLabel(at: "/nonexistent/agent.plist"))
    }
}
