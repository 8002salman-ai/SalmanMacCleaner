//
//  AuroraTheme.swift
//  SalmanMacCleaner
//
//  Original "Aurora Glass" design tokens. Semantic colors resolve against
//  the active color scheme; Increase Contrast shifts token brightness so
//  text stays accessible.
//

import SwiftUI

public enum AuroraPalette {

    // Core brand tokens (dark scheme).
    public static let midnight = Color(red: 16 / 255, green: 0 / 255, blue: 37 / 255)          // #100025
    public static let deepIndigo = Color(red: 27 / 255, green: 6 / 255, blue: 72 / 255)        // #1B0648
    public static let violet = Color(red: 95 / 255, green: 20 / 255, blue: 199 / 255)          // #5F14C7
    public static let electricPurple = Color(red: 140 / 255, green: 53 / 255, blue: 255 / 255) // #8C35FF
    public static let magenta = Color(red: 240 / 255, green: 47 / 255, blue: 208 / 255)        // #F02FD0
    public static let cyan = Color(red: 93 / 255, green: 220 / 255, blue: 255 / 255)           // #5DDCFF
    public static let success = Color(red: 65 / 255, green: 209 / 255, blue: 138 / 255)        // #41D18A
    public static let amber = Color(red: 255 / 255, green: 200 / 255, blue: 87 / 255)          // #FFC857
    public static let coral = Color(red: 255 / 255, green: 92 / 255, blue: 118 / 255)          // #FF5C76

    /// Primary text (near white in dark, near black in light).
    public static func primaryText(_ scheme: ColorScheme, increaseContrast: Bool) -> Color {
        switch scheme {
        case .dark:
            return increaseContrast ? .white : Color(red: 0.96, green: 0.95, blue: 0.99)
        default:
            return increaseContrast ? .black : Color(red: 0.10, green: 0.08, blue: 0.18)
        }
    }

    /// Secondary text (lavender-gray).
    public static func secondaryText(_ scheme: ColorScheme, increaseContrast: Bool) -> Color {
        switch scheme {
        case .dark:
            return increaseContrast ? Color(red: 0.85, green: 0.83, blue: 0.95) : Color(red: 0.72, green: 0.68, blue: 0.82)
        default:
            return increaseContrast ? Color(red: 0.25, green: 0.22, blue: 0.34) : Color(red: 0.42, green: 0.38, blue: 0.52)
        }
    }

    /// Tertiary text.
    public static func tertiaryText(_ scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            return Color(red: 0.55, green: 0.52, blue: 0.66)
        default:
            return Color(red: 0.55, green: 0.51, blue: 0.64)
        }
    }

    /// The full-window background gradient.
    public static func backgroundGradient(_ scheme: ColorScheme) -> [Color] {
        switch scheme {
        case .dark:
            return [midnight, deepIndigo, Color(red: 38 / 255, green: 10 / 255, blue: 92 / 255)]
        default:
            return [Color(red: 0.97, green: 0.96, blue: 1.0),
                    Color(red: 0.91, green: 0.88, blue: 0.98),
                    Color(red: 0.84, green: 0.82, blue: 0.96)]
        }
    }

    /// Radial illumination blobs behind module artwork.
    public static func auroraBlobColors(_ scheme: ColorScheme) -> [Color] {
        switch scheme {
        case .dark:
            return [
                electricPurple.opacity(0.55),
                magenta.opacity(0.32),
                cyan.opacity(0.28),
                violet.opacity(0.45)
            ]
        default:
            return [
                electricPurple.opacity(0.30),
                magenta.opacity(0.18),
                cyan.opacity(0.22),
                violet.opacity(0.22)
            ]
        }
    }

    /// Primary accent used for actions.
    public static var accent: Color { electricPurple }
    public static var accentGradient: [Color] { [violet, electricPurple, magenta] }
}

/// Semantic tint helpers used across modules.
public enum SemanticTint {
    public static func color(for safety: SafetyLevel) -> Color {
        switch safety {
        case .safe: return AuroraPalette.success
        case .review: return AuroraPalette.amber
        case .protected: return AuroraPalette.coral
        }
    }

    public static func color(for confidence: UninstallConfidence) -> Color {
        switch confidence {
        case .high: return AuroraPalette.success
        case .medium: return AuroraPalette.amber
        case .cautious: return AuroraPalette.coral
        }
    }
}
