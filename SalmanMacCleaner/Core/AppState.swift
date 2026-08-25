//
//  AppState.swift
//  SalmanMacCleaner
//
//  Central observable state: current module, activity phase, progress,
//  settings, session history and ignore list.
//

import Foundation
import Combine
import SwiftUI

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
        case .scanning, .hashing, .cleaning: return true
        case .idle, .finished, .failed: return false
        }
    }
}

@MainActor
public final class AppState: ObservableObject {

    @Published public var module: SidebarModule = .smartCare
    @Published public var activityPhase: ActivityPhase = .idle
    @Published public var progress: Double = 0
    @Published public var isBusy: Bool = false
    @Published public var lastError: String?
    @Published public var lastSuccessMessage: String?
    @Published public var settings: SettingsStore
    public let sessionStore: ScanSessionStore
    public let ignoreList: IgnoreListStore
    public let history: HistoryStore
    /// The most recently finished scan outcome (for the results workspace).
    @Published public var lastOutcome: ScanOutcome?
    /// Monotonic cancellation signal for feature-local scanners that do not
    /// use ScanCoordinator. This keeps the shared toolbar stop control honest.
    @Published public private(set) var cancellationGeneration = UUID()

    public init(settings: SettingsStore? = nil,
                sessionStore: ScanSessionStore? = nil,
                ignoreList: IgnoreListStore? = nil,
                history: HistoryStore? = nil) {
        self.settings = settings ?? SettingsStore()
        self.sessionStore = sessionStore ?? ScanSessionStore()
        self.ignoreList = ignoreList ?? IgnoreListStore()
        self.history = history ?? HistoryStore()
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
        cancellationGeneration = UUID()
        DeepScanCoordinator.shared.cancel()
        ScanCoordinator.shared.cancel()
        if case .scanning = activityPhase {
            activityPhase = .idle
            isBusy = false
            progress = 0
        } else if case .hashing = activityPhase {
            activityPhase = .idle
            isBusy = false
            progress = 0
        } else if case .cleaning = activityPhase {
            CleanupEngine.shared.cancel()
            CleanupExecutor.shared.cancel()
            // Keep the activity visible until the executor returns its exact
            // partial result; it will transition to finished/idle itself.
        }
    }
}
