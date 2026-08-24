//
//  StartupManager.swift
//  SalmanMacCleaner
//
//  Read-only discovery of login items, launch agents and launch daemons.
//  Version 1 intentionally does NOT modify startup items — the UI is
//  explicitly read-only.
//

import Foundation
import CoreServices
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

public enum StartupManager {

    /// Whether the modern login-item API is available (macOS 13+). It is used
    /// only to *read* the app's own status — never to change anything.
    public static var canReadModernLoginItems: Bool {
        if #available(macOS 13.0, *) {
            _ = SMAppService.mainApp.status
            return true
        }
        return false
    }

    /// Gather all startup items the app is able to see without elevated
    /// privileges. Launch agents are discovered from the standard LaunchAgents
    /// folders (user + per-user system location); login items come from the
    /// legacy shared list; daemons are listed from the system folder when
    /// readable (read-only).
    public static func discover() -> [StartupItem] {
        var items: [StartupItem] = []

        items.append(contentsOf: discoverUserLaunchAgents())
        items.append(contentsOf: discoverLoginItems())
        items.append(contentsOf: discoverSystemDaemons())

        items.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return items
    }

    // MARK: - Launch agents

    public static func discoverUserLaunchAgents() -> [StartupItem] {
        let home = PathSafety.userHome.path
        let candidateFolders = [
            home + "/Library/LaunchAgents",
            "/Library/LaunchAgents"   // read-only listing; entries are shown but never modified
        ]
        var items: [StartupItem] = []

        for folder in candidateFolders {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "plist" {
                let path = url.path
                let name = (path as NSString).lastPathComponent
                let label = launchAgentLabel(at: path) ?? name
                let detail = String(format: NSLocalizedString("startup.detail.agent", comment: ""), folder)
                items.append(StartupItem(
                    name: label,
                    path: path,
                    source: folder.hasPrefix(home) ? .launchAgent : .launchDaemon,
                    detail: detail
                ))
            }
        }
        return items
    }

    /// Parse a launchd plist's Label field without executing anything.
    public static func launchAgentLabel(at path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            return nil
        }
        return dict["Label"] as? String
    }

    // MARK: - Login items

    public static func discoverLoginItems() -> [StartupItem] {
        guard let listRef = LSSharedFileListCreate(
            nil,
            kLSSharedFileListSessionLoginItems.takeUnretainedValue(),
            nil
        ) else {
            return []
        }
        let loginItems = listRef.takeRetainedValue()
        guard let snapshot = LSSharedFileListCopySnapshot(loginItems, nil)?.takeRetainedValue() else {
            return []
        }

        var result: [StartupItem] = []
        if let typedItems = snapshot as NSArray as? [LSSharedFileListItem] {
            for item in typedItems {
                guard let url = LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() else { continue }
                let path = (url as URL).path
                let name = (path as NSString).lastPathComponent
                result.append(StartupItem(
                    name: name,
                    path: path,
                    source: .loginItem,
                    detail: NSLocalizedString("startup.detail.login_item", comment: "")
                ))
            }
        }
        return result
    }

    // MARK: - System daemons (read-only)

    public static func discoverSystemDaemons() -> [StartupItem] {
        var items: [StartupItem] = []
        let daemonFolders = ["/Library/LaunchDaemons", "/System/Library/LaunchDaemons"]
        for folder in daemonFolders {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "plist" {
                let path = url.path
                let name = (path as NSString).lastPathComponent
                let label = launchAgentLabel(at: path) ?? name
                items.append(StartupItem(
                    name: label,
                    path: path,
                    source: .launchDaemon,
                    detail: NSLocalizedString("startup.detail.read_only", comment: "")
                ))
            }
        }
        return items
    }

    // MARK: - Policy

    /// Version 1 is read-only: no startup item may be modified.
    public static var modificationsAllowed: Bool { false }

    /// Human-readable explanation shown in the UI.
    public static var readOnlyExplanation: String {
        NSLocalizedString("startup.read_only.explanation", comment: "")
    }
}
