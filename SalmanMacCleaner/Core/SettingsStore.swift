//
//  SettingsStore.swift
//  SalmanMacCleaner
//
//  User preferences: safety posture, scan behavior, permissions, updates and
//  appearance. Persisted with UserDefaults; safe defaults always.
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
        // Safety
        static let dryRun = "settings.dryRun"
        static let confirmBeforeCleanup = "settings.confirmBeforeCleanup"
        static let smartSelection = "settings.smartSelection"
        // Scanning
        static let largeFileThreshold = "settings.largeFileThresholdMB"
        static let maxScanDepth = "settings.maxScanDepth"
        static let defaultScanMode = "settings.defaultScanMode"
        static let defaultScannerCategory = "settings.defaultScannerCategory"
        static let excludedPatterns = "settings.excludedPatterns"
        static let scanDevCachesOnLaunch = "settings.scanDevCachesOnLaunch"
        static let devCacheMaxAgeDays = "settings.devCacheMaxAgeDays"
        static let includeHiddenFiles = "settings.includeHiddenFiles"
        static let includePackageContents = "settings.includePackageContents"
        static let incrementalScans = "settings.incrementalScans"
        static let minFileSizeMB = "settings.minFileSizeMB"
        static let minFileAgeDays = "settings.minFileAgeDays"
        static let avoidIntensiveWorkOnBattery = "settings.avoidIntensiveWorkOnBattery"
        // Appearance & accessibility
        static let appearance = "settings.appearance"
        static let animationsEnabled = "settings.animationsEnabled"
        // Privacy
        static let redactPaths = "settings.redactPaths"
        // Updates
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let autoDownloadUpdates = "settings.autoDownloadUpdates"
        static let updateChannel = "settings.updateChannel"
    }

    // MARK: - Safety

    /// Preview Mode. ON by default; cleanup can be deliberately disabled by
    /// the user in the results workspace or Settings.
    @Published public var dryRun: Bool {
        didSet { defaults.set(dryRun, forKey: Key.dryRun) }
    }

    @Published public var confirmBeforeCleanup: Bool {
        didSet { defaults.set(confirmBeforeCleanup, forKey: Key.confirmBeforeCleanup) }
    }

    /// Smart-selection: SAFE items are pre-selected in the results workspace.
    @Published public var smartSelection: Bool {
        didSet { defaults.set(smartSelection, forKey: Key.smartSelection) }
    }

    // MARK: - Scanning

    @Published public var largeFileThresholdMB: Double {
        didSet { defaults.set(largeFileThresholdMB, forKey: Key.largeFileThreshold) }
    }

    @Published public var maxScanDepth: Int {
        didSet { defaults.set(maxScanDepth, forKey: Key.maxScanDepth) }
    }

    @Published public var defaultScanMode: String {
        didSet { defaults.set(defaultScanMode, forKey: Key.defaultScanMode) }
    }

    @Published public var defaultScannerCategory: String {
        didSet { defaults.set(defaultScannerCategory, forKey: Key.defaultScannerCategory) }
    }

    @Published public var excludedPatterns: [String] {
        didSet { defaults.set(excludedPatterns, forKey: Key.excludedPatterns) }
    }

    @Published public var scanDevCachesOnLaunch: Bool {
        didSet { defaults.set(scanDevCachesOnLaunch, forKey: Key.scanDevCachesOnLaunch) }
    }

    @Published public var devCacheMaxAgeDays: Int {
        didSet { defaults.set(devCacheMaxAgeDays, forKey: Key.devCacheMaxAgeDays) }
    }

    @Published public var includeHiddenFiles: Bool {
        didSet { defaults.set(includeHiddenFiles, forKey: Key.includeHiddenFiles) }
    }

    @Published public var includePackageContents: Bool {
        didSet { defaults.set(includePackageContents, forKey: Key.includePackageContents) }
    }

    @Published public var incrementalScans: Bool {
        didSet { defaults.set(incrementalScans, forKey: Key.incrementalScans) }
    }

    @Published public var minFileSizeMB: Double {
        didSet { defaults.set(minFileSizeMB, forKey: Key.minFileSizeMB) }
    }

    @Published public var minFileAgeDays: Int {
        didSet { defaults.set(minFileAgeDays, forKey: Key.minFileAgeDays) }
    }

    @Published public var avoidIntensiveWorkOnBattery: Bool {
        didSet { defaults.set(avoidIntensiveWorkOnBattery, forKey: Key.avoidIntensiveWorkOnBattery) }
    }

    // MARK: - Appearance

    @Published public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    @Published public var animationsEnabled: Bool {
        didSet { defaults.set(animationsEnabled, forKey: Key.animationsEnabled) }
    }

    // MARK: - Privacy

    @Published public var redactPaths: Bool {
        didSet { defaults.set(redactPaths, forKey: Key.redactPaths) }
    }

    // MARK: - Updates

    @Published public var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) }
    }

    @Published public var autoDownloadUpdates: Bool {
        didSet { defaults.set(autoDownloadUpdates, forKey: Key.autoDownloadUpdates) }
    }

    @Published public var updateChannel: String {
        didSet { defaults.set(updateChannel, forKey: Key.updateChannel) }
    }

    public let defaults: UserDefaults

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.dryRun = (defaults.object(forKey: Key.dryRun) as? Bool) ?? true
        self.confirmBeforeCleanup = (defaults.object(forKey: Key.confirmBeforeCleanup) as? Bool) ?? true
        self.smartSelection = (defaults.object(forKey: Key.smartSelection) as? Bool) ?? true

        self.largeFileThresholdMB = (defaults.object(forKey: Key.largeFileThreshold) as? Double) ?? 500
        self.maxScanDepth = (defaults.object(forKey: Key.maxScanDepth) as? Int) ?? 6
        self.defaultScanMode = defaults.string(forKey: Key.defaultScanMode) ?? ScanMode.quick.rawValue
        self.defaultScannerCategory = defaults.string(forKey: Key.defaultScannerCategory) ?? "derivedData"
        self.excludedPatterns = (defaults.array(forKey: Key.excludedPatterns) as? [String]) ?? []
        self.scanDevCachesOnLaunch = (defaults.object(forKey: Key.scanDevCachesOnLaunch) as? Bool) ?? true
        self.devCacheMaxAgeDays = (defaults.object(forKey: Key.devCacheMaxAgeDays) as? Int) ?? 90

        self.includeHiddenFiles = (defaults.object(forKey: Key.includeHiddenFiles) as? Bool) ?? false
        self.includePackageContents = (defaults.object(forKey: Key.includePackageContents) as? Bool) ?? false
        self.incrementalScans = (defaults.object(forKey: Key.incrementalScans) as? Bool) ?? true
        self.minFileSizeMB = (defaults.object(forKey: Key.minFileSizeMB) as? Double) ?? 0
        self.minFileAgeDays = (defaults.object(forKey: Key.minFileAgeDays) as? Int) ?? 0
        self.avoidIntensiveWorkOnBattery = (defaults.object(forKey: Key.avoidIntensiveWorkOnBattery) as? Bool) ?? true

        let storedAppearance = defaults.string(forKey: Key.appearance)
        self.appearance = storedAppearance.flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.animationsEnabled = (defaults.object(forKey: Key.animationsEnabled) as? Bool) ?? true

        self.redactPaths = (defaults.object(forKey: Key.redactPaths) as? Bool) ?? false

        self.autoCheckUpdates = (defaults.object(forKey: Key.autoCheckUpdates) as? Bool) ?? true
        self.autoDownloadUpdates = (defaults.object(forKey: Key.autoDownloadUpdates) as? Bool) ?? false
        self.updateChannel = defaults.string(forKey: Key.updateChannel) ?? "stable"
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
        confirmBeforeCleanup = true
        smartSelection = true
        largeFileThresholdMB = 500
        maxScanDepth = 6
        defaultScanMode = ScanMode.quick.rawValue
        defaultScannerCategory = "derivedData"
        excludedPatterns = []
        scanDevCachesOnLaunch = true
        devCacheMaxAgeDays = 90
        includeHiddenFiles = false
        includePackageContents = false
        incrementalScans = true
        minFileSizeMB = 0
        minFileAgeDays = 0
        avoidIntensiveWorkOnBattery = true
        appearance = .system
        animationsEnabled = true
        redactPaths = false
        autoCheckUpdates = true
        autoDownloadUpdates = false
        updateChannel = "stable"
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
