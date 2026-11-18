import Foundation
import Observation

/// Single mutation point for a document. Tools and canvas call `perform`; undo/redo flow through `undoManager`.
@MainActor @Observable
public final class DocumentModel {
    public private(set) var document: SketchDocument

    /// Replaceable so the app can inject the SwiftUI scene's manager. The current value is used at perform time.
    @ObservationIgnored public var undoManager: UndoManager

    /// Called after every perform/undo/redo with the new document.
    @ObservationIgnored public var onChange: ((SketchDocument) -> Void)?

    public init(document: SketchDocument, undoManager: UndoManager = UndoManager()) {
        self.document = document
        self.undoManager = undoManager
    }

    public func perform(_ edit: SceneEdit, actionName: String) {
        run(edit, actionName: actionName)
    }

    /// Persists the viewport (pan/zoom). Fires `onChange`; registers no undo.
    public func setViewport(_ v: Viewport) {
        document.viewport = v
        onChange?(document)
    }

    /// Merges binary assets (images). Not undoable and fires no `onChange`: unreferenced assets are harmless;
    /// callers follow up with a `perform` that references them.
    public func addAssets(_ assets: [String: Data]) {
        guard !assets.isEmpty else { return }
        document.assets.merge(assets) { _, new in new }
    }

    private func run(_ edit: SceneEdit, actionName: String) {
        let inverse = edit.apply(to: &document)
        undoManager.registerUndo(withTarget: self) { model in
            // While undoing this registers the redo; while redoing, the undo.
            model.run(inverse, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        onChange?(document)
    }
}
