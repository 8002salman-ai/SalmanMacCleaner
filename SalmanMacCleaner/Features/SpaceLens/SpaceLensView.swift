//
//  SpaceLensView.swift
//  SalmanMacCleaner
//
//  Real Space Lens: hierarchical proportional bubble visualization drawn
//  with SwiftUI Canvas. Bubble area is proportional to actual allocated size.
//  Hover highlights both visual node and synchronized list with tooltip details;
//  clicking drills into folders with breadcrumb navigation and back/forward history.
//
//  Explicit states: Not scanned, Scanning, Partial, Denied, Measured — never Zero KB
//  for an unscanned root. System folders are protected, personal files are never auto-selected.
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

public struct SpaceLensTargetRoot: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var icon: String
    public var state: SpaceLensRootState
    public var isSystem: Bool

    public init(name: String, path: String, icon: String, state: SpaceLensRootState = .notScanned, isSystem: Bool = false) {
        self.name = name
        self.path = path
        self.icon = icon
        self.state = state
        self.isSystem = isSystem
    }
}

public enum SpaceLensSortOption: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case nameDescending

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sizeDescending: return NSLocalizedString("space_lens.sort.size_desc", comment: "")
        case .sizeAscending: return NSLocalizedString("space_lens.sort.size_asc", comment: "")
        case .nameAscending: return NSLocalizedString("space_lens.sort.name_asc", comment: "")
        case .nameDescending: return NSLocalizedString("space_lens.sort.name_desc", comment: "")
        }
    }
}

@MainActor
public final class SpaceLensViewModel: ObservableObject {
    @Published public var root: SpaceLensNode?
    @Published public var focus: SpaceLensNode?
    @Published public var isScanning = false
    @Published public var progress: SpaceLensProgress = SpaceLensProgress()
    @Published public var includeHidden = false
    @Published public var includePackageContents = false
    @Published public var hoveredNode: SpaceLensNode?
    @Published public var selectedTargetPath: String = PathSafety.userHome.path
    @Published public var searchText = ""
    @Published public var sortOption: SpaceLensSortOption = .sizeDescending
    @Published public var targets: [SpaceLensTargetRoot] = []
    @Published public var errorMessage: String?

    private var scanTask: Task<Void, Never>?
    private var scanToken = UUID()
    private var historyStack: [SpaceLensNode] = []
    private var forwardStack: [SpaceLensNode] = []

    public init() {
        let home = PathSafety.userHome.path
        self.targets = [
            SpaceLensTargetRoot(name: NSLocalizedString("space_lens.root.home", comment: ""), path: home, icon: "house.fill"),
            SpaceLensTargetRoot(name: NSLocalizedString("space_lens.root.applications", comment: ""), path: "/Applications", icon: "square.grid.2x2.fill"),
            SpaceLensTargetRoot(name: NSLocalizedString("space_lens.root.system", comment: ""), path: "/System", icon: "gearshape.2.fill", isSystem: true),
            SpaceLensTargetRoot(name: NSLocalizedString("space_lens.root.users", comment: ""), path: "/Users", icon: "person.2.fill")
        ]
        self.selectedTargetPath = home
    }

    public var selectedTarget: SpaceLensTargetRoot? {
        targets.first { $0.path == selectedTargetPath }
    }

    public var breadcrumb: [SpaceLensNode] {
        var chain: [SpaceLensNode] = []
        var current = focus
        while let node = current {
            chain.insert(node, at: 0)
            current = parent(of: node)
        }
        return chain
    }

