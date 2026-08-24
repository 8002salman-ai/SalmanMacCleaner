//
//  HistoryView.swift
//  SalmanMacCleaner
//
//  Local cleanup history table with JSON/CSV export and clear. Rendered on the
//  dashboard and fully local — nothing is ever transmitted.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("history.title", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Spacer()
                    if !appState.history.entries.isEmpty {
                        Button("history.export.json") {
                            _ = appState.history.exportInteractive(format: .json)
                        }
                        Button("history.export.csv") {
                            _ = appState.history.exportInteractive(format: .csv)
                        }
                        Button("history.clear", role: .destructive) {
                            appState.history.clear()
                        }
                    }
                }

                if appState.history.entries.isEmpty {
                    Text("history.empty")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    Table(appState.history.entries.prefix(10).map { $0 }) {
                        TableColumn("history.column.date") { entry in
                            Text(entry.date, style: .date)
                                .font(.callout)
                        }
                        TableColumn("history.column.action") { entry in
                            Text(entry.action)
                                .font(.callout)
                                .lineLimit(1)
                        }
                        TableColumn("history.column.items") { entry in
                            Text("\(entry.itemCount)")
                                .font(.callout.monospacedDigit())
                        }
                        .width(60)
                        TableColumn("history.column.bytes") { entry in
                            Text(FileUtilities.formattedBytes(entry.bytes))
                                .font(.callout.monospacedDigit())
                        }
                        .width(100)
                        TableColumn("history.column.mode") { entry in
                            Text(LocalizedStringKey(entry.dryRun ? "history.mode.preview" : "history.mode.trash"))
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(entry.dryRun ? Color.green.opacity(0.15) : Color.orange.opacity(0.15),
                                            in: Capsule())
                        }
                        .width(80)
                    }
                    .frame(minHeight: 160)
                }
            }
            .padding(8)
        } label: {
            Label("history.title", systemImage: "clock")
        }
    }
}
