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
import Security
#if canImport(Sparkle)
import Sparkle
#endif

public struct UpdaterAudit: Equatable {
    public let installedVersion: String
    public let availableVersion: String?
    public let releaseSource: String
    public let architecture: String
    public let signatureStatus: String
    public let notarizationStatus: String
    public let notes: String
    public let releaseDate: Date?

    public init(installedVersion: String,
                availableVersion: String? = nil,
                releaseSource: String,
                architecture: String,
                signatureStatus: String,
                notarizationStatus: String,
                notes: String,
                releaseDate: Date? = nil) {
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.releaseSource = releaseSource
        self.architecture = architecture
        self.signatureStatus = signatureStatus
        self.notarizationStatus = notarizationStatus
        self.notes = notes
        self.releaseDate = releaseDate
    }
}

@MainActor
public final class SparkleUpdaterController: ObservableObject {

    public static let shared = SparkleUpdaterController()

    @Published public private(set) var state: UpdaterState = .unconfigured
    /// Set only after Sparkle validates a newer appcast item. A downloaded
    /// item is still not called installed; installation remains Sparkle's
    /// verified update cycle.
    @Published public private(set) var availableVersion: String?

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
    private var sparkleDelegate: SparkleDelegate?

    private final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
        weak var owner: SparkleUpdaterController?

        func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            let version = item.displayVersionString.isEmpty ? item.versionString : item.displayVersionString
            Task { @MainActor [weak owner] in
                owner?.availableVersion = version
                owner?.state = .updateAvailable(version: version)
            }
        }

        func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error?) {
            Task { @MainActor [weak owner] in
                owner?.availableVersion = nil
                owner?.state = error.map { .failed($0.localizedDescription) } ?? .upToDate
            }
        }

        func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
            guard let error else { return }
            Task { @MainActor [weak owner] in
                owner?.state = .failed(error.localizedDescription)
            }
        }
    }
    #endif

    public init() {
        #if canImport(Sparkle)
        state = Self.isConfigured ? .checking : .unconfigured
        let delegate = SparkleDelegate()
        self.sparkleDelegate = delegate
        if Self.isConfigured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: delegate,
                userDriverDelegate: nil
            )
        }
        delegate.owner = self
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
        availableVersion = nil
        updaterController?.checkForUpdates(nil)
        #else
        state = .failed(NSLocalizedString("updater.reason.unavailable", comment: ""))
        #endif
    }

    /// Best-effort "is an update pending" signal for the status pill.
    public static func hasPendingUpdate() async -> Bool {
        guard isConfigured else { return false }
        return await MainActor.run { shared.availableVersion != nil }
    }

    public static var currentAudit: UpdaterAudit {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
        let installed = "\(version) (\(build))"
        let executable = Bundle.main.executableURL?.path
        let architectures = executable.map { MachOArchitecture.architectures(ofBinaryAt: $0) } ?? []
        let signature = isSignedForDistribution
            ? NSLocalizedString("updater.signature.valid", comment: "")
            : NSLocalizedString("updater.signature.not_verified", comment: "")
        return UpdaterAudit(
            installedVersion: installed,
            availableVersion: nil,
            releaseSource: isConfigured
                ? NSLocalizedString("updater.source.sparkle", comment: "")
                : NSLocalizedString("updater.source.official_page", comment: ""),
            architecture: architectures.isEmpty ? NSLocalizedString("updater.architecture.unknown", comment: "") : architectures.joined(separator: ", "),
            signatureStatus: signature,
            notarizationStatus: NSLocalizedString("updater.notarization.inspect_on_release", comment: ""),
            notes: isConfigured ? NSLocalizedString("updater.notes.feed_check", comment: "") : unconfiguredReason,
            releaseDate: nil
        )
    }

    /// Current version + build for Settings/About. Both values come from the
    /// bundle metadata; the source fallback is deliberately not a release id.
    public static var currentVersion: String {
        currentAudit.installedVersion
    }
}
