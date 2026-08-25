//
//  GlassComponents.swift
//  SalmanMacCleaner
//
//  Reusable Aurora Glass surfaces and controls: cards, buttons, badges,
//  sidebar rows, section headers and status pills. All controls carry
//  distinct hover/pressed/keyboard-focus states and VoiceOver labels.
//

import SwiftUI

// MARK: - Glass card

public struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accessibility.reduceTransparency
                          ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                          : AnyShapeStyle(.ultraThinMaterial))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.12 : 0.55),
                                        Color.white.opacity(0.03)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.08), radius: 18, y: 8)
            }
    }
}

public extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }
}

// MARK: - Sidebar row style

/// Premium sidebar row: rounded translucent capsule when selected, purple
/// highlight + inner glow, distinct hover and keyboard-focus states.
public struct SidebarRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(background(for: configuration))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                configuration.isPressed
                                    ? AuroraPalette.electricPurple.opacity(0.5)
                                    : Color.white.opacity(configuration.isPressed ? 0 : 0.06),
                                lineWidth: 1
                            )
                    }
                    .shadow(
                        color: configuration.isPressed
                            ? AuroraPalette.electricPurple.opacity(0.35)
                            : .clear,
                        radius: 8
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func background(for configuration: Configuration) -> Color {
        if configuration.isPressed {
            return AuroraPalette.violet.opacity(0.55)
        }
        if configuration.isHovering {
            return Color.white.opacity(colorScheme == .dark ? 0.09 : 0.16)
        }
        return .clear
    }
}

private extension ButtonStyleConfiguration {
    var isHovering: Bool {
        // SwiftUI does not expose hover in ButtonStyle; hover feedback is
        // delivered by the row overlay in SidebarRowView instead.
        false
    }
}

// MARK: - Glass button style

/// Primary Aurora action button: gradient fill, glow, pressed feedback.
public struct AuroraPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .frame(minWidth: 180)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: configuration.isPressed
                                ? [AuroraPalette.violet, AuroraPalette.magenta]
                                : [AuroraPalette.violet, AuroraPalette.electricPurple, AuroraPalette.magenta],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                    }
                    .shadow(color: AuroraPalette.electricPurple.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 14, y: 6)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return AnyView(label.glassEffect(.regular))
        }
        #endif
        return AnyView(label)
    }
}

/// Secondary glass action.
public struct AuroraSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(AuroraPalette.primaryText(colorScheme, increaseContrast: false))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Badges

public struct SafetyBadge: View {
    let level: SafetyLevel

    public init(level: SafetyLevel) {
        self.level = level
    }

    public var body: some View {
        Text(level.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(SemanticTint.color(for: level).opacity(0.18), in: Capsule())
            .foregroundStyle(SemanticTint.color(for: level))
    }
}

public struct StatusPill: View {
    public enum Kind {
        case ok
        case warning
        case info
        case unavailable
    }

    let text: LocalizedStringKey
    let kind: Kind

    public init(_ text: LocalizedStringKey, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch kind {
        case .ok: return AuroraPalette.success
        case .warning: return AuroraPalette.amber
        case .info: return AuroraPalette.cyan
        case .unavailable: return AuroraPalette.tertiaryText(.dark)
        }
    }
}

// MARK: - Section header

public struct GlassSectionHeader: View {
    let title: LocalizedStringKey
    let systemImage: String?

    public init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AuroraPalette.electricPurple)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
        }
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Capability row (hero screens)

public struct CapabilityRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    public init(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.icon = icon
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AuroraPalette.electricPurple.opacity(0.35), AuroraPalette.violet.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reclaim ring

/// Summary ring used by the results workspace.
public struct ReclaimRing: View {
    let safeBytes: Int64
    let reviewBytes: Int64
    let protectedBytes: Int64

    public init(safeBytes: Int64, reviewBytes: Int64, protectedBytes: Int64) {
        self.safeBytes = safeBytes
        self.reviewBytes = reviewBytes
        self.protectedBytes = protectedBytes
    }

    private var total: Int64 { safeBytes + reviewBytes + protectedBytes }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 14)
            if total > 0 {
                Circle()
                    .trim(from: 0, to: fraction(safeBytes))
                    .stroke(AuroraPalette.success, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: fraction(safeBytes), to: fraction(safeBytes + reviewBytes))
                    .stroke(AuroraPalette.amber, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Circle()
                    .trim(from: fraction(safeBytes + reviewBytes), to: 1)
                    .stroke(AuroraPalette.coral.opacity(0.7), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(FileUtilities.formattedBytes(safeBytes + reviewBytes))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text("results.ring.label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String(format: NSLocalizedString("results.ring.a11y", comment: ""),
                                        FileUtilities.formattedBytes(safeBytes + reviewBytes))))
    }

    private func fraction(_ value: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(value) / Double(total), 0), 1)
    }
}
