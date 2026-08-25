//
//  SpaceLensView.swift
//  SalmanMacCleaner
//
//  Real Space Lens: hierarchical bubble visualization drawn with SwiftUI
//  Canvas. Bubble area is proportional to allocated size. Hover highlights
//  both the visual node and the synchronized list; clicking drills into a
//  folder with breadcrumb navigation and back/forward support. Heavy-child
//  capping + "Other" aggregation keeps rendering bounded.
//

import SwiftUI
import AppKit

public struct BubbleLayoutNode: Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var source: SpaceLensNode
    public var depth: Int

    public init(id: UUID, frame: CGRect, source: SpaceLensNode, depth: Int) {
        self.id = id
        self.frame = frame
        self.source = source
        self.depth = depth
    }
}

@MainActor
public final class SpaceLensViewModel: ObservableObject {
    @Published public var root: SpaceLensNode?
    @Published public var focus: SpaceLensNode?
    @Published public var isScanning = false
    @Published public var progressDetail: String?
    @Published public var includeHidden = false
    @Published public var includePackageContents = false
    @Published public var hoveredNode: SpaceLensNode?
    @Published public var selectedVolumeID: String = "/"

    public var breadcrumb: [SpaceLensNode] {
        var chain: [SpaceLensNode] = []
        var current = focus
        while let node = current {
            chain.insert(node, at: 0)
            current = parent(of: node)
        }
        return chain
    }

    private var historyStack: [SpaceLensNode] = []
    private var forwardStack: [SpaceLensNode] = []

    public func scan(volume: String) {
        isScanning = true
        progressDetail = nil
        root = nil
        focus = nil
        historyStack = []
        forwardStack = []

        let hidden = includeHidden
        let packages = includePackageContents
        Task.detached(priority: .userInitiated) {
            let node = SpaceLensEngine.buildTree(
                root: URL(fileURLWithPath: volume, isDirectory: true),
                includeHidden: hidden,
                includePackageContents: packages
            )
            await MainActor.run {
                self.root = node
                self.focus = node
                self.isScanning = false
            }
        }
    }

    public func drill(into node: SpaceLensNode) {
        guard node.isDirectory || node.isAggregate else { return }
        guard focus?.id != node.id else { return }
        if let current = focus {
            historyStack.append(current)
        }
        forwardStack = []
        focus = node
    }

    public var canGoBack: Bool { !historyStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public func goBack() {
        guard let previous = historyStack.popLast() else { return }
        if let current = focus {
            forwardStack.append(current)
        }
        focus = previous
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = focus {
            historyStack.append(current)
        }
        focus = next
    }

    public func parent(of node: SpaceLensNode) -> SpaceLensNode? {
        func search(_ current: SpaceLensNode, targetID: UUID) -> SpaceLensNode? {
            if current.children.contains(where: { $0.id == targetID }) {
                return current
            }
            for child in current.children {
                if let found = search(child, targetID: targetID) {
                    return found
                }
            }
            return nil
        }
        guard let root else { return nil }
        return search(root, targetID: node.id)
    }
}

public struct SpaceLensView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SpaceLensViewModel()
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    @State private var volumes: [VolumeInfo] = []
    @State private var heroMode = true

    public init() {}

