import SwiftUI
import Combine
import SketchCore
import CanvasUI

struct SketchEditorView: View {
    let document: SketchFileDocument
    @Environment(\.undoManager) private var undoManager
    @State private var toolState = ToolState()
    @State private var previousKind: ToolKind = .ink(.pen)
    @State private var showsGrid = true
    @State private var snapsToGrid = false
    @State private var canvas: CanvasView?
    /// Bumped on undo-manager changes so the buttons re-read canUndo/canRedo.
    @State private var undoTick = 0

    var body: some View {
        CanvasRepresentable(
            model: document.model, toolState: toolState, showsGrid: showsGrid, snapsToGrid: snapsToGrid,
            onCanvas: { canvas = $0 }, onPencilDoubleTap: togglePencilEraser
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            ToolPalette(
                toolState: $toolState, showsGrid: $showsGrid, snapsToGrid: $snapsToGrid,
                canUndo: canUndo, canRedo: canRedo,
                undo: { undoManager?.undo() }, redo: { undoManager?.redo() },
                insertImage: { _ = canvas?.insertImage($0) },
                insertStress: insertStress
            )
            .padding(.top, 8)
        }
        .onAppear(perform: injectUndoManager)
        .onChange(of: undoManager) { injectUndoManager() }
        .onReceive(undoNotifications) { _ in undoTick += 1 }
    }

    private var undoNotifications: some Publisher<Notification, Never> {
        let c = NotificationCenter.default
        // Never observe .NSUndoManagerCheckpoint: `canRedo` (read in `body`) posts it, which would
        // re-render `body` forever (main thread pinned, blank editor).
        return Publishers.MergeMany([
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
        ].map { c.publisher(for: $0, object: undoManager) })
    }

    private var canUndo: Bool { _ = undoTick; return undoManager?.canUndo ?? false }
    private var canRedo: Bool { _ = undoTick; return undoManager?.canRedo ?? false }

    private func injectUndoManager() {
        if let undoManager { document.model.undoManager = undoManager }
        undoTick += 1
    }

    private func togglePencilEraser() {
        if toolState.kind == .eraser {
            toolState.kind = previousKind
        } else {
            previousKind = toolState.kind
            toolState.kind = .eraser
        }
    }

    private func insertStress() {
        #if DEBUG
        document.model.perform(.insert(SketchDocument.fixtureGrid(strokes: 5000, spacing: 20).objects, at: nil),
                               actionName: "Insert Stress Fixture")
        #endif
    }
}
