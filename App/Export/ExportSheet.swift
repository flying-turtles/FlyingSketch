import ExportKit
import SketchCore
import SwiftUI

struct ExportSheet: View {
    let format: ExportFormat
    let snapshot: SketchDocument
    let selectionIDs: Set<ObjectID>
    let baseName: String

    @Environment(\.dismiss) private var dismiss
    @State private var useSelection: Bool
    @State private var dpi = 300.0
    @State private var background = PNGOptions.Background.white
    @State private var fileURL: URL?
    @State private var errorText: String?

    init(format: ExportFormat, snapshot: SketchDocument, selectionIDs: Set<ObjectID>, baseName: String) {
        self.format = format
        self.snapshot = snapshot
        self.selectionIDs = selectionIDs
        self.baseName = baseName
        _useSelection = State(initialValue: !selectionIDs.isEmpty)
    }

    private var scope: ExportScope { format.usesScope && useSelection && !selectionIDs.isEmpty ? .selection(selectionIDs) : .all }

    private var request: ExportRequest {
        ExportRequest(format: format, scope: scope,
                      png: format == .png ? PNGOptions(dpi: dpi, background: background) : PNGOptions())
    }

    var body: some View {
        NavigationStack {
            Form {
                if format.usesScope {
                    Section("Scope") {
                        Picker("Scope", selection: $useSelection) {
                            Text("Whole drawing").tag(false)
                            Text("Selection (\(selectionIDs.count) objects)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .disabled(selectionIDs.isEmpty)
                    }
                }
                if format == .png {
                    Section("Image") {
                        Picker("Resolution", selection: $dpi) {
                            Text("150 dpi").tag(150.0)
                            Text("300 dpi").tag(300.0)
                            Text("600 dpi").tag(600.0)
                        }
                        .pickerStyle(.segmented)
                        Picker("Background", selection: $background) {
                            Text("White").tag(PNGOptions.Background.white)
                            Text("Transparent").tag(PNGOptions.Background.transparent)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    if let sizeLine { Text(sizeLine).foregroundStyle(.secondary) }
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else if fileURL == nil {
                        HStack { ProgressView(); Text("Preparing…") }
                    }
                    if let fileURL {
                        ShareLink(item: fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    } else {
                        Label("Share", systemImage: "square.and.arrow.up").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(format.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task(id: request) { await generate(request) }
    }

    private func generate(_ request: ExportRequest) async {
        fileURL = nil
        errorText = nil
        do {
            let url = try await ExportJob.run(request, document: snapshot, baseName: baseName)
            guard !Task.isCancelled else { return }
            fileURL = url
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
    }

    private var sizeLine: String? {
        guard format == .png || format == .pdf || format == .svg else { return nil }
        guard let content = try? ExportContent.make(snapshot, scope: scope) else { return nil }
        if format == .png {
            guard let plan = try? RasterExporter.plan(content, options: request.png) else { return nil }
            var line = "\(plan.width) × \(plan.height) px"
            if plan.effectiveDPI < dpi { line += " (reduced to \(Int(plan.effectiveDPI.rounded(.down))) dpi)" }
            return line
        }
        let size = content.bounds.size
        return "\(Int(size.x.rounded())) × \(Int(size.y.rounded())) mm"
    }
}
