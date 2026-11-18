import SwiftUI
import PhotoPartKit

/// Sheet: create a bus (internally connected pins) from multi-selected pins; delete buses.
struct BusEditorView: View {
    @Bindable var session: StudioSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        let inBus = Set(session.draft.buses.flatMap { $0 })
        NavigationStack {
            List {
                Section {
                    ForEach(session.draft.pins, id: \.id) { pin in
                        let taken = inBus.contains(pin.id)
                        Button { toggle(pin.id) } label: {
                            HStack {
                                Image(systemName: selected.contains(pin.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(pin.id) ? Color.accentColor : .secondary)
                                Text(name(pin.id))
                                Spacer()
                                if taken { Text("In a bus").font(.caption).foregroundStyle(.secondary) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(taken)
                    }
                    Button("Create bus from \(selected.count) pins", systemImage: "plus.circle", action: create)
                        .disabled(selected.count < 2)
                } header: {
                    Text("New bus")
                } footer: {
                    Text("Pins in a bus are connected inside the part. Select two or more pins.")
                }
                Section("Buses") {
                    if session.draft.buses.isEmpty {
                        Text("No buses").foregroundStyle(.secondary)
                    }
                    ForEach(Array(session.draft.buses.enumerated()), id: \.offset) { i, bus in
                        HStack {
                            Text(bus.map(name).joined(separator: ", "))
                            Spacer()
                            Button("Delete", systemImage: "trash", role: .destructive) { delete(i) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in offsets.sorted(by: >).forEach(delete) }
                }
            }
            .navigationTitle("Buses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func name(_ id: String) -> String {
        guard let pin = session.draft.pins.first(where: { $0.id == id }) else { return id }
        return pin.trimmedName.isEmpty ? id : pin.name
    }

    private func toggle(_ id: String) {
        if selected.remove(id) == nil { selected.insert(id) }
    }

    private func create() {
        let order = session.draft.pins.map(\.id).filter(selected.contains)
        session.draft.buses.append(order)
        selected = []
    }

    private func delete(_ index: Int) {
        guard session.draft.buses.indices.contains(index) else { return }
        session.draft.buses.remove(at: index)
    }
}
