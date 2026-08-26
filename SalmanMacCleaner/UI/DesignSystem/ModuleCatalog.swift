//
//  ModuleCatalog.swift
//  SalmanMacCleaner
//
//  The sidebar information architecture: 20 modules grouped into MAIN,
//  CLEANUP, STORAGE, APPLICATIONS, HEALTH and OTHER. Each module carries its
//  hero-screen copy (benefit + three concrete capabilities) and artwork seed.
//

import SwiftUI

public enum SidebarGroup: String, CaseIterable, Identifiable {
    case main
    case cleanup
    case storage
    case applications
    case health
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .main: return NSLocalizedString("sidebar.group.main", comment: "")
        case .cleanup: return NSLocalizedString("sidebar.group.cleanup", comment: "")
        case .storage: return NSLocalizedString("sidebar.group.storage", comment: "")
        case .applications: return NSLocalizedString("sidebar.group.applications", comment: "")
        case .health: return NSLocalizedString("sidebar.group.health", comment: "")
        case .other: return NSLocalizedString("sidebar.group.other", comment: "")
        }
    }
}

public enum SidebarModule: String, CaseIterable, Identifiable, Codable, Hashable {
    // MAIN
    case smartCare
    case deepScan
    // CLEANUP
    case systemJunk
    case trashBins
    case appLeftovers
    case developerCaches
    // STORAGE
    case spaceLens
    case largeOldFiles
    case duplicates
    case myClutter
    // APPLICATIONS
    case applications
    case uninstaller
    case appUpdater
    case startupItems
    // HEALTH
    case performance
    case securityAudit
    case permissions
    // OTHER
    case myTools
    case activityHistory
    case settings

    public var id: String { rawValue }

    public var group: SidebarGroup {
        switch self {
        case .smartCare, .deepScan: return .main
        case .systemJunk, .trashBins, .appLeftovers, .developerCaches: return .cleanup
        case .spaceLens, .largeOldFiles, .duplicates, .myClutter: return .storage
        case .applications, .uninstaller, .appUpdater, .startupItems: return .applications
        case .performance, .securityAudit, .permissions: return .health
        case .myTools, .activityHistory, .settings: return .other
        }
    }

    public static var ordered: [SidebarModule] {
        [.smartCare, .deepScan,
         .systemJunk, .trashBins, .appLeftovers, .developerCaches,
         .spaceLens, .largeOldFiles, .duplicates, .myClutter,
         .applications, .uninstaller, .appUpdater, .startupItems,
         .performance, .securityAudit, .permissions,
         .myTools, .activityHistory, .settings]
    }

    public var title: String {
        switch self {
        case .smartCare: return NSLocalizedString("module.smart_care", comment: "")
        case .deepScan: return NSLocalizedString("module.deep_scan", comment: "")
        case .systemJunk: return NSLocalizedString("module.system_junk", comment: "")
        case .trashBins: return NSLocalizedString("module.trash_bins", comment: "")
        case .appLeftovers: return NSLocalizedString("module.app_leftovers", comment: "")
        case .developerCaches: return NSLocalizedString("module.dev_caches", comment: "")
        case .spaceLens: return NSLocalizedString("module.space_lens", comment: "")
        case .largeOldFiles: return NSLocalizedString("module.large_old", comment: "")
        case .duplicates: return NSLocalizedString("module.duplicates", comment: "")
        case .myClutter: return NSLocalizedString("module.my_clutter", comment: "")
        case .applications: return NSLocalizedString("module.applications", comment: "")
        case .uninstaller: return NSLocalizedString("module.uninstaller", comment: "")
        case .appUpdater: return NSLocalizedString("module.app_updater", comment: "")
        case .startupItems: return NSLocalizedString("module.startup", comment: "")
        case .performance: return NSLocalizedString("module.performance", comment: "")
        case .securityAudit: return NSLocalizedString("module.security", comment: "")
        case .permissions: return NSLocalizedString("module.permissions", comment: "")
        case .myTools: return NSLocalizedString("module.my_tools", comment: "")
        case .activityHistory: return NSLocalizedString("module.activity", comment: "")
        case .settings: return NSLocalizedString("module.settings", comment: "")
        }
    }

