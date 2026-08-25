//
//  JunkClassifier.swift
//  SalmanMacCleaner
//
//  Maps inventory records to junk verdicts. Conservative by construction:
//  everything starts PROTECTED; only strong allowlist matches can become
//  SAFE, and a narrow set of well-understood locations become REVIEW.
//  Inventory and cleanup eligibility are strictly separate concepts.
//

import Foundation

public enum JunkClassifier {

    /// Category names grouped for the results workspace.
    public static let systemJunkCategories: Set<String> = [
        "userCache", "userLog", "crashReport", "diagnosticReport", "savedState",
        "tempFile", "updateRemnant", "brokenAlias", "brokenLoginItem", "brokenPreference"
    ]

    /// Strong allowlist: directory suffixes that make a file SAFE when other
    /// guards (ownership, age, size, not-in-use) pass.
    private static let safeDirectorySuffixes: [String] = [
        "/Library/Caches",
        "/Library/Logs",
        "/Library/Logs/DiagnosticReports",
        "/Library/Saved Application State",
        "/.cache",
        "/.npm/_cacache",
        "/Library/Caches/Homebrew",
        "/Library/Caches/pip",
        "/Library/Caches/Yarn",
        "/Library/Caches/pnpm",
        "/Library/Caches/CocoaPods",
        "/Library/Developer/CoreSimulator/Caches"
    ]

    /// REVIEW locations: potentially useful, never auto-selected.
    private static let reviewDirectorySuffixes: [String] = [
        "/Library/Developer/Xcode/DerivedData",
        "/Library/Developer/Xcode/Archives",
        "/Library/Developer/Xcode/iOS DeviceSupport",
        "/Library/Developer/CoreSimulator",
        "/Library/Developer/CoreSimulator/Caches",
        "/.gradle",
        "/.m2/repository",
        "/.cargo/registry",
        "/Library/org.swift.swiftpm",
        "/Library/Caches/org.swift.swiftpm"
    ]

    /// File suffixes that are PROTECTED regardless of location.
    private static let protectedSuffixes: Set<String> = [
        ".sqlite", ".sqlite3", ".sqlite-wal", ".sqlite-shm", ".db", ".db3",
        ".keychain", ".keychain-db", ".p12", ".pfx", ".pem", ".crt", ".key",
        ".vmdk", ".vhdx", ".qcow2", ".sparsebundle", ".sparseimage", ".dmgpart",
        ".pst", ".ost", ".olk15", ".mbox", ".eml", ".maildir",
        ".mobileconfig", ".provisionprofile", ".p8", ".cer",
        ".gitconfig", ".npmrc", ".yarnrc", ".netrc", ".ssh"
    ]

    /// File names that are PROTECTED regardless of location.
    private static let protectedNames: Set<String> = [
        "Cookies", "Cookies.binarycookies", "History", "History-journal",
        "Login Data", "Login Data-journal", "Web Data", "Local State",
        "Bookmarks", "Bookmarks.bak", "Favicons", "Visited Links",
        "session.json", "keychain", "Package.resolved", "lock.json", "yarn.lock",
        "package-lock.json", "pnpm-lock.yaml", "Cargo.lock", "Podfile.lock",
        "Gemfile.lock", "gradle-wrapper.properties", ".python-version"
    ]

    /// Classify one inventory record.
    public static func classify(_ record: FileRecord, now: Date = Date()) -> JunkVerdict {
        let path = record.path
        let name = record.name

        // 1. Hard protections first — nothing else may override these.
        if let verdict = hardProtection(record, path: path, name: name) {
            return verdict
        }

        // 2. Protected classification (personal data, credentials, …).
        if let verdict = protectedClassification(record, path: path, name: name) {
            return verdict
        }

        // 3. Review-only well-understood locations.
        if let verdict = reviewClassification(record, path: path, now: now) {
            return verdict
        }

        // 4. SAFE allowlist: regenerable cache/log/temp content owned by the
        //    user, old enough and not in active use.
        if let verdict = safeClassification(record, path: path, name: name, now: now) {
            return verdict
        }

        // 5. Default: unknown files are protected.
        return JunkVerdict(
            category: .unknown,
            safety: .protected,
            reason: NSLocalizedString("classify.reason.unknown", comment: ""),
            autoSelectable: false,
            regenerable: false,
            sourceRule: "default"
        )
    }

    // MARK: - Layers

