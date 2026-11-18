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
    /// callers follow up with a `perform` that references them. Throws (adding nothing) when any name is not
    /// `isSafeAssetName`.
    public func addAssets(_ assets: [String: Data]) throws(AssetNameError) {
        guard !assets.isEmpty else { return }
        if let bad = assets.keys.sorted().first(where: { !isSafeAssetName($0) }) { throw .unsafe(bad) }
        document.assets.merge(assets) { _, new in new }
    }

    /// Applies `edits` in order as ONE undo step (inverses applied in reverse). Skipped entirely when the
    /// whole batch is a no-op; fires `onChange` once.
    public func perform(_ edits: [SceneEdit], actionName: String) {
        run(edits, actionName: actionName)
    }

    private func run(_ edit: SceneEdit, actionName: String) {
        run([edit], actionName: actionName)
    }

    private func run(_ edits: [SceneEdit], actionName: String) {
        let before = (objects: document.objects, parts: document.parts)
        var inverses: [SceneEdit] = []
        inverses.reserveCapacity(edits.count)
        for edit in edits { inverses.append(edit.apply(to: &document)) }
        inverses.reverse()
        // No-op edit (e.g. remove of absent ids, replace with identical objects): no undo entry, no onChange.
        guard document.objects != before.objects || document.parts != before.parts else { return }
        undoManager.registerUndo(withTarget: self) { model in
            // While undoing this registers the redo; while redoing, the undo.
            model.run(inverses, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        onChange?(document)
    }
}
