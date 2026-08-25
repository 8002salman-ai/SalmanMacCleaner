//
//  AuroraBackground.swift
//  SalmanMacCleaner
//
//  The immersive full-window surface: dark indigo/violet/midnight gradient,
//  soft radial illumination behind the active module, and a subtle animated
//  aurora glow. All motion stops when Reduce Motion is enabled, and the
//  gradient flattens when Reduce Transparency is enabled.
//

import SwiftUI

/// The single immersive background behind every module.
public struct AuroraBackground<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    /// Deterministic seed for the illumination position (per module).
    private let seed: Int
    private let content: Content

    public init(seed: Int = 0, @ViewBuilder content: () -> Content) {
        self.seed = seed
        self.content = content()
    }

    public var body: some View {
        ZStack {
            backgroundLayers
            content
        }
    }

    @ViewBuilder
    private var backgroundLayers: some View {
        let palette = AuroraPalette.backgroundGradient(colorScheme)
        let blobColors = AuroraPalette.auroraBlobColors(colorScheme)

        LinearGradient(
            colors: palette,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        if !accessibility.reduceTransparency {
            if accessibility.reduceMotion {
                // Static illumination — same composition, no animation.
                StaticAuroraBlobs(seed: seed, colors: blobColors)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    AnimatedAuroraBlobs(seed: seed, colors: blobColors, time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }

        // One-pixel translucent border for the glass edge definition.
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.10 : 0.35),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .padding(1)
            .allowsHitTesting(false)
    }
}

/// Slow-drifting aurora blobs.
private struct AnimatedAuroraBlobs: View {
    let seed: Int
    let colors: [Color]
    let time: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let phase = time.truncatingRemainder(dividingBy: 40) / 40
            let offset1 = drift(phase: phase, seed: seed)
            let offset2 = drift(phase: (phase + 0.33).truncatingRemainder(dividingBy: 1), seed: seed + 7)

            RadialGradient(
                colors: [colors[0], colors[0].opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.55
            )
            .frame(width: size.width * 0.9, height: size.width * 0.9)
            .offset(offset1)
            .blur(radius: 40)

            RadialGradient(
                colors: [colors[2], colors[2].opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.4
            )
            .frame(width: size.width * 0.6, height: size.width * 0.6)
            .offset(offset2)
            .blur(radius: 50)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drift(phase: Double, seed: Int) -> CGSize {
        let angle = Double(seed % 7) * 1.1 + phase * 2 * .pi
        return CGSize(width: cos(angle) * 60, height: sin(angle) * 44)
    }
}

/// Static (Reduce Motion) illumination.
private struct StaticAuroraBlobs: View {
    let seed: Int
    let colors: [Color]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let angle = Double(seed % 7) * 1.1
            RadialGradient(
                colors: [colors[0], colors[0].opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.55
            )
            .frame(width: size.width * 0.9, height: size.width * 0.9)
            .offset(x: cos(angle) * 40, y: sin(angle) * 30)
            .blur(radius: 40)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Native Liquid Glass for macOS 26+; older systems get the fallback below.
#if compiler(>=6.2)
@available(macOS 26.0, *)
public extension View {
    func auroraNativeGlass(_ style: GlassEffectContainer.Style = .regular) -> some View {
        glassEffect(style)
    }
}
#endif

/// The material fallback used on macOS 13–15.
public extension View {
    /// Applies the appropriate glass surface for the running OS.
    func auroraGlass(style: Material = .ultraThinMaterial) -> some View {
        modifier(AuroraGlassModifier(style: style))
    }
}

private struct AuroraGlassModifier: ViewModifier {
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    let style: Material

    func body(content: Content) -> some View {
        if accessibility.reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        } else {
            content.background(style)
        }
    }
}

/// Soft inner glow used behind artwork and primary controls.
public struct AuroraGlow: View {
    let color: Color
    let radius: CGFloat

    public init(color: Color = AuroraPalette.electricPurple, radius: CGFloat = 60) {
        self.color = color
        self.radius = radius
    }

    public var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.5), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius
                )
            )
            .blur(radius: radius / 3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
