import SwiftUI
import UniformTypeIdentifiers
import SketchCore

extension UTType {
    nonisolated static let flySketch = UTType(exportedAs: "com.flyingturtle.flyingsketch.document")
}

/// Reference document wrapping the editing model. Dirty state / autosave are driven by the model's undo
/// registrations on the scene's UndoManager (injected by the editor view). Viewport-only changes register no
/// undo, so they persist with the next edit's save; `snapshot` always carries the current viewport.
final class SketchFileDocument: ReferenceFileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.flySketch]
    nonisolated static let writableContentTypes: [UTType] = [.flySketch]

    let model: DocumentModel

    // SwiftUI creates, reads and snapshots documents on the main thread; the protocol requirements are
    // nonisolated, so assert that instead of hopping.
    nonisolated init() {
        model = MainActor.assumeIsolated { DocumentModel(document: .empty) }
    }

    /// Read errors propagate (DocumentGroup shows them); never falls back to an empty document.
    required nonisolated init(configuration: ReadConfiguration) throws {
        let doc = try DocumentPackage.read(configuration.file)
        model = MainActor.assumeIsolated { DocumentModel(document: doc) }
    }

    nonisolated func snapshot(contentType: UTType) throws -> SketchDocument {
        MainActor.assumeIsolated { model.document }
    }

    nonisolated func fileWrapper(snapshot: SketchDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        try DocumentPackage.fileWrapper(for: snapshot)
    }
}
