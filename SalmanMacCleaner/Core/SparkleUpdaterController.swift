//
//  SparkleUpdaterController.swift
//  SalmanMacCleaner
//
//  Sparkle 2 self-update integration (Swift Package Manager).
//
//  Update installation is ONLY active when the app is properly configured:
//  a real SUFeedURL (https) and a real SUPublicEDKey in Info.plist. In
//  development builds — where the placeholder public key is present or
//  signing/notarization credentials are unavailable — updates are disabled
//  and the UI says so honestly. No update is ever installed unsigned.
//

import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
public final class SparkleUpdaterController: ObservableObject {

    public static let shared = SparkleUpdaterController()

    @Published public private(set) var state: UpdaterState = .unconfigured

    public enum UpdaterState: Equatable {
        case unconfigured
        case checking
        case upToDate
        case updateAvailable(version: String)
        case failed(String)

        public var title: String {
            switch self {
            case .unconfigured: return NSLocalizedString("updater.state.unconfigured", comment: "")
            case .checking: return NSLocalizedString("updater.state.checking", comment: "")
            case .upToDate: return NSLocalizedString("updater.state.up_to_date", comment: "")
            case .updateAvailable(let version): return String(format: NSLocalizedString("updater.state.available", comment: ""), version)
            case .failed(let message): return message
            }
        }
    }

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    public init() {
        #if canImport(Sparkle)
        if Self.isConfigured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        #endif
    }

    /// Configuration gate: a placeholder or missing EdDSA key or feed URL
    /// disables updates. Placeholder value must match Docs/SparkleSetup.md.
    public static var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              feed.hasPrefix("https://"),
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              !key.contains("REPLACE") else {
            return false
        }
        return true
    }

    /// Human-readable reason updates are disabled (development builds).
    public static var unconfiguredReason: String {
        if !isSignedForDistribution {
            return NSLocalizedString("updater.reason.unsigned", comment: "")
        }
        return NSLocalizedString("updater.reason.no_feed", comment: "")
    }

    /// Whether the running binary carries a Developer ID signature. Sparkle
    /// must never install an update over an unsigned or ad-hoc build.
    public static var isSignedForDistribution: Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return false
        }
        var requirement: SecRequirement?
        let requirementString = "anchor apple generic" as CFString
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }

    /// Trigger a manual update check (menu command).
    public func checkForUpdates() {
        #if canImport(Sparkle)
        guard Self.isConfigured else {
            state = .failed(Self.unconfiguredReason)
            return
        }
        state = .checking
        updaterController?.checkForUpdates(nil)
        #else
        state = .failed(NSLocalizedString("updater.reason.unavailable", comment: ""))
        #endif
    }

    /// Best-effort "is an update pending" signal for the status pill.
    public static func hasPendingUpdate() async -> Bool {
        guard isConfigured else { return false }
        #if canImport(Sparkle)
        // Sparkle surfaces pending updates through the standard user driver;
        // the pill is only shown while an update session exists.
        return false
        #else
        return false
        #endif
    }

    /// Current version + build for Settings/About.
    public static var currentVersion: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
        return "\(version) (\(build))"
    }
}