    public var filteredChildren: [SpaceLensNode] {
        guard let focus else { return [] }
        var list = focus.children
        if !searchText.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending:
            list.sort { $0.totalBytes > $1.totalBytes }
        case .sizeAscending:
            list.sort { $0.totalBytes < $1.totalBytes }
        case .nameAscending:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        }
        return list
    }

    public func selectTarget(_ target: SpaceLensTargetRoot) {
        errorMessage = nil
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanToken = UUID()
        selectedTargetPath = target.path
        if let cached = SpaceLensCache.shared.node(
            for: target.path,
            includeHidden: includeHidden,
            includePackageContents: includePackageContents
        ) {
            root = cached
            focus = cached
            let cachedState: SpaceLensRootState
            if cached.isDenied {
                cachedState = .denied(reason: NSLocalizedString("space_lens.error.denied", comment: ""))
            } else if containsTruncatedNode(cached) {
                cachedState = .partial(deniedPaths: 0, errors: 1)
            } else {
                cachedState = .measured(bytes: cached.totalBytes, fileCount: cached.totalFiles)
            }
            updateTargetState(path: target.path, state: cachedState)
            historyStack = []
            forwardStack = []
        } else {
            root = nil
            focus = nil
            historyStack = []
            forwardStack = []
        }
    }

    public func addCustomTarget(url: URL) {
        switch FolderPicker.validatePickedFolder(url) {
        case .failure(let error):
            errorMessage = error.localizedDescription
            return
        case .success(let validated):
            errorMessage = nil
            let path = validated.path
            if !targets.contains(where: { $0.path == path }) {
                targets.append(SpaceLensTargetRoot(name: validated.lastPathComponent, path: path, icon: "folder.fill"))
            }
            selectedTargetPath = path
            scan(targetPath: path)
        }
    }

    public func startCurrentScan() {
        scan(targetPath: selectedTargetPath)
    }

    public func scan(targetPath: String) {
        errorMessage = nil
        scanTask?.cancel()
        let token = UUID()
        scanToken = token
        isScanning = true
        progress = SpaceLensProgress(currentPath: targetPath)
        root = nil
        focus = nil
        historyStack = []
        forwardStack = []

        updateTargetState(path: targetPath, state: .scanning(currentPath: targetPath, files: 0, bytes: 0, elapsed: 0, inaccessible: 0))

        let hidden = includeHidden
        let packages = includePackageContents
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: true)

        scanTask = Task.detached(priority: .userInitiated) {
            let result = SpaceLensEngine.buildTree(
                root: targetURL,
                includeHidden: hidden,
                includePackageContents: packages,
                progress: { update in
                    Task { @MainActor in
                        guard self.scanToken == token else { return }
                        self.progress = update
                    }
                },
                isCancelled: { Task.isCancelled }
            )

            await MainActor.run {
                guard self.scanToken == token else { return }
                self.root = result.node
                self.focus = result.node
                self.isScanning = false
                self.updateTargetState(path: targetPath, state: result.state)
            }
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        scanToken = UUID()
        isScanning = false
        if let current = selectedTarget, case .scanning = current.state {
            updateTargetState(
                path: selectedTargetPath,
                state: .partial(deniedPaths: progress.inaccessibleCount, errors: 1)
            )
        }
    }

    private func containsTruncatedNode(_ node: SpaceLensNode) -> Bool {
        node.isTruncated || node.children.contains { containsTruncatedNode($0) }
    }

    private func updateTargetState(path: String, state: SpaceLensRootState) {
        if let index = targets.firstIndex(where: { $0.path == path }) {
            targets[index].state = state
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
                if let found = search(child, targetID: targetID) { return found }
            }
            return nil
        }
        guard let root else { return nil }
        return search(root, targetID: node.id)
    }

    public func focusOnRoot() {
        if let root {
            focus = root
            historyStack = []
            forwardStack = []
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("space_lens.choose_folder.message", comment: "")
        if panel.runModal() == .OK, let url = panel.url {
            addCustomTarget(url: url)
        }
    }
}

