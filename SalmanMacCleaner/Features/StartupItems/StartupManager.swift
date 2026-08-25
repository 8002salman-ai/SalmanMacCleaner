//
//  StartupManager.swift
//  SalmanMacCleaner
//
//  Startup & Background Items inventory using public APIs (SMAppService) and
//  supported launch-agent locations. Launch daemons are shown read-only.
//  No deprecated LSSharedFileList APIs are used. Version 1 of this module
//  never disables or removes anything automatically.
//

import Foundation
import ServiceManagement

public enum StartupItemSource: String, CaseIterable, Identifiable {
    case loginItems
    case launchAgents
    case launchDaemons

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .loginItems: return NSLocalizedString("startup.source.login_items", comment: "")
        case .launchAgents: return NSLocalizedString("startup.source.agents", comment: "")
        case .launchDaemons: return NSLocalizedString("startup.source.daemons", comment: "")
        }
    }
}

public struct StartupItemDetail: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var path: String
    public var source: StartupItemSource
    public var executable: String?
    public var owningApp: String?
    public var isBroken: Bool
    public var isEnabled: Bool?
    public var detail: String

    public init(id: UUID = UUID(),
                name: String,
                path: String,
                source: StartupItemSource,
                executable: String?,
                owningApp: String?,
                isBroken: Bool,
                isEnabled: Bool?,
                detail: String) {
        self.id = id
        self.name = name
        self.path = path
        self.source = source
        self.executable = executable
        self.owningApp = owningApp
        self.isBroken = isBroken
        self.isEnabled = isEnabled
        self.detail = detail
    }
}

public enum StartupManager {

    /// Whether this app currently registers itself to launch at login
    /// (public SMAppService API — read-only usage here).
    public static var ownLoginItemStatus: SMAppService.Status? {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status
        }
        return nil
    }

    /// Gather all startup/background items the app can see without elevated
    /// privileges. Never modifies anything.
    public static func discover() -> [StartupItemDetail] {
        var items: [StartupItemDetail] = []
        items.append(contentsOf: discoverLaunchAgents(folder: PathSafety.userHome.path + "/Library/LaunchAgents", source: .launchAgents, daemon: false))
        items.append(contentsOf: discoverLaunchAgents(folder: "/Library/LaunchAgents", source: .launchDaemons, daemon: true))
        items.append(contentsOf: discoverLaunchAgents(folder: "/System/Library/LaunchAgents", source: .launchDaemons, daemon: true))
        items.append(contentsOf: discoverLaunchAgents(folder: "/Library/LaunchDaemons", source: .launchDaemons, daemon: true))
        items.append(contentsOf: discoverLaunchAgents(folder: "/System/Library/LaunchDaemons", source: .launchDaemons, daemon: true))

        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return items
    }

    /// Parse launchd plists from a folder: Label, Program/ProgramArguments,
    /// disabled flag, broken-reference detection.
    public static func discoverLaunchAgents(folder: String, source: StartupItemSource, daemon: Bool) -> [StartupItemDetail] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [StartupItemDetail] = []
        for url in contents where url.pathExtension == "plist" {
            guard let plist = launchdPlist(at: url.path) else { continue }
            let label = (plist["Label"] as? String) ?? url.lastPathComponent

            var executable: String?
            if let program = plist["Program"] as? String {
                executable = program
            } else if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first {
                executable = first
            }

            let isBroken: Bool
            if let executable, executable.hasPrefix("/") {
                isBroken = !FileManager.default.fileExists(atPath: executable)
                    && !FileManager.default.fileExists(atPath: expandTilde(executable))
            } else {
                // Relative binaries are resolved by launchd PATH — treat as
                // unknown, not broken.
                isBroken = false
            }

            let isEnabled: Bool? = plist["Disabled"] as? Bool

            items.append(StartupItemDetail(
                name: label,
                path: url.path,
                source: source,
                executable: executable,
                owningApp: plist["BundleProgram"] as? String,
                isBroken: isBroken,
                isEnabled: isEnabled.map { !$0 },
                detail: daemon
                    ? NSLocalizedString("startup.detail.daemon", comment: "")
                    : NSLocalizedString("startup.detail.agent", comment: "")
            ))
        }
        return items
    }

    /// Read a launchd plist (data only — never executed).
    public static func launchdPlist(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Parse a launchd plist's Label field without executing anything.
    public static func launchAgentLabel(at path: String) -> String? {
        launchdPlist(at: path)?["Label"] as? String
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst())
    }

    // MARK: - Policy

    /// Version 1 never modifies startup/background items automatically.
    public static var modificationsAllowed: Bool { false }

    /// Human-readable explanation shown in the UI.
    public static var readOnlyExplanation: String {
        NSLocalizedString("startup.read_only.explanation", comment: "")
    }
}
