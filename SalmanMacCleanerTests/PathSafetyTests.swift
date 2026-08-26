//
//  PathSafetyTests.swift
//  SalmanMacCleanerTests
//
//  Tests for the central path-safety policy: protected locations, personal
//  directories, traversal detection, symlink handling and ownership checks.
//

import XCTest
@testable import SalmanMacCleaner

final class PathSafetyTests: XCTestCase {

    private var sandbox: URL!
    private var originalUID: uid_t!

    override func setUp() {
        super.setUp()
        originalUID = PathSafety.currentUID
        PathSafety.currentUID = getuid()

        sandbox = PathSafety.userHome.appendingPathComponent(".SalmanMacCleanerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        PathSafety.currentUID = originalUID
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String = "hello") -> URL {
        let url = sandbox.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8))
        return url
    }

    // MARK: - Protected root locations

    func testProtectedRootLocationsAreRejected() {
        let protected = [
            "/System", "/System/Library", "/Library", "/private", "/usr", "/bin",
            "/sbin", "/Applications", "/Applications/Safari.app", "/Volumes",
            "/Network", "/dev", "/cores", "/etc", "/var", "/tmp", "/opt", "/srv",
            "/home", "/net"
        ]
        for path in protected {
            XCTAssertTrue(PathSafety.isProtectedRootLocation(path), "\(path) must be protected")
        }
    }

    func testUserHomeIsNotProtectedRoot() {
        XCTAssertFalse(PathSafety.isProtectedRootLocation(PathSafety.userHome.path))
        let userFile = PathSafety.userHome.path + "/some-regular-file.txt"
        XCTAssertFalse(PathSafety.isProtectedRootLocation(userFile))
    }

    // MARK: - Personal directories

    func testPersonalDirectoriesAreDetected() {
        for name in PathSafety.personalDirectories {
            let path = PathSafety.userHome.path + "/" + name
            XCTAssertTrue(PathSafety.isPersonalDirectory(path), "\(name) must be personal")
            XCTAssertTrue(PathSafety.isInsidePersonalDirectory(path))
            XCTAssertTrue(PathSafety.isInsidePersonalDirectory(path + "/Subfolder"))
        }
        XCTAssertFalse(PathSafety.isInsidePersonalDirectory(PathSafety.userHome.path + "/tmpfiles"))
    }

    func testProtectedComponentsAndTopLevelPersonalPolicy() {
        XCTAssertTrue(PathSafety.containsProtectedComponent(PathSafety.userHome.path + "/Desktop/sub"))
        XCTAssertTrue(PathSafety.containsProtectedComponent("/whatever/Documents/x"))
        XCTAssertFalse(PathSafety.containsTopLevelProtectedComponent("/whatever/Documents/x"))
        XCTAssertFalse(PathSafety.containsProtectedComponent("/Users/test/tmp/test"))
    }

    // MARK: - Traversal

    func testTraversalAttemptsAreRejected() {
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertTrue(PathSafety.hasTraversal("/etc/passwd", root: root.path))
        XCTAssertTrue(PathSafety.hasTraversal(root.path + "/../other", root: root.path))
        XCTAssertFalse(PathSafety.hasTraversal(root.path + "/file.txt", root: root.path))
        XCTAssertFalse(PathSafety.hasTraversal(root.path, root: root.path))
    }

    func testValidateRejectsOutsideContainment() {
        let root = sandbox.appendingPathComponent("root", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inside = makeFile("root/inside.txt")

        // A path that lexically stays inside root but physically doesn't exist
        // must fail with missingPath, and a path outside root must fail with
        // traversal/outside-home errors — never succeed.
        let outside = sandbox.appendingPathComponent("outside.txt")
        FileManager.default.createFile(atPath: outside.path, contents: Data("x".utf8))

        let outsideResult = PathSafety.validate(path: outside.path, root: root.path, purpose: .scan)
        XCTAssertThrowsError(try outsideResult.get())

        let missingResult = PathSafety.validate(path: root.path + "/nope.txt", root: root.path, purpose: .scan)
        XCTAssertThrowsError(try missingResult.get())

        let goodResult = PathSafety.validate(path: inside.path, root: root.path, purpose: .scan)
        XCTAssertNoThrow(try goodResult.get())
    }

    // MARK: - Symlinks

    func testSymlinksAreRejectedByDefaultEvenWhenTargetIsSafe() throws {
        let root = sandbox.appendingPathComponent("symroot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = makeFile("symroot/target.txt")
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = PathSafety.validate(path: link.path, root: root.path, purpose: .scan, allowSymlink: false)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? PathSafetyError, .suspiciousLink(link.path))
        }
    }

    func testExplicitlyAllowedSymlinkMustStayInsideRoot() throws {
        let root = sandbox.appendingPathComponent("symroot2", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = makeFile("symroot2/target.txt")
        let link = root.appendingPathComponent("good-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let good = PathSafety.validate(path: link.path, root: root.path, purpose: .scan, allowSymlink: true)
        XCTAssertNoThrow(try good.get())

        // A symlink escaping the root must fail even when symlinks are allowed.
        let escapedTarget = makeFile("escaped.txt")
        let escapedLink = root.appendingPathComponent("bad-link.txt")
        try FileManager.default.createSymbolicLink(at: escapedLink, withDestinationURL: escapedTarget)
        let bad = PathSafety.validate(path: escapedLink.path, root: root.path, purpose: .scan, allowSymlink: true)
        XCTAssertThrowsError(try bad.get())
    }

    func testRecursiveSymlinkLoopIsNotFollowed() throws {
        let root = sandbox.appendingPathComponent("looproot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let loop = root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)

        // Never resolves; default policy rejects the symlink outright.
        let result = PathSafety.validate(path: loop.path, root: root.path, purpose: .scan)
        XCTAssertThrowsError(try result.get())
    }

    // MARK: - Ownership

    func testOwnershipChecksHonorInjectedUID() {
        let file = makeFile("owned.txt")
        PathSafety.currentUID = getuid()
        XCTAssertTrue(PathSafety.isOwnedByCurrentUser(file.path))

        // Files owned by a different uid are rejected.
        PathSafety.currentUID = 12345
        if getuid() != 12345 {
            XCTAssertFalse(PathSafety.isOwnedByCurrentUser(file.path))
            let result = PathSafety.validate(path: file.path, root: sandbox.path, purpose: .scan)
            XCTAssertThrowsError(try result.get()) { error in
                XCTAssertNotNil(error as? PathSafetyError)
            }
        }
    }

    // MARK: - Protected file names / suffixes

    func testProtectedFileNamesAndSuffixes() {
        XCTAssertTrue(PathSafety.isProtectedFile(name: "Cookies", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "History", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "Login Data", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "login.keychain-db", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "Important.sqlite", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "VM.vmdk", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "Disk.dmg", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "MyApp.app", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: ".git", purpose: .cleanup))
        XCTAssertTrue(PathSafety.isProtectedFile(name: "setup.sh", purpose: .cleanup))
        XCTAssertFalse(PathSafety.isProtectedFile(name: "ProjectCache.bin", purpose: .scan))
    }

    // MARK: - App bundle detection

    func testAppBundleDetection() {
        XCTAssertTrue(PathSafety.isAppBundle("/Applications/Safari.app"))
        XCTAssertFalse(PathSafety.isAppBundle("/Applications/notes.txt"))
    }

    // MARK: - Canonicalization

    func testCanonicalizationResolvesParentSymlinksOnly() {
        let realDir = sandbox.appendingPathComponent("realdir", isDirectory: true)
        try? FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let file = realDir.appendingPathComponent("data.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data("d".utf8))

        let linkDir = sandbox.appendingPathComponent("linkdir")
        try? FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let resolved = PathSafety.canonicalPathResolvingParent(of: linkDir.path + "/data.txt")
        XCTAssertEqual(resolved, file.standardizedFileURL.path)
    }
}
