//
//  VersionComparator.swift
//  SalmanMacCleaner
//
//  Semantic-version comparison for the updater and Settings. Pure logic —
//  no I/O — so it is fully unit-testable.
//

import Foundation

public enum VersionComparator {

    public struct SemanticVersion: Comparable, Equatable, Codable {
        public var major: Int
        public var minor: Int
        public var patch: Int
        public var prerelease: String?

        public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil): return false
            case (nil, .some): return false          // release > prerelease
            case (.some, nil): return true           // prerelease < release
            case (.some(let l), .some(let r)): return l < r
            }
        }
    }

    /// Parse a semantic version string like "1.2.3" or "1.2.3-beta.4".
    public static func parse(_ raw: String) -> SemanticVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var core = trimmed
        var prerelease: String?
        if let dashIndex = trimmed.firstIndex(of: "-") {
            core = String(trimmed[..<dashIndex])
            prerelease = String(trimmed[trimmed.index(after: dashIndex)...])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3,
              let major = Int(parts[0]), let minor = Int(parts[1]) else {
            return nil
        }
        let patch = parts.count == 3 ? (Int(parts[2]) ?? 0) : 0
        return SemanticVersion(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    /// Whether `candidate` is newer than `current`.
    public static func isNewer(candidate: String, current: String) -> Bool {
        guard let candidateVersion = parse(candidate),
              let currentVersion = parse(current) else {
            // Unparseable versions never count as an update.
            return false
        }
        return candidateVersion > currentVersion
    }
}
