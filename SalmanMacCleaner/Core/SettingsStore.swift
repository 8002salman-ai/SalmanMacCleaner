//
//  SettingsStore.swift
//  SalmanMacCleaner
//
//  User preferences: thresholds, exclusions, scan depth, categories and
//  appearance. Persisted with UserDefaults via @AppStorage-compatible keys.
//

import Foundation
import SwiftUI
import Combine

/// Appearance choice for the app (follow system, light, dark).
public enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return NSLocalizedString("appearance.system", comment: "")
        case .light: return NSLocalizedString("appearance.light", comment: "")
        case .dark: return NSLocalizedString("appearance.dark", comment: "")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
public final class SettingsStore: ObservableObject {

    public static let shared = SettingsStore()

    // MARK: - Keys

    private enum Key {
        static let dryRun = "settings.dryRun"
        static let largeFileThreshold = "settings.largeFileThresholdMB"
        static let maxScanDepth = "settings.maxScanDepth"
        static let defaultScannerCategory = "settings.defaultScannerCategory"
        static let excludedPatterns = "settings.excludedPatterns"
        static let confirmBeforeCleanup = "settings.confirmBeforeCleanup"
        static let appearance = "settings.appearance"
        static let scanDevCachesOnLaunch = "settings.scanDevCachesOnLaunch"
        static let devCacheMaxAgeDays = "settings.devCacheMaxAgeDays"
    }

    // MARK: - Published settings

    /// Dry-run / preview mode. ON by default and never silently disabled.
    @Published public var dryRun: Bool {
        didSet { defaults.set(dryRun, forKey: Key.dryRun) }
    }

    /// Large-file threshold in megabytes.
    @Published public var largeFileThresholdMB: Double {
        didSet { defaults.set(largeFileThresholdMB, forKey: Key.largeFileThreshold) }
    }

    /// Maximum directory depth scanned by the recursive scanners.
    @Published public var maxScanDepth: Int {
        didSet { defaults.set(maxScanDepth, forKey: Key.maxScanDepth) }
    }

    /// Category selected by default in the developer cache scanner.
    @Published public var defaultScannerCategory: String {
        didSet { defaults.set(defaultScannerCategory, forKey: Key.defaultScannerCategory) }
    }

    /// User-managed exclusion patterns (substring matches, case-insensitive).
    @Published public var excludedPatterns: [String] {
        didSet { defaults.set(excludedPatterns, forKey: Key.excludedPatterns) }
    }

    /// Require a second confirmation dialog before cleanup.
    @Published public var confirmBeforeCleanup: Bool {
        didSet { defaults.set(confirmBeforeCleanup, forKey: Key.confirmBeforeCleanup) }
    }

    /// Light / dark / system appearance.
    @Published public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// Automatically refresh dev-cache estimates when the app launches.
    @Published public var scanDevCachesOnLaunch: Bool {
        didSet { defaults.set(scanDevCachesOnLaunch, forKey: Key.scanDevCachesOnLaunch) }
    }

    /// Only offer dev-cache entries that were modified at least this long ago
    /// (age in days) for cleanup.
    @Published public var devCacheMaxAgeDays: Int {
        didSet { defaults.set(devCacheMaxAgeDays, forKey: Key.devCacheMaxAgeDays) }
    }

    public let defaults: UserDefaults

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedDryRun = defaults.object(forKey: Key.dryRun) as? Bool
        self.dryRun = storedDryRun ?? true

        let storedThreshold = defaults.object(forKey: Key.largeFileThreshold) as? Double
        self.largeFileThresholdMB = storedThreshold ?? 500

        let storedDepth = defaults.object(forKey: Key.maxScanDepth) as? Int
        self.maxScanDepth = storedDepth ?? 6

        self.defaultScannerCategory = defaults.string(forKey: Key.defaultScannerCategory) ?? "derivedData"
        self.excludedPatterns = (defaults.array(forKey: Key.excludedPatterns) as? [String]) ?? []
        self.confirmBeforeCleanup = (defaults.object(forKey: Key.confirmBeforeCleanup) as? Bool) ?? true

        let storedAppearance = defaults.string(forKey: Key.appearance)
        self.appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system

        self.scanDevCachesOnLaunch = (defaults.object(forKey: Key.scanDevCachesOnLaunch) as? Bool) ?? true

        let storedAge = defaults.object(forKey: Key.devCacheMaxAgeDays) as? Int
        self.devCacheMaxAgeDays = storedAge ?? 90
    }

    // MARK: - Exclusion logic

    /// Whether `path` matches any user exclusion pattern.
    public func isExcluded(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        for pattern in excludedPatterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lowercased.contains(trimmed.lowercased()) {
                return true
            }
        }
        return false
    }

    /// Reset every setting back to its default.
    public func resetAll() {
        dryRun = true
        largeFileThresholdMB = 500
        maxScanDepth = 6
        defaultScannerCategory = "derivedData"
        excludedPatterns = []
        confirmBeforeCleanup = true
        appearance = .system
        scanDevCachesOnLaunch = true
        devCacheMaxAgeDays = 90
    }

    /// A human-readable one-line summary of the effective safety posture.
    public var safetySummary: String {
        var lines: [String] = []
        lines.append(dryRun
                     ? NSLocalizedString("settings.dryrun.on", comment: "")
                     : NSLocalizedString("settings.dryrun.off", comment: ""))
        lines.append(String(format: NSLocalizedString("settings.summary.threshold", comment: ""), largeFileThresholdMB))
        lines.append(String(format: NSLocalizedString("settings.summary.depth", comment: ""), maxScanDepth))
        lines.append(String(format: NSLocalizedString("settings.summary.exclusions", comment: ""), excludedPatterns.count))
        return lines.joined(separator: " · ")
    }
}
