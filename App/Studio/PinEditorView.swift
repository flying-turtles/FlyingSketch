import SwiftUI
import PhotoPartKit
import SketchCore

/// Popover editing one pin: name, kind, role, description, delete.
struct PinEditorView: View {
    @Binding var pin: DraftPin
    var issue: String?
    var onDelete: () -> Void

    var body: some View {
        Form {
            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            LabeledContent("Name") {
                TextField("Name", text: $pin.name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            Picker("Kind", selection: $pin.kind) {
                ForEach(ConnectorKind.pickerCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Role", selection: $pin.role) {
                Text("None").tag(PinRole?.none)
                ForEach(PinRole.pickerCases, id: \.self) { Text($0.title).tag(PinRole?.some($0)) }
            }
            TextField("Description", text: $pin.description, axis: .vertical)
                .lineLimit(1...4)
            Button("Delete pin", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .frame(minWidth: 320, idealWidth: 340, minHeight: 300, idealHeight: 300)
    }
}

/// Pins step: grid snap, pin list (tap a row or a canvas pin to edit it), buses.
struct PinsStepControls: View {
    @Bindable var session: StudioSession
    /// Pin whose editor popover is open (also highlighted on the canvas).
    @Binding var editingPinID: String?
    @Binding var showsBuses: Bool

    var body: some View {
        let issues = session.draft.pinIssues()
        Section {
            Toggle("Snap to 2.54 mm grid", isOn: $session.draft.gridSnap)
            Button("Buses…", systemImage: "point.3.connected.trianglepath.dotted") { showsBuses = true }
                .disabled(session.draft.pins.count < 2)
        } header: {
            Text("Pins")
        } footer: {
            Text("Tap the part to add a pin, drag a pin to move it, tap a pin to edit it.")
        }
        Section("\(session.draft.pins.count) pins") {
            if session.draft.pins.isEmpty {
                Text("No pins yet").foregroundStyle(.secondary)
            }
            ForEach(session.draft.pins, id: \.id) { pin in
                row(pin, issue: issues[pin.id])
            }
        }
    }

    private func row(_ pin: DraftPin, issue: String?) -> some View {
        Button { editingPinID = pin.id } label: {
            HStack {
                Circle().fill(Color(StudioRoleColor.color(for: pin.role))).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.trimmedName.isEmpty ? "Unnamed" : pin.name)
                        .foregroundStyle(pin.trimmedName.isEmpty ? .secondary : .primary)
                    Text([pin.kind.title, pin.role?.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let issue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(editingPinID == pin.id ? Color.accentColor.opacity(0.15) : nil)
        .popover(isPresented: presented(pin.id), arrowEdge: .trailing) {
            if let binding = binding(for: pin) {
                PinEditorView(pin: binding, issue: session.draft.pinIssues()[pin.id]) {
                    editingPinID = nil
                    session.draft.removePin(pin.id)
                }
            }
        }
    }

    private func presented(_ id: String) -> Binding<Bool> {
        Binding(get: { editingPinID == id }, set: { if !$0, editingPinID == id { editingPinID = nil } })
    }

    /// Looks the pin up by id on every access (indices shift when pins are deleted).
    private func binding(for pin: DraftPin) -> Binding<DraftPin>? {
        guard session.draft.pins.contains(where: { $0.id == pin.id }) else { return nil }
        return Binding(
            get: { session.draft.pins.first(where: { $0.id == pin.id }) ?? pin },
            set: { new in
                if let i = session.draft.pins.firstIndex(where: { $0.id == pin.id }) { session.draft.pins[i] = new }
            })
    }
}

/// Mirrors the canvas pin marker colours (`StudioOverlayLayers.color(for:)` is internal to CanvasUI).
enum StudioRoleColor {
    static func color(for role: PinRole?) -> UIColor {
        switch role {
        case .power?: .systemRed
        case .ground?: UIColor(white: 0.15, alpha: 1)
        case .digital?: .systemBlue
        case .analog?: .systemGreen
        case .i2cSDA?, .i2cSCL?: .systemPurple
        case .spi?: .systemOrange
        case .uart?: .systemTeal
        case .other?, nil: .systemGray
        }
    }
}
