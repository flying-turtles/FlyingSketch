import SwiftUI
import UniformTypeIdentifiers
import Foundation
import SketchCore

extension UTType {
    nonisolated static let flySketch = UTType(exportedAs: "com.flyingturtle.flyingsketch.document")
}

/// Thread-safe holder of the latest document value. `snapshot`/init run on whatever thread SwiftUI picks,
/// so they only touch this box (lock-protected), never main-actor state.
nonisolated final class DocumentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SketchDocument
    init(_ value: SketchDocument) { self.value = value }
    var current: SketchDocument {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Reference document. Nonisolated inits/snapshot touch only `box`; the `DocumentModel` is created lazily on
/// the main actor (first access from the editor) and mirrors every change into `box` via `onChange`.
/// Dirty state / autosave are driven by the model's undo registrations on the scene's UndoManager.
/// Viewport-only changes register no undo, so they persist with the next edit's save (the box always holds
/// the current viewport, so snapshots include it).
final class SketchFileDocument: ReferenceFileDocument {
    nonisolated static let readableContentTypes: [UTType] = [.flySketch]
    nonisolated static let writableContentTypes: [UTType] = [.flySketch]

    private nonisolated let box: DocumentBox

    nonisolated init() {
        box = DocumentBox(.empty)
    }

    /// Read errors propagate (DocumentGroup shows them); never falls back to an empty document.
    required nonisolated init(configuration: ReadConfiguration) throws {
        box = DocumentBox(try DocumentPackage.read(configuration.file))
    }

    // Only read/written inside the @MainActor `model` accessor.
    private nonisolated(unsafe) var _model: DocumentModel?

    @MainActor var model: DocumentModel {
        if let _model { return _model }
        let m = DocumentModel(document: box.current)
        let box = box
        let previous = m.onChange
        m.onChange = { doc in
            previous?(doc)
            box.current = doc
        }
        _model = m
        return m
    }

    nonisolated func snapshot(contentType: UTType) throws -> SketchDocument {
        box.current
    }

    nonisolated func fileWrapper(snapshot: SketchDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        try DocumentPackage.fileWrapper(for: snapshot)
    }
}
