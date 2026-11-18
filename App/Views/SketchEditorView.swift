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
    @State private var canvasHandle = CanvasHandle()
    /// Bumped on undo-manager changes so the buttons re-read canUndo/canRedo.
    @State private var undoTick = 0
    /// Owned here (passed into the canvas) so `body` observes it from the first render.
    @State private var selection = SelectionState()
    @State private var showsParts = false
    @State private var showsInspector = false

    var body: some View {
        CanvasRepresentable(
            model: document.model, selection: selection, toolState: toolState, showsGrid: showsGrid, snapsToGrid: snapsToGrid,
            handle: canvasHandle, onPencilDoubleTap: togglePencilEraser
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            ToolPalette(
                toolState: $toolState, showsGrid: $showsGrid, snapsToGrid: $snapsToGrid,
                canUndo: canUndo, canRedo: canRedo,
                undo: { undoManager?.undo() }, redo: { undoManager?.redo() },
                insertImage: { _ = canvasHandle.view?.insertImage($0) },
                insertStress: insertStress,
                openParts: { showsParts = true },
                accessory: inspectorButton
            )
            .padding(.top, 8)
        }
        .sheet(isPresented: $showsParts) {
            PartsLibraryView { canvasHandle.view?.placePart($0) }
        }
        .onAppear {
            injectUndoManager()
            #if DEBUG
            // Simulator screenshots: `simctl launch … -showPartsLibrary` opens the library sheet.
            if ProcessInfo.processInfo.arguments.contains("-showPartsLibrary") { showsParts = true }
            #endif
        }
        .onChange(of: undoManager) { injectUndoManager() }
        .onReceive(undoNotifications) { _ in undoTick += 1 }
    }

    /// The single selected part and its definition title, if exactly one part is selected.
    private var inspectedPart: (part: PartInstance, title: String)? {
        guard selection.ids.count == 1, let id = selection.ids.first else { return nil }
        let doc = document.model.document
        guard case .part(let p)? = doc.objects.first(where: { $0.id == id }) else { return nil }
        return (p, doc.parts[p.definitionKey]?.title ?? "Part")
    }

    @ViewBuilder private var inspectorButton: some View {
        if let inspected = inspectedPart {
            Button { showsInspector = true } label: { Image(systemName: "info.circle").padding(6) }
                .accessibilityLabel("Inspector")
                .popover(isPresented: $showsInspector) {
                    PartInspectorView(part: inspected.part, title: inspected.title) { label, properties in
                        canvasHandle.view?.updatePartProperties(inspected.part.id, label: label, properties: properties)
                    }
                }
        }
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
