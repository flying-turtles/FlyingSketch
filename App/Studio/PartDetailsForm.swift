import SwiftUI
import PhotoPartKit

/// Details step: title, family, label prefix, tags (comma separated) and key/value properties.
struct PartDetailsForm: View {
    @Binding var metadata: PartMetadata
    @State private var tagsText = ""
    @State private var rows: [PropertyRow] = []
    @State private var loaded = false

    private struct PropertyRow: Identifiable, Equatable {
        let id = UUID()
        var key: String
        var value: String
    }

    var body: some View {
        Section("Part") {
            LabeledContent("Title") { TextField("Required", text: $metadata.title).multilineTextAlignment(.trailing) }
            LabeledContent("Family") { TextField("Family", text: $metadata.family).multilineTextAlignment(.trailing) }
            LabeledContent("Label prefix") {
                TextField("U", text: $metadata.labelPrefix)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
        Section {
            TextField("e.g. sensor, i2c", text: $tagsText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text("Tags")
        } footer: {
            Text("Separate tags with commas.")
        }
        Section("Properties") {
            ForEach($rows) { $row in
                HStack {
                    TextField("Key", text: $row.key).autocorrectionDisabled()
                    Divider()
                    TextField("Value", text: $row.value)
                }
            }
            .onDelete { rows.remove(atOffsets: $0) }
            Button("Add property", systemImage: "plus") { rows.append(PropertyRow(key: "", value: "")) }
        }
        .onAppear(perform: load)
        .onChange(of: tagsText) { if loaded { metadata.tags = Self.tags(from: tagsText) } }
        .onChange(of: rows) { if loaded { metadata.properties = Self.properties(from: rows) } }
    }

    /// Seeds the editable text/rows from the metadata each time the step is shown.
    private func load() {
        tagsText = metadata.tags.joined(separator: ", ")
        rows = metadata.properties.sorted { $0.key < $1.key }.map { PropertyRow(key: $0.key, value: $0.value) }
        loaded = true
    }

    private static func tags(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Rows with an empty key are dropped; a repeated key keeps the last value.
    private static func properties(from rows: [PropertyRow]) -> [String: String] {
        var out: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = row.value }
        }
        return out
    }
}
