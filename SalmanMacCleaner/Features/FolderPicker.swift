//
//  FolderPicker.swift
//  SalmanMacCleaner
//
//  Explicit folder selection. Large-file and duplicate scans only ever run on
//  folders the user picked — never on Desktop/Documents/Downloads/… by default.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
public final class FolderPicker {

    /// Present an NSOpenPanel (directory-only) and return the chosen URL.
    /// Returns nil when the user cancels.
    public static func chooseFolder(
        message: String? = nil,
        prompt: String? = nil,
        canChooseFiles: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = prompt ?? NSLocalizedString("folder.picker.choose", comment: "")
        panel.message = message ?? NSLocalizedString("folder.picker.message", comment: "")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Validate a user-picked URL for scanning. Refuses root-level protected
    /// locations, other-user folders, and the home directory itself (too broad).
    public static func validatePickedFolder(_ url: URL) -> Result<URL, Error> {
        let path = url.standardizedFileURL.path

        guard PathSafety.isInsideUserHome(path) else {
            return .failure(FolderValidationError.outsideHome)
        }
        guard !PathSafety.isProtectedRootLocation(path) else {
            return .failure(FolderValidationError.protectedLocation)
        }
        guard path != PathSafety.userHome.path else {
            return .failure(FolderValidationError.homeRootTooBroad)
        }
        guard PathSafety.isOwnedByCurrentUser(path) else {
            return .failure(FolderValidationError.notOwned)
        }
        guard !PathSafety.isAppBundle(path) else {
            return .failure(FolderValidationError.appBundle)
        }
        guard PathSafety.kind(of: path) == .directory else {
            return .failure(FolderValidationError.notDirectory)
        }
        return .success(URL(fileURLWithPath: path, isDirectory: true))
    }
}

public enum FolderValidationError: LocalizedError, Equatable {
    case outsideHome
    case protectedLocation
    case homeRootTooBroad
    case notOwned
    case appBundle
    case notDirectory

    public var errorDescription: String? {
        switch self {
        case .outsideHome: return NSLocalizedString("folder.error.outside_home", comment: "")
        case .protectedLocation: return NSLocalizedString("folder.error.protected", comment: "")
        case .homeRootTooBroad: return NSLocalizedString("folder.error.home_root", comment: "")
        case .notOwned: return NSLocalizedString("folder.error.not_owned", comment: "")
        case .appBundle: return NSLocalizedString("folder.error.app_bundle", comment: "")
        case .notDirectory: return NSLocalizedString("folder.error.not_directory", comment: "")
        }
    }
}

/// SwiftUI wrapper used in sheets: presents NSOpenPanel and calls back with
/// the picked URL (nil on cancel).
@MainActor
public struct FolderPickerView: View {
    let message: LocalizedStringKey
    let onPick: (URL?) -> Void

    public init(message: LocalizedStringKey, onPick: @escaping (URL?) -> Void) {
        self.message = message
        self.onPick = onPick
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.callout)
                .frame(maxWidth: 360)
            Button {
                let url = FolderPicker.chooseFolder()
                onPick(url)
            } label: {
                Label(NSLocalizedString("folder.picker.choose", comment: ""), systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Button(NSLocalizedString("common.cancel", comment: "")) {
                onPick(nil)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 340, minHeight: 200)
    }
}
