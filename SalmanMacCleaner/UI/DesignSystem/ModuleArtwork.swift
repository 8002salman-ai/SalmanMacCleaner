//
//  ModuleArtwork.swift
//  SalmanMacCleaner
//
//  Original abstract artwork for every module: layered Canvas compositions
//  of gradients, rings and SF Symbols — no copied third-party artwork.
//  Each module gets a deterministic composition seeded from its identity.
//

import SwiftUI

public struct ModuleArtwork: View {
    let module: SidebarModule
    var size: CGFloat = 340
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    public init(module: SidebarModule, size: CGFloat = 340) {
        self.module = module
        self.size = size
    }

    public var body: some View {
        ZStack {
            AuroraGlow(color: primaryColor, radius: size * 0.5)

            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                let radius = min(canvasSize.width, canvasSize.height) * 0.42

                // Outer rings (module-tinted).
                let ringGradient = Gradient(colors: [primaryColor.opacity(0.55), secondaryColor.opacity(0.05)])
                for ringIndex in 0..<3 {
                    let ringRadius = radius * (1 + CGFloat(ringIndex) * 0.16)
                    let rect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                      width: ringRadius * 2, height: ringRadius * 2)
                    context.stroke(
                        Path(ellipseIn: rect),
                        with: .conicGradient(
                            Gradient(colors: [ringGradient.stops[0].color, ringGradient.stops[1].color, ringGradient.stops[0].color]),
                            center: center,
                            angle: .degrees(Double(module.artworkSeed) * 21 + Double(ringIndex) * 40)
                        ),
                        lineWidth: 1.2
                    )
                }

                // Satellite glyphs positioned deterministically per module.
                let satellites = satelliteSymbols
                for (index, symbol) in satellites.enumerated() {
                    guard let resolved = context.resolve(Image(systemName: symbol)) else { continue }
                    let angle = Double(module.artworkSeed) * 0.61 + Double(index) * (2 * .pi / Double(max(satellites.count, 1)))
                    let orbit = radius * 1.18
                    let position = CGPoint(
                        x: center.x + cos(angle) * orbit,
                        y: center.y + sin(angle) * orbit
                    )
                    let glyphSize = size * 0.055
                    var resolvedContext = context
                    resolvedContext.opacity = 0.75
                    resolvedContext.draw(
                        resolved,
                        in: CGRect(x: position.x - glyphSize / 2, y: position.y - glyphSize / 2, width: glyphSize, height: glyphSize)
                    )
                }

                // Central glass disc.
                let discRect = CGRect(x: center.x - radius * 0.62, y: center.y - radius * 0.62,
                                      width: radius * 1.24, height: radius * 1.24)
                let disc = Path(ellipseIn: discRect)
                context.fill(
                    disc,
                    with: .radialGradient(
                        Gradient(colors: [primaryColor.opacity(0.30), primaryColor.opacity(0.06)]),
                        center: center,
                        startRadius: 0,
                        endRadius: radius * 0.62
                    )
                )
                context.stroke(disc, with: .color(.white.opacity(colorScheme == .dark ? 0.16 : 0.5)), lineWidth: 1)

                // Central module symbol.
                guard let central = context.resolve(Image(systemName: module.systemImage)) else { return }
                let centralSize = radius * 0.72
                var centralContext = context
                centralContext.addFilter(.shadow(color: primaryColor.opacity(0.55), radius: 18))
                centralContext.draw(
                    central,
                    in: CGRect(x: center.x - centralSize / 2, y: center.y - centralSize / 2, width: centralSize, height: centralSize)
                )
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
        .opacity(accessibility.reduceTransparency ? 0.9 : 1)
        .scaleEffect(accessibility.reduceMotion ? 1.0 : 1.0)
    }

    private var primaryColor: Color {
        switch module.group {
        case .main: return AuroraPalette.electricPurple
        case .cleanup: return AuroraPalette.cyan
        case .storage: return AuroraPalette.magenta
        case .applications: return AuroraPalette.success
        case .health: return AuroraPalette.amber
        case .other: return AuroraPalette.violet
        }
    }

    private var secondaryColor: Color {
        switch module.group {
        case .main: return AuroraPalette.magenta
        case .cleanup: return AuroraPalette.electricPurple
        case .storage: return AuroraPalette.electricPurple
        case .applications: return AuroraPalette.cyan
        case .health: return AuroraPalette.coral
        case .other: return AuroraPalette.cyan
        }
    }

    private var satelliteSymbols: [String] {
        switch module {
        case .smartCare: return ["sparkle", "sparkles", "wand.and.stars"]
        case .deepScan: return ["viewfinder.circle", "dot.radiowaves.left.and.right", "magnifyingglass"]
        case .systemJunk: return ["folder", "doc.text", "sparkles"]
        case .trashBins: return ["trash.circle", "arrow.uturn.backward", "externaldrive"]
        case .appLeftovers: return ["app.badge", "square.stack.3d.up.slash", "questionmark.circle"]
        case .developerCaches: return ["hammer.circle", "arrow.triangle.2.circlepath", "shippingbox"]
        case .spaceLens: return ["circle.circle", "circle.hexagongrid", "scope"]
        case .largeOldFiles: return ["externaldrive.badge.timemachine", "hourglass", "arrow.down.to.line"]
        case .duplicates: return ["doc.on.doc", "waveform.path.ecg", "link"]
        case .myClutter: return ["shippingbox", "folder.badge.questionmark", "checkmark.circle"]
        case .applications: return ["square.grid.2x2", "info.circle", "cpu"]
        case .uninstaller: return ["app.badge", "square.3.layers.3d", "lock.shield"]
        case .appUpdater: return ["arrow.down.circle", "checkmark.seal", "info.circle"]
        case .startupItems: return ["power", "gearshape.2", "exclamationmark.triangle"]
        case .performance: return ["gauge.with.dots.needle.50percent", "memorychip", "lightbulb"]
        case .securityAudit: return ["checkmark.shield", "doc.badge.gearshape", "link.badge.plus"]
        case .permissions: return ["lock.shield", "hand.raised", "slider.horizontal.3"]
        case .myTools: return ["square.grid.3x3.square", "magnifyingglass", "keyboard"]
        case .activityHistory: return ["clock.arrow.circlepath", "doc.text", "square.and.arrow.up"]
        case .settings: return ["gearshape.2", "slider.horizontal.3", "lock.shield"]
        }
    }
}