    public var systemImage: String {
        switch self {
        case .smartCare: return "wand.and.stars"
        case .deepScan: return "viewfinder"
        case .systemJunk: return "sparkles"
        case .trashBins: return "trash"
        case .appLeftovers: return "square.stack.3d.up.slash"
        case .developerCaches: return "hammer"
        case .spaceLens: return "circle.hexagongrid"
        case .largeOldFiles: return "externaldrive.badge.timemachine"
        case .duplicates: return "doc.on.doc"
        case .myClutter: return "shippingbox"
        case .applications: return "square.grid.2x2"
        case .uninstaller: return "arrow.uturn.down.square"
        case .appUpdater: return "arrow.down.circle"
        case .startupItems: return "power"
        case .performance: return "gauge.with.dots.needle.50percent"
        case .securityAudit: return "checkmark.shield"
        case .permissions: return "lock.shield"
        case .myTools: return "square.grid.3x3.square"
        case .activityHistory: return "clock.arrow.circlepath"
        case .settings: return "gearshape.2"
        }
    }

    public var benefit: String {
        switch self {
        case .smartCare: return NSLocalizedString("hero.smart_care.benefit", comment: "")
        case .deepScan: return NSLocalizedString("hero.deep_scan.benefit", comment: "")
        case .systemJunk: return NSLocalizedString("hero.system_junk.benefit", comment: "")
        case .trashBins: return NSLocalizedString("hero.trash_bins.benefit", comment: "")
        case .appLeftovers: return NSLocalizedString("hero.app_leftovers.benefit", comment: "")
        case .developerCaches: return NSLocalizedString("hero.dev_caches.benefit", comment: "")
        case .spaceLens: return NSLocalizedString("hero.space_lens.benefit", comment: "")
        case .largeOldFiles: return NSLocalizedString("hero.large_old.benefit", comment: "")
        case .duplicates: return NSLocalizedString("hero.duplicates.benefit", comment: "")
        case .myClutter: return NSLocalizedString("hero.my_clutter.benefit", comment: "")
        case .applications: return NSLocalizedString("hero.applications.benefit", comment: "")
        case .uninstaller: return NSLocalizedString("hero.uninstaller.benefit", comment: "")
        case .appUpdater: return NSLocalizedString("hero.app_updater.benefit", comment: "")
        case .startupItems: return NSLocalizedString("hero.startup.benefit", comment: "")
        case .performance: return NSLocalizedString("hero.performance.benefit", comment: "")
        case .securityAudit: return NSLocalizedString("hero.security.benefit", comment: "")
        case .permissions: return NSLocalizedString("hero.permissions.benefit", comment: "")
        case .myTools: return NSLocalizedString("hero.my_tools.benefit", comment: "")
        case .activityHistory: return NSLocalizedString("hero.activity.benefit", comment: "")
        case .settings: return NSLocalizedString("hero.settings.benefit", comment: "")
        }
    }

