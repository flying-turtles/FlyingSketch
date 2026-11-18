import SwiftUI
import SketchCore
import PartsKit

/// A document part whose library version differs from the embedded one.
struct OutdatedPart: Identifiable {
    let current: PartDefinition
    let newer: LibraryPart
    var id: String { current.key }
}

/// Sheet listing outdated parts with current vs library version; per-part Update and "Update all".
struct PartUpdatesView: View {
    let entries: [OutdatedPart]
    let update: (OutdatedPart) -> Void
    let updateAll: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.current.title)
                            Text("\(Self.short(entry.current.versionHash)) → \(Self.short(entry.newer.definition.versionHash))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Update") { update(entry) }.buttonStyle(.bordered)
                    }
                }
            }
            .overlay {
                if entries.isEmpty { ContentUnavailableView("All parts up to date", systemImage: "checkmark.circle") }
            }
            .navigationTitle("Part Updates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Update all", action: updateAll).disabled(entries.isEmpty)
                }
            }
        }
    }

    private static func short(_ hash: String) -> String { String(hash.prefix(7)) }
}
