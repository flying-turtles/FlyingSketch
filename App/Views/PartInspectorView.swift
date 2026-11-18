import SwiftUI
import SketchCore

/// Popover editing one part's label and properties; Save hands the edited values back.
struct PartInspectorView: View {
    let title: String
    let save: (_ label: String, _ properties: [String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var properties: [String: String]

    init(part: PartInstance, title: String, save: @escaping (_ label: String, _ properties: [String: String]) -> Void) {
        self.title = title
        self.save = save
        _label = State(initialValue: part.label)
        _properties = State(initialValue: part.properties)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Label", text: $label).autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                if !properties.isEmpty {
                    Section("Properties") {
                        ForEach(properties.keys.sorted(), id: \.self) { key in
                            LabeledContent(key) {
                                TextField(key, text: binding(for: key)).multilineTextAlignment(.trailing)
                                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(label, properties)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(get: { properties[key] ?? "" }, set: { properties[key] = $0 })
    }
}