    /// Three concrete capability points per module.
    public var capabilities: [(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey)] {
        switch self {
        case .smartCare:
            return [
                ("sparkles", "hero.smart_care.c1.t", "hero.smart_care.c1.d"),
                ("internaldrive", "hero.smart_care.c2.t", "hero.smart_care.c2.d"),
                ("checkmark.shield", "hero.smart_care.c3.t", "hero.smart_care.c3.d")
            ]
        case .deepScan:
            return [
                ("viewfinder", "hero.deep_scan.c1.t", "hero.deep_scan.c1.d"),
                ("eye.slash", "hero.deep_scan.c2.t", "hero.deep_scan.c2.d"),
                ("square.stack.3d.up", "hero.deep_scan.c3.t", "hero.deep_scan.c3.d")
            ]
        case .systemJunk:
            return [
                ("folder.badge.gearshape", "hero.system_junk.c1.t", "hero.system_junk.c1.d"),
                ("doc.text.magnifyingglass", "hero.system_junk.c2.t", "hero.system_junk.c2.d"),
                ("trash", "hero.system_junk.c3.t", "hero.system_junk.c3.d")
            ]
        case .trashBins:
            return [
                ("trash", "hero.trash_bins.c1.t", "hero.trash_bins.c1.d"),
                ("arrow.uturn.backward", "hero.trash_bins.c2.t", "hero.trash_bins.c2.d"),
                ("externaldrive", "hero.trash_bins.c3.t", "hero.trash_bins.c3.d")
            ]
        case .appLeftovers:
            return [
                ("app.badge", "hero.app_leftovers.c1.t", "hero.app_leftovers.c1.d"),
                ("square.stack.3d.up.slash", "hero.app_leftovers.c2.t", "hero.app_leftovers.c2.d"),
                ("checkmark.seal", "hero.app_leftovers.c3.t", "hero.app_leftovers.c3.d")
            ]
        case .developerCaches:
            return [
                ("hammer", "hero.dev_caches.c1.t", "hero.dev_caches.c1.d"),
                ("arrow.triangle.2.circlepath", "hero.dev_caches.c2.t", "hero.dev_caches.c2.d"),
                ("shippingbox", "hero.dev_caches.c3.t", "hero.dev_caches.c3.d")
            ]
        case .spaceLens:
            return [
                ("circle.hexagongrid", "hero.space_lens.c1.t", "hero.space_lens.c1.d"),
                ("eye", "hero.space_lens.c2.t", "hero.space_lens.c2.d"),
                ("folder", "hero.space_lens.c3.t", "hero.space_lens.c3.d")
            ]
        case .largeOldFiles:
            return [
                ("externaldrive.badge.timemachine", "hero.large_old.c1.t", "hero.large_old.c1.d"),
                ("hourglass", "hero.large_old.c2.t", "hero.large_old.c2.d"),
                ("arrow.down.to.line", "hero.large_old.c3.t", "hero.large_old.c3.d")
            ]
        case .duplicates:
            return [
                ("doc.on.doc", "hero.duplicates.c1.t", "hero.duplicates.c1.d"),
                ("waveform.path.ecg", "hero.duplicates.c2.t", "hero.duplicates.c2.d"),
                ("link", "hero.duplicates.c3.t", "hero.duplicates.c3.d")
            ]
        case .myClutter:
            return [
                ("shippingbox", "hero.my_clutter.c1.t", "hero.my_clutter.c1.d"),
                ("folder.badge.questionmark", "hero.my_clutter.c2.t", "hero.my_clutter.c2.d"),
                ("checkmark.circle", "hero.my_clutter.c3.t", "hero.my_clutter.c3.d")
            ]
        case .applications:
            return [
                ("square.grid.2x2", "hero.applications.c1.t", "hero.applications.c1.d"),
                ("info.circle", "hero.applications.c2.t", "hero.applications.c2.d"),
                ("cpu", "hero.applications.c3.t", "hero.applications.c3.d")
            ]
        case .uninstaller:
            return [
                ("app.badge", "hero.uninstaller.c1.t", "hero.uninstaller.c1.d"),
                ("square.3.layers.3d", "hero.uninstaller.c2.t", "hero.uninstaller.c2.d"),
                ("lock.shield", "hero.uninstaller.c3.t", "hero.uninstaller.c3.d")
            ]
        case .appUpdater:
            return [
                ("arrow.down.circle", "hero.app_updater.c1.t", "hero.app_updater.c1.d"),
                ("checkmark.seal", "hero.app_updater.c2.t", "hero.app_updater.c2.d"),
                ("info.circle", "hero.app_updater.c3.t", "hero.app_updater.c3.d")
            ]
        case .startupItems:
            return [
                ("power", "hero.startup.c1.t", "hero.startup.c1.d"),
                ("gearshape.2", "hero.startup.c2.t", "hero.startup.c2.d"),
                ("exclamationmark.triangle", "hero.startup.c3.t", "hero.startup.c3.d")
            ]
        case .performance:
            return [
                ("gauge.with.dots.needle.50percent", "hero.performance.c1.t", "hero.performance.c1.d"),
                ("memorychip", "hero.performance.c2.t", "hero.performance.c2.d"),
                ("lightbulb", "hero.performance.c3.t", "hero.performance.c3.d")
            ]
        case .securityAudit:
            return [
                ("checkmark.shield", "hero.security.c1.t", "hero.security.c1.d"),
                ("doc.badge.gearshape", "hero.security.c2.t", "hero.security.c2.d"),
                ("link.badge.plus", "hero.security.c3.t", "hero.security.c3.d")
            ]
        case .permissions:
            return [
                ("lock.shield", "hero.permissions.c1.t", "hero.permissions.c1.d"),
                ("hand.raised", "hero.permissions.c2.t", "hero.permissions.c2.d"),
                ("slider.horizontal.3", "hero.permissions.c3.t", "hero.permissions.c3.d")
            ]
        case .myTools:
            return [
                ("square.grid.3x3.square", "hero.my_tools.c1.t", "hero.my_tools.c1.d"),
                ("magnifyingglass", "hero.my_tools.c2.t", "hero.my_tools.c2.d"),
                ("keyboard", "hero.my_tools.c3.t", "hero.my_tools.c3.d")
            ]
        case .activityHistory:
            return [
                ("clock.arrow.circlepath", "hero.activity.c1.t", "hero.activity.c1.d"),
                ("doc.text", "hero.activity.c2.t", "hero.activity.c2.d"),
                ("square.and.arrow.up", "hero.activity.c3.t", "hero.activity.c3.d")
            ]
        case .settings:
            return [
                ("gearshape.2", "hero.settings.c1.t", "hero.settings.c1.d"),
                ("slider.horizontal.3", "hero.settings.c2.t", "hero.settings.c2.d"),
                ("lock.shield", "hero.settings.c3.t", "hero.settings.c3.d")
            ]
        }
    }

