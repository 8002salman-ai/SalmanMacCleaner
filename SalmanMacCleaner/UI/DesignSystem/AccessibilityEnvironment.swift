//
//  AccessibilityEnvironment.swift
//  SalmanMacCleaner
//
//  Observes macOS accessibility settings (Reduce Motion, Reduce
//  Transparency, Increase Contrast, Differentiate Without Color) and exposes
//  them to SwiftUI so motion and material choices degrade gracefully.
//

import SwiftUI
import AppKit
import Combine

@MainActor
public final class AccessibilityEnvironment: ObservableObject {

    public static let shared = AccessibilityEnvironment()

    @Published public private(set) var reduceMotion: Bool
    @Published public private(set) var reduceTransparency: Bool
    @Published public private(set) var increaseContrast: Bool
    @Published public private(set) var differentiateWithoutColor: Bool

    private var observers: [NSObjectProtocol] = []

    public init() {
        let workspace = NSWorkspace.shared
        self.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        self.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        self.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        self.differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor

        let center = workspace.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        })
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func refresh() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
    }
}

/// Convenience environment access.
private struct AccessibilityEnvironmentKey: EnvironmentKey {
    @MainActor static let defaultValue = AccessibilityEnvironment.shared
}

public extension EnvironmentValues {
    var auroraAccessibility: AccessibilityEnvironment {
        get { self[AccessibilityEnvironmentKey.self] }
        set { self[AccessibilityEnvironmentKey.self] = newValue }
    }
}
