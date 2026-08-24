//
//  AppState.swift
//  SalmanMacCleaner
//
//  Central observable state for the app: current section, scan/cleanup phase,
//  progress and cancellation. Background work itself is coordinated by
//  ScanCoordinator; AppState mirrors its phase into the shared toolbar.
//

import Foundation
import Combine
import SwiftUI

/// Root section of the sidebar.
public enum AppSection: String, CaseIterable, Identifiable, Codable {
    case dashboard
    case largeFiles
    case duplicates
    case developerCaches
    case startupItems
    case uninstaller
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return NSLocalizedString("nav.dashboard", comment: "")
        case .largeFiles: return NSLocalizedString("nav.large_files", comment: "")
        case .duplicates: return NSLocalizedString("nav.duplicates", comment: "")
        case .developerCaches: return NSLocalizedString("nav.dev_caches", comment: "")
        case .startupItems: return NSLocalizedString("nav.startup_items", comment: "")
        case .uninstaller: return NSLocalizedString("nav.uninstaller", comment: "")
        case .settings: return NSLocalizedString("nav.settings", comment: "")
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .largeFiles: return "externaldrive.fill.badge.timemachine"
        case .duplicates: return "doc.on.doc.fill"
        case .developerCaches: return "hammer.fill"
        case .startupItems: return "power"
        case .uninstaller: return "trash"
        case .settings: return "gearshape.fill"
        }
    }

    /// The permission badge shown in the sidebar, if any.
    public var permissionBadge: String? {
        switch self {
        case .startupItems: return NSLocalizedString("badge.read_only", comment: "")
        case .developerCaches: return NSLocalizedString("badge.preview_first", comment: "")
        default: return nil
        }
    }
}

/// Phase of a background operation, surfaced in the shared toolbar.
public enum ActivityPhase: Equatable {
    case idle
    case scanning(detail: String)
    case hashing(detail: String)
    case cleaning(detail: String)
    case finished(summary: String)
    case failed(message: String)

    /// Whether the stop button should be offered for this phase.
    public var isCancellable: Bool {
        switch self {
        case .scanning, .hashing: return true
        case .idle, .cleaning, .finished, .failed: return false
        }
    }
}

@MainActor
public final class AppState: ObservableObject {

    @Published public var section: AppSection = .dashboard
    @Published public var activityPhase: ActivityPhase = .idle
    @Published public var progress: Double = 0
    @Published public var isBusy: Bool = false
    @Published public var lastError: String?
    @Published public var lastSuccessMessage: String?
    @Published public var sidebarSearchText: String = ""
    @Published public var folderPickerActive = false
    @Published public var settings: SettingsStore
    @Published public var history: HistoryStore

    public init(settings: SettingsStore = SettingsStore(), history: HistoryStore = HistoryStore()) {
        self.settings = settings
        self.history = history
    }

    // MARK: - Activity control

    public func beginActivity(_ phase: ActivityPhase) {
        activityPhase = phase
        isBusy = true
        progress = 0
        lastError = nil
        lastSuccessMessage = nil
    }

    public func updateProgress(_ value: Double, detail: String? = nil) {
        progress = min(max(value, 0), 1)
        guard let detail else { return }
        switch activityPhase {
        case .scanning:
            activityPhase = .scanning(detail: detail)
        case .hashing:
            activityPhase = .hashing(detail: detail)
        case .cleaning:
            activityPhase = .cleaning(detail: detail)
        case .idle, .finished, .failed:
            break
        }
    }

    public func endActivity(message: String? = nil, error: String? = nil) {
        if let error {
            activityPhase = .failed(message: error)
            lastError = error
            progress = 0
        } else if let message {
            activityPhase = .finished(summary: message)
            lastSuccessMessage = message
            progress = 1
        } else {
            activityPhase = .idle
            progress = 0
        }
        isBusy = false
    }

    /// Cancel the currently running scan (delegates to the coordinator).
    public func cancelCurrentScan() {
        ScanCoordinator.shared.cancel()
        if case .scanning = activityPhase {
            activityPhase = .idle
            isBusy = false
            progress = 0
        } else if case .hashing = activityPhase {
            activityPhase = .idle
            isBusy = false
            progress = 0
        }
    }
}