    /// Deterministic artwork/illumination seed.
    public var artworkSeed: Int {
        switch self {
        case .smartCare: return 1
        case .deepScan: return 2
        case .systemJunk: return 3
        case .trashBins: return 4
        case .appLeftovers: return 5
        case .developerCaches: return 6
        case .spaceLens: return 7
        case .largeOldFiles: return 8
        case .duplicates: return 9
        case .myClutter: return 10
        case .applications: return 11
        case .uninstaller: return 12
        case .appUpdater: return 13
        case .startupItems: return 14
        case .performance: return 15
        case .securityAudit: return 16
        case .permissions: return 17
        case .myTools: return 18
        case .activityHistory: return 19
        case .settings: return 20
        }
    }

    /// Primary action title shown on the hero.
    public var primaryActionTitle: String {
        switch self {
        case .smartCare: return NSLocalizedString("hero.action.scan", comment: "")
        case .deepScan: return NSLocalizedString("hero.action.start_deep_scan", comment: "")
        case .systemJunk: return NSLocalizedString("hero.action.scan_junk", comment: "")
        case .trashBins: return NSLocalizedString("hero.action.scan_trash", comment: "")
        case .appLeftovers: return NSLocalizedString("hero.action.find_leftovers", comment: "")
        case .developerCaches: return NSLocalizedString("hero.action.scan_caches", comment: "")
        case .spaceLens: return NSLocalizedString("hero.action.scan_volume", comment: "")
        case .largeOldFiles: return NSLocalizedString("hero.action.scan_large_old", comment: "")
        case .duplicates: return NSLocalizedString("hero.action.find_duplicates", comment: "")
        case .myClutter: return NSLocalizedString("hero.action.review_clutter", comment: "")
        case .applications: return NSLocalizedString("hero.action.scan_apps", comment: "")
        case .uninstaller: return NSLocalizedString("hero.action.scan_apps", comment: "")
        case .appUpdater: return NSLocalizedString("hero.action.check_now", comment: "")
        case .startupItems: return NSLocalizedString("hero.action.review_startup", comment: "")
        case .performance: return NSLocalizedString("hero.action.review_performance", comment: "")
        case .securityAudit: return NSLocalizedString("hero.action.run_audit", comment: "")
        case .permissions: return NSLocalizedString("hero.action.open_permissions", comment: "")
        case .myTools: return NSLocalizedString("hero.action.open_tools", comment: "")
        case .activityHistory: return NSLocalizedString("hero.action.view_history", comment: "")
        case .settings: return NSLocalizedString("hero.action.open_settings", comment: "")
        }
    }
}