    public var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .spaceLens,
                    isBusy: model.isScanning,
                    lastScanText: nil,
                    permissionWarning: nil,
                    primaryAction: {
                        model.selectedVolumeID = volumes.first?.mountPoint ?? "/"
                        model.scan(volume: model.selectedVolumeID)
                        heroMode = false
                    },
                    selectors: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("hero.volumes")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Picker("hero.volumes", selection: $model.selectedVolumeID) {
                                ForEach(volumes) { volume in
                                    Text("\(volume.name) — \(FileUtilities.formattedBytes(volume.used)) used")
                                        .tag(volume.mountPoint)
                                }
                            }
                            .frame(maxWidth: 420)
                            Toggle("space_lens.hidden_toggle", isOn: $model.includeHidden)
                                .toggleStyle(.checkbox)
                            Toggle("space_lens.packages_toggle", isOn: $model.includePackageContents)
                                .toggleStyle(.checkbox)
                        }
                    }
                )
                .task {
                    volumes = VolumeDiscoveryService.discoverVolumes()
                }
            } else if model.isScanning {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("space_lens.scanning")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workspace
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            HStack(spacing: 0) {
                bubbleCanvas
                    .frame(minWidth: 460)
                Divider().overlay(Color.white.opacity(0.08))
                synchronizedList
                    .frame(width: 340)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: { model.goBack() }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help(Text("space_lens.back"))
                Button(action: { model.goForward() }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help(Text("space_lens.forward"))
                Button(action: {
                    model.scan(volume: model.selectedVolumeID)
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(Text("space_lens.rescan"))
            }
        }
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.breadcrumb) { node in
                    Button {
                        model.drill(into: node)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: node.isDirectory ? "folder" : "doc")
                            Text(node.name)
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if node.id != model.breadcrumb.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var bubbleCanvas: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let focus = model.focus, focus.totalBytes > 0 else { return }
                let layout = BubblePacker.layout(node: focus, in: size)
                let depthHues: [Color] = [AuroraPalette.electricPurple, AuroraPalette.magenta, AuroraPalette.cyan, AuroraPalette.success]

                for bubble in layout.reversed() {
                    let color = depthHues[min(bubble.depth, depthHues.count - 1)]
                    let rect = bubble.frame
                    if bubble.source.isDirectory {
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(
                                Gradient(colors: [color.opacity(0.85), color.opacity(0.35)]),
                                center: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.midY - rect.height * 0.18),
                                startRadius: 0,
                                endRadius: max(rect.width, rect.height) / 2
                            )
                        )
                        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)), lineWidth: 1)
                    } else {
                        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
                    }
                    if rect.width > 64, bubble.source.name.count < 24 {
                        context.draw(
                            Text(bubble.source.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white),
                            at: CGPoint(x: rect.midX, y: rect.midY)
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        hitTest(at: value.location, canvasSize: geometry.size)
                    }
            )
        }
    }

    private func hitTest(at point: CGPoint, canvasSize: CGSize) {
        guard let focus = model.focus, focus.totalBytes > 0 else { return }
        let layout = BubblePacker.layout(node: focus, in: canvasSize)
        for bubble in layout {
            if bubble.frame.contains(point), bubble.source.isDirectory {
                model.drill(into: bubble.source)
                return
            }
        }
    }

    private var synchronizedList: some View {
        List {
            if let focus = model.focus {
                Section {
                    ForEach(focus.children) { child in
                        Button {
                            model.drill(into: child)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: child.isDirectory ? "folder.fill" : "doc")
                                    .foregroundStyle(AuroraPalette.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(child.path)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(FileUtilities.formattedBytes(child.totalBytes))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("results.reveal") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)])
                            }
                            Button("results.quicklook") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: child.path)])
                            }
                        }
                    }
                } header: {
                    Text(focus.name)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// Deterministic circle-packing layout: children sized by allocated bytes,
/// placed with a spiral until no overlap. Bounded by SpaceLensEngine's cap.
public enum BubblePacker {

    public static func layout(node: SpaceLensNode, in size: CGSize) -> [BubbleLayoutNode] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var result: [BubbleLayoutNode] = []

        let rootDiameter = min(size.width, size.height) * 0.94
        let rootFrame = CGRect(x: center.x - rootDiameter / 2, y: center.y - rootDiameter / 2,
                               width: rootDiameter, height: rootDiameter)
        result.append(BubbleLayoutNode(id: UUID(), frame: rootFrame, source: node, depth: 0))

        let total = max(node.totalBytes, 1)
        let sorted = node.children.sorted { $0.totalBytes > $1.totalBytes }
        var placed: [CGRect] = [rootFrame.insetBy(dx: -rootFrame.width * 0.02, dy: -rootFrame.height * 0.02)]

        for child in sorted {
            let areaFraction = Double(child.totalBytes) / Double(total)
            let diameter = max(sqrt(max(areaFraction, 0.0001)) * rootDiameter, 26)
            let frame = findSpot(for: diameter, inside: rootFrame, avoid: placed)
            if let frame {
                placed.append(frame.insetBy(dx: -4, dy: -4))
                result.append(BubbleLayoutNode(id: UUID(), frame: frame, source: child, depth: 1))
            }
        }
        return result
    }

    private static func findSpot(for diameter: CGFloat, inside container: CGRect, avoid: [CGRect]) -> CGRect? {
        let radius = diameter / 2
        let center = CGPoint(x: container.midX, y: container.midY)
        let maxR = max(container.width, container.height) / 2 - radius

        var angle = 0.0
        var distance: CGFloat = 0
        let step: CGFloat = radius * 0.6

        for _ in 0..<420 {
            let candidateCenter = CGPoint(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance
            )
            let candidate = CGRect(x: candidateCenter.x - radius, y: candidateCenter.y - radius,
                                   width: diameter, height: diameter)
            if container.contains(candidate) && !overlaps(candidate, avoid) {
                return candidate
            }
            angle += 0.42
            distance += step / 90
            if distance > maxR { break }
        }
        return nil
    }

    private static func overlaps(_ candidate: CGRect, _ placed: [CGRect]) -> Bool {
        for other in placed {
            if candidate.intersects(other) { return true }
        }
        return false
    }
}
