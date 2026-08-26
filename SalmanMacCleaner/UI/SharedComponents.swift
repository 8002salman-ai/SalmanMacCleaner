//
//  SharedComponents.swift
//  SalmanMacCleaner
//
//  Reusable UI building blocks: progress bars, safety notes, permission
//  banners, empty states, size labels and confirmation dialogs.
//

import SwiftUI

// MARK: - Activity toolbar

struct ActivityToolbarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch appState.activityPhase {
            case .idle:
                EmptyView()
            case .scanning(let detail), .hashing(let detail), .cleaning(let detail):
                ProgressView(value: appState.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text(detail)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220)
                if appState.activityPhase.isCancellable {
                    Button {
                        appState.cancelCurrentScan()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .help("toolbar.cancel.help")
                }
            case .finished(let summary):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(summary)
                    .font(.caption)
                    .lineLimit(1)
            case .failed(let message):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .lineLimit(1)
                    .help(Text(message))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isBusy)
    }
}

// MARK: - Safety note banner

struct SafetyNoteView: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Permission banner

struct PermissionBannerView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Selection summary bar

struct SelectionSummaryBar: View {
    let selectedCount: Int
    let selectedBytes: Int64
    let previewOnly: Bool

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(String(format: NSLocalizedString("selection.count", comment: ""), selectedCount))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            Text(FileUtilities.formattedBytes(selectedBytes))
                .monospacedDigit()
            Spacer()
            Text(LocalizedStringKey(previewOnly ? "selection.preview_only" : "selection.will_trash"))
                .font(.caption)
                .foregroundStyle(previewOnly ? Color.green : Color.orange)
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Cleanup result summary

/// Compact, reusable post-run report. It is intentionally separate from the
/// confirmation dialog so failed and remaining items stay visible after a
/// Trash attempt rather than being mistaken for successful cleanup.
struct CleanupResultSummaryView: View {
    let result: CleanupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: result.previewOnly
                      ? "eye.fill"
                      : (result.cancelled || result.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(result.previewOnly ? AuroraPalette.cyan : (result.cancelled || result.failedCount > 0 ? AuroraPalette.amber : AuroraPalette.success))
                Text(result.previewOnly
                     ? String(format: NSLocalizedString("cleanup.report.previewed", comment: ""), result.previewed.count, FileUtilities.formattedBytes(result.totalBytes))
                     : String(format: NSLocalizedString("cleanup.report.moved", comment: ""), result.trashed.count, FileUtilities.formattedBytes(result.movedBytes)))
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            Text(String(format: NSLocalizedString("cleanup.report.exact", comment: ""),
                        result.selectedCount,
                        result.processedCount,
                        result.trashed.count,
                        result.previewed.count,
                        result.failedCount,
                        result.notProcessed,
                        FileUtilities.formattedBytes(result.remainingBytes)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if result.cancelled {
                Label("cleanup.report.cancelled", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AuroraPalette.amber)
            }
            ForEach(Array(result.failures.prefix(4).enumerated()), id: \.offset) { _, failure in
                Text("\(failure.path): \(failure.reason)")
                    .font(.caption)
                    .foregroundStyle(AuroraPalette.amber)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confirmation dialog helper

struct ConfirmationDialogConfig {
    let title: String
    let message: String
    let confirmTitle: String
    let destructive: Bool
}

extension View {
    /// Standard second-confirmation dialog. `isPresented` binding, `onConfirm`
    /// runs only when the user presses the confirm button.
    func cleanupConfirmation(
        isPresented: Binding<Bool>,
        config: ConfirmationDialogConfig,
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(LocalizedStringKey(config.title), isPresented: isPresented) {
            Button(LocalizedStringKey(config.confirmTitle), role: config.destructive ? .destructive : nil, action: onConfirm)
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(config.message)
        }
    }
}

// MARK: - Row-level selection checkbox + size

struct ItemRowLabel: View {
    let name: String
    let detail: String?
    let size: Int64

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(FileUtilities.formattedBytes(size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Confidence badge

struct ConfidenceBadge: View {
    private let title: String
    private let tint: Color

    init(confidence: UninstallConfidence) {
        self.title = confidence.title
        self.tint = Color(hex: confidence.colorHex)
    }

    init(confidence: LeftoverCandidate.Confidence) {
        self.title = confidence.title
        switch confidence {
        case .high: self.tint = AuroraPalette.success
        case .medium: self.tint = AuroraPalette.amber
        case .cautious: self.tint = AuroraPalette.coral
        }
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
            .help(Text(NSLocalizedString("confidence.help", comment: "")))
    }
}

// MARK: - Color from hex (used by confidence badges)

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

// MARK: - Confirmation dialog config helper

extension ConfirmationDialogConfig {
    /// Standard preview/trash confirmation used by every feature view.
    ///
    /// The wording follows the mode: a Preview Mode run asks to "Confirm
    /// Preview" and states that nothing will move; only a real run offers
    /// "Move Selected to Trash" as a destructive action. `destructive`
    /// defaults to `!previewOnly` so the dialog can never label a preview
    /// as a destructive move.
    static func detailLine(path: String,
                           category: String,
                           size: Int64,
                           confidence: String,
                           reason: String) -> String {
        String(format: NSLocalizedString("common.confirm.item", comment: ""),
               path,
               category,
               FileUtilities.formattedBytes(size),
               confidence,
               reason.isEmpty ? NSLocalizedString("common.confirm.no_reason", comment: "") : reason)
    }

    static func standard(itemCount: Int,
                         totalBytes: Int64,
                         previewOnly: Bool = false,
                         destructive: Bool? = nil,
                         details: [String] = []) -> ConfirmationDialogConfig {
        let baseMessage = String(
            format: NSLocalizedString(
                previewOnly ? "common.confirm.preview_message" : "common.confirm.message",
                comment: ""
            ),
            itemCount,
            FileUtilities.formattedBytes(totalBytes)
        )
        let visibleDetails = details.prefix(12)
        let detailMessage: String
        if visibleDetails.isEmpty {
            detailMessage = ""
        } else {
            let remaining = details.count - visibleDetails.count
            let suffix = remaining > 0
                ? "\n" + String(format: NSLocalizedString("common.confirm.more_items", comment: ""), remaining)
                : ""
            detailMessage = "\n\n" + NSLocalizedString("common.confirm.details_header", comment: "")
                + "\n" + visibleDetails.joined(separator: "\n") + suffix
        }
        return ConfirmationDialogConfig(
            title: NSLocalizedString(
                previewOnly ? "common.confirm.preview_title" : "common.confirm.title",
                comment: ""
            ),
            message: baseMessage + detailMessage,
            confirmTitle: NSLocalizedString(
                previewOnly ? "common.confirm.preview" : "common.confirm.trash",
                comment: ""
            ),
            destructive: destructive ?? !previewOnly
        )
    }
}