    private static func hardProtection(_ record: FileRecord, path: String, name: String) -> JunkVerdict? {
        if record.ownerUID != PathSafety.currentUID {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.other_user", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "ownership"
            )
        }
        if record.isSymlink || PathSafety.isAppBundle(path) {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.bundle_or_link", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "hard-protection"
            )
        }
        let lowerName = name.lowercased()
        if protectedNames.contains(name) || protectedNames.contains(lowerName) {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.protected_name", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "protected-name"
            )
        }
        for suffix in protectedSuffixes where lowerName.hasSuffix(suffix) {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.protected_suffix", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "protected-suffix"
            )
        }
        return nil
    }

    private static func protectedClassification(_ record: FileRecord, path: String, name: String) -> JunkVerdict? {
        if PathSafety.isInsidePersonalDirectory(path) {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.personal", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "personal-directory"
            )
        }
        if PathSafety.containsProtectedComponent(path) {
            return JunkVerdict(
                category: .unknown,
                safety: .protected,
                reason: NSLocalizedString("classify.reason.protected_component", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "protected-component"
            )
        }
        return nil
    }

    private static func reviewClassification(_ record: FileRecord, path: String, now: Date) -> JunkVerdict? {
        for suffix in reviewDirectorySuffixes where path.hasPrefix(PathSafety.userHome.path + suffix) {
            let category = reviewCategory(for: path)
            return JunkVerdict(
                category: category,
                safety: .review,
                reason: String(format: NSLocalizedString("classify.reason.review_location", comment: ""), category.title),
                autoSelectable: false,
                regenerable: regenerable(category),
                sourceRule: "review-location"
            )
        }
        // Old installers and disk images are review-only.
        let lowerName = record.name.lowercased()
        if lowerName.hasSuffix(".dmg") || lowerName.hasSuffix(".pkg") || lowerName.hasSuffix(".xip") {
            return JunkVerdict(
                category: .installer,
                safety: .review,
                reason: NSLocalizedString("classify.reason.installer", comment: ""),
                autoSelectable: false,
                regenerable: false,
                sourceRule: "installer"
            )
        }
        return nil
    }

    private static func safeClassification(_ record: FileRecord, path: String, name: String, now: Date) -> JunkVerdict? {
        for suffix in safeDirectorySuffixes where path.hasPrefix(PathSafety.userHome.path + suffix) {
            let category = cacheCategory(for: path, name: name)
            let age = record.modified ?? .distantPast
            let ageDays = now.timeIntervalSince(age) / 86_400
            guard ageDays >= 1 else {
                // Recently used cache files are not offered as junk.
                return JunkVerdict(
                    category: category,
                    safety: .protected,
                    reason: NSLocalizedString("classify.reason.in_use", comment: ""),
                    autoSelectable: false,
                    regenerable: true,
                    sourceRule: "in-use-cache"
                )
            }
            return JunkVerdict(
                category: category,
                safety: .safe,
                reason: String(format: NSLocalizedString("classify.reason.safe_cache", comment: ""), category.title),
                autoSelectable: true,
                regenerable: true,
                sourceRule: "safe-cache"
            )
        }
        return nil
    }

    // MARK: - Category mapping

    private static func reviewCategory(for path: String) -> JunkCategory {
        if path.contains("/DerivedData") { return .xcodeDerivedData }
        if path.contains("/Archives") { return .xcodeArchive }
        if path.contains("iOS DeviceSupport") || path.contains("DeviceSupport") { return .iosDeviceSupport }
        if path.contains("/CoreSimulator") { return .simulatorData }
        if path.contains("/.gradle") { return .gradleCache }
        if path.contains("/.m2/") { return .mavenCache }
        if path.contains("/.cargo/") { return .cargoCache }
        if path.contains("org.swift.swiftpm") { return .swiftPMCache }
        return .moduleCache
    }

    private static func cacheCategory(for path: String, name: String) -> JunkCategory {
        if path.contains("/Logs") { return .userLog }
        if path.contains("DiagnosticReports") { return .diagnosticReport }
        if path.contains("/Saved Application State") { return .savedState }
        if path.contains("/Homebrew") { return .homebrewCache }
        if path.contains("/pip") { return .pipCache }
        if path.contains("/Yarn") { return .yarnCache }
        if path.contains("/pnpm") { return .pnpmCache }
        if path.contains("/CocoaPods") { return .cocoapodsCache }
        if path.contains("/_cacache") { return .npmCache }
        if name.lowercased().hasPrefix("temp") || name.lowercased().hasSuffix(".tmp") {
            return .tempFile
        }
        return .userCache
    }

    private static func regenerable(_ category: JunkCategory) -> Bool {
        switch category {
        case .xcodeArchive, .installer:
            return false
        default:
            return true
        }
    }
}