public struct SpaceLensView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = SpaceLensViewModel()
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            targetSelectorBar
            if let error = model.errorMessage {
                PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            Divider().overlay(Color.white.opacity(0.08))

            if model.isScanning {
                scanningProgressView
            } else if model.root != nil {
                workspaceView
            } else if let target = model.selectedTarget {
                unscannedOrErrorView(target: target)
            } else {
                Text("space_lens.empty_selection")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background {
            AuroraBackground { EmptyView() }
        }
        .onChange(of: model.includeHidden) { _ in
            rescanAfterOptionChange()
        }
        .onChange(of: model.includePackageContents) { _ in
            rescanAfterOptionChange()
        }
        .onChange(of: appState.cancellationGeneration) { _ in
            if model.isScanning { model.cancelScan() }
        }
        .onDisappear {
            if model.isScanning { model.cancelScan() }
        }
    }

    private func rescanAfterOptionChange() {
        guard model.root != nil, !model.isScanning else { return }
        model.startCurrentScan()
    }

    // MARK: - Target Selector Bar

    private var targetSelectorBar: some View {
        HStack(spacing: 10) {
            ForEach(model.targets) { target in
                Button {
                    model.selectTarget(target)
                } label: {
                    HStack(spacing: 6) {
                        SpaceLensRootGlyph(name: target.name, selected: model.selectedTargetPath == target.path)
                        Text(target.name)
                            .font(.callout.weight(model.selectedTargetPath == target.path ? .semibold : .regular))
                            .foregroundStyle(model.selectedTargetPath == target.path ? .primary : .secondary)

                        StatusPill(LocalizedStringKey(target.state.title), kind: targetStateKind(target.state))
                            .scaleEffect(0.85)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        model.selectedTargetPath == target.path
                            ? AnyShapeStyle(AuroraPalette.electricPurple.opacity(0.25))
                            : AnyShapeStyle(Color.white.opacity(0.04)),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        if model.selectedTargetPath == target.path {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(AuroraPalette.electricPurple.opacity(0.5), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                chooseCustomFolder()
            } label: {
                Text("space_lens.choose_folder")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func targetStateKind(_ state: SpaceLensRootState) -> StatusPill.Kind {
        switch state {
        case .measured: return .ok
        case .partial: return .warning
        case .denied: return .warning
        case .scanning: return .info
        case .notScanned: return .unavailable
        }
    }

    // MARK: - Unscanned / Denied / Empty View

    private func unscannedOrErrorView(target: SpaceLensTargetRoot) -> some View {
        VStack(spacing: 16) {
            SpaceLensRootGlyph(name: target.name, selected: true)
                .frame(width: 54, height: 54)

            Text(target.name)
                .font(.title2.weight(.bold))

            Text(target.path)
                .font(.caption)
                .foregroundStyle(.tertiary)

            switch target.state {
            case .notScanned:
                Text("space_lens.not_scanned_explanation")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                Button {
                    model.scan(targetPath: target.path)
                } label: {
                    Text("space_lens.start_scan")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(AuroraPrimaryButtonStyle())

            case .denied(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(AuroraPalette.coral)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)

                HStack(spacing: 12) {
                    Button {
                        PermissionService.shared.openFullDiskAccessSettings()
                    } label: {
                        Label("permissions.open_fda_settings", systemImage: "lock.shield")
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())

                    Button {
                        model.scan(targetPath: target.path)
                    } label: {
                        Label("permissions.recheck", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                }

            default:
                Button {
                    model.scan(targetPath: target.path)
                } label: {
                    Label("space_lens.rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Scanning Progress View

    private var scanningProgressView: some View {
        VStack(spacing: 20) {
            SpaceLensActivityIndicator()
                .frame(width: 56, height: 56)

            Text("space_lens.measuring_title")
                .font(.title3.weight(.semibold))

            Text(model.progress.currentPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 500)

            HStack(spacing: 20) {
                progressMetric(title: "space_lens.metric.files", value: "\(model.progress.filesScanned)")
                progressMetric(title: "space_lens.metric.bytes", value: FileUtilities.formattedBytes(model.progress.bytesIndexed))
                progressMetric(title: "space_lens.metric.elapsed", value: String(format: "%.1fs", model.progress.elapsed))
                if model.progress.inaccessibleCount > 0 {
                    progressMetric(title: "space_lens.metric.denied", value: "\(model.progress.inaccessibleCount)")
                }
            }
            .padding(14)
            .glassCard()

            Button(role: .cancel) {
                model.cancelScan()
            } label: {
                Label("common.cancel", systemImage: "xmark")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressMetric(title: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: - Main Workspace

    private var workspaceView: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                bubbleCanvas
                    .frame(minWidth: 460)

                Divider().overlay(Color.white.opacity(0.08))

                synchronizedListView
                    .frame(width: 380)
            }
        }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 8) {
            Button(action: { model.goBack() }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .disabled(!model.canGoBack)
            .help(Text("space_lens.back"))

            Button(action: { model.goForward() }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .disabled(!model.canGoForward)
            .help(Text("space_lens.forward"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.breadcrumb) { node in
                        Button {
                            model.drill(into: node)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.caption2)
                                Text(node.name)
                                    .font(.caption.weight(.medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        if node.id != model.breadcrumb.last?.id {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Toggle("space_lens.hidden_toggle", isOn: $model.includeHidden)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(Text("space_lens.hidden_toggle"))
            Toggle("space_lens.packages_toggle", isOn: $model.includePackageContents)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help(Text("space_lens.packages_toggle"))

            Spacer()

            Button {
                model.scan(targetPath: model.selectedTargetPath)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .help(Text("space_lens.rescan"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Canvas

    private var bubbleCanvas: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    guard let focus = model.focus, focus.totalBytes > 0 else { return }
                    let layout = BubblePacker.layout(node: focus, in: size)
                    let depthHues: [Color] = [
                        AuroraPalette.electricPurple,
                        AuroraPalette.magenta,
                        AuroraPalette.cyan,
                        AuroraPalette.success
                    ]

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
                            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.3)), lineWidth: 1)
                        } else {
                            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.55)))
                        }

                        if rect.width > 56, bubble.source.name.count < 26 {
                            context.draw(
                                Text(bubble.source.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.white),
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

                if let focus = model.focus, focus.totalBytes == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(AuroraPalette.success)
                        Text("space_lens.empty_folder")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let hovered = model.hoveredNode {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(hovered.name)
                            .font(.caption.weight(.bold))
                        Text(FileUtilities.formattedBytes(hovered.totalBytes))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if hovered.isSystemProtected {
                            Label("space_lens.system_protected", systemImage: "lock.shield.fill")
                                .font(.caption2)
                                .foregroundStyle(AuroraPalette.amber)
                        }
                    }
                    .padding(8)
                    .glassCard()
                    .position(x: geometry.size.width - 120, y: 50)
                }
            }
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

    // MARK: - Synchronized List View

    private var synchronizedListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("space_lens.search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)

                Picker("", selection: $model.sortOption) {
                    ForEach(SpaceLensSortOption.allCases) { opt in
                        Text(opt.title).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.04))

            Divider().overlay(Color.white.opacity(0.05))

            List {
                if let focus = model.focus {
                    Section {
                        ForEach(model.filteredChildren) { child in
                            Button {
                                model.drill(into: child)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill")
                                        .foregroundStyle(child.isDirectory ? AuroraPalette.cyan : .secondary)
                                        .frame(width: 16)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 4) {
                                            Text(child.name)
                                                .font(.callout.weight(.medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            if child.isSystemProtected {
                                                Image(systemName: "lock.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(AuroraPalette.amber)
                                            }
                                        }
                                        Text(child.path)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(FileUtilities.formattedBytes(child.totalBytes))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        if focus.totalBytes > 0 {
                                            Text(String(format: "%.1f%%", Double(child.totalBytes) / Double(focus.totalBytes) * 100.0))
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .onHover { isHovered in
                                model.hoveredNode = isHovered ? child : nil
                            }
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
                        HStack {
                            Text(focus.name)
                                .font(.caption.weight(.bold))
                            Spacer()
                            Text(FileUtilities.formattedBytes(focus.totalBytes))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = NSLocalizedString("space_lens.select_folder", comment: "")
        if panel.runModal() == .OK, let url = panel.url {
            model.addCustomTarget(url: url)
        }
    }
}

/// Pure SwiftUI activity ring. The native indeterminate `ProgressView` maps to
/// `NSProgressIndicator` on macOS and triggered an AppKit initialization crash
/// on some systems when Space Lens first entered its scanning state.
private struct SpaceLensActivityIndicator: View {
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    var body: some View {
        TimelineView(.animation(minimumInterval: accessibility.reduceMotion ? 1 : 1.0 / 24.0)) { timeline in
            let phase = accessibility.reduceMotion
                ? 0.0
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 6)
                Circle()
                    .trim(from: 0.08, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [AuroraPalette.electricPurple.opacity(0.20), AuroraPalette.electricPurple, .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(phase * 360))
                    .shadow(color: AuroraPalette.electricPurple.opacity(0.55), radius: 10)
            }
            .accessibilityLabel(Text("space_lens.measuring_title"))
        }
    }
}

/// Asset-catalog independent root glyph. Keeping this page free of dynamic
/// SF Symbol lookups avoids a CoreUI crash observed while the Space Lens
/// target selector was first being constructed.
private struct SpaceLensRootGlyph: View {
    let name: String
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(selected ? AuroraPalette.electricPurple.opacity(0.30) : Color.white.opacity(0.08))
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? AuroraPalette.electricPurple.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
            Text(String(name.prefix(1)).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? AuroraPalette.electricPurple : Color.secondary)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}

/// Deterministic, bounded circle layout. The focus root is deliberately a
/// small anchor, while children are laid over the remaining canvas. Children
/// never avoid a full-size root circle (the old reason only one bubble was
/// visible), and every frame is finite and contained.
public enum BubblePacker {

    public static func layout(node: SpaceLensNode, in size: CGSize) -> [BubbleLayoutNode] {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let canvas = CGRect(x: 4, y: 4, width: max(width - 8, 1), height: max(height - 8, 1))
        let minimumSide = min(canvas.width, canvas.height)
        guard minimumSide.isFinite, minimumSide > 0 else { return [] }

        let rootDiameter = max(minimumSide * 0.28, 36)
        let rootFrame = CGRect(
            x: canvas.midX - rootDiameter / 2,
            y: canvas.midY - rootDiameter / 2,
            width: rootDiameter,
            height: rootDiameter
        )
        var result = [BubbleLayoutNode(id: stableID(for: node.path), frame: rootFrame, source: node, depth: 0)]
        var placed = [rootFrame.insetBy(dx: -3, dy: -3)]
        let total = max(node.totalBytes, 1)
        let sorted = node.children.sorted {
            if $0.totalBytes == $1.totalBytes { return $0.path < $1.path }
            return $0.totalBytes > $1.totalBytes
        }

        for child in sorted {
            let fraction = min(max(Double(child.totalBytes) / Double(total), 0.0001), 1)
            // Diameter is proportional to the square root of measured bytes
            // (area carries the byte proportion), with a cap that preserves
            // room for several siblings around the focus anchor.
            let rawDiameter = sqrt(fraction) * minimumSide * 0.38
            let diameter = min(max(rawDiameter, 26), minimumSide * 0.36)
            guard diameter.isFinite, diameter > 0,
                  let frame = findSpot(for: diameter, inside: canvas, avoid: placed) else { continue }
            placed.append(frame.insetBy(dx: -3, dy: -3))
            result.append(BubbleLayoutNode(
                id: stableID(for: child.path),
                frame: frame,
                source: child,
                depth: 1
            ))
        }
        return result
    }

    private static func stableID(for path: String) -> UUID {
        // UUID(uuidString:) is deterministic for generated test paths when
        // available; a UUID derived from UTF-8 bytes avoids random layout IDs.
        let bytes = Array(path.utf8)
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        let hex = String(format: "%016llx%016llx%016llx%016llx", hash, hash ^ 0x9e3779b97f4a7c15, hash, hash ^ 0xa5a5a5a5a5a5a5a5)
        let chars = Array(hex.prefix(32))
        let uuidText = "\(String(chars[0..<8]))-\(String(chars[8..<12]))-\(String(chars[12..<16]))-\(String(chars[16..<20]))-\(String(chars[20..<32]))"
        return UUID(uuidString: uuidText) ?? UUID()
    }

    private static func findSpot(for diameter: CGFloat, inside container: CGRect, avoid: [CGRect]) -> CGRect? {
        let radius = diameter / 2
        let center = CGPoint(x: container.midX, y: container.midY)
        let maxRadius = min(container.width, container.height) / 2 - radius
        guard maxRadius >= 0 else { return nil }
        let radialStep = max(radius * 0.42, 4)

        for index in 0..<2_400 {
            let angle = Double(index) * 0.61803398875 * Double.pi * 2
            let distance = min(maxRadius, CGFloat(sqrt(Double(index))) * radialStep)
            let candidateCenter = CGPoint(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance
            )
            let candidate = CGRect(
                x: candidateCenter.x - radius,
                y: candidateCenter.y - radius,
                width: diameter,
                height: diameter
            )
            guard candidate.isFinite, container.contains(candidate), !overlaps(candidate, avoid) else { continue }
            return candidate
        }
        return nil
    }

    private static func overlaps(_ candidate: CGRect, _ placed: [CGRect]) -> Bool {
        placed.contains { candidate.intersects($0) }
    }
}

private extension CGRect {
    var isFinite: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite && width >= 0 && height >= 0
    }
}
