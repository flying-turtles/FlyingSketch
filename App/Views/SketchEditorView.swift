import SwiftUI
import Combine
import SketchCore
import CanvasUI
import PartsKit
import PhotoPartKit
import ExportKit

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
    /// Owned here like `selection` so `body` observes the pin info without touching the canvas from a view update.
    @State private var netHighlight = NetHighlightState()
    @State private var showsParts = false
    @State private var showsInspector = false
    @Environment(PartsLibraryProvider.self) private var partsProvider
    @State private var outdated: [OutdatedPart] = []
    @State private var showsUpdates = false
    /// Bumped to recompute `outdated` (library import, undo/redo of an update).
    @State private var updatesTick = 0
    /// `-photoStudioDemo` (DEBUG): studio over the editor; the saved part is placed on the canvas.
    @State private var demoStudio: StudioSession?
    @Environment(\.documentConfiguration) private var documentConfiguration
    /// Snapshot taken on the main actor when the export sheet opens.
    @State private var exportSession: ExportSession?

    var body: some View {
        CanvasRepresentable(
            model: document.model, selection: selection, netHighlight: netHighlight, toolState: toolState, showsGrid: showsGrid, snapsToGrid: snapsToGrid,
            handle: canvasHandle, onPencilDoubleTap: togglePencilEraser
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                ToolPalette(
                    toolState: $toolState, showsGrid: $showsGrid, snapsToGrid: $snapsToGrid,
                    canUndo: canUndo, canRedo: canRedo,
                    undo: { undoManager?.undo() }, redo: { undoManager?.redo() },
                    insertImage: { _ = canvasHandle.view?.insertImage($0) },
                    insertStress: insertStress,
                    openParts: { showsParts = true },
                    accessory: HStack { exportMenu; updatesButton; inspectorButton }
                )
                pinInfoCard
            }
            .padding(.top, 8)
        }
        .sheet(isPresented: $showsParts) {
            PartsLibraryView(place: { canvasHandle.view?.placePart($0) }, libraryChanged: { updatesTick += 1 })
        }
        .sheet(item: $exportSession) { session in
            ExportSheet(format: session.format, snapshot: session.snapshot, selectionIDs: session.selectionIDs, baseName: session.baseName)
        }
        .sheet(isPresented: $showsUpdates) {
            PartUpdatesView(entries: outdated, update: applyUpdate, updateAll: updateAll)
        }
        .task(id: UpdatesKey(ready: partsProvider.library != nil, tick: updatesTick)) { await refreshOutdated() }
        .onReceive(undoRedoNotifications) { _ in updatesTick += 1 }
        .onAppear {
            injectUndoManager()
            #if DEBUG
            // Simulator screenshots: `simctl launch … -showPartsLibrary` opens the library sheet.
            if ProcessInfo.processInfo.arguments.contains("-showPartsLibrary") { showsParts = true }
            if PhotoStudioDemo.claim() { demoStudio = PhotoStudioDemo.makeSession() }
            #endif
        }
        .onChange(of: undoManager) { injectUndoManager() }
        .fullScreenCover(isPresented: Binding(get: { demoStudio != nil }, set: { if !$0 { demoStudio = nil } })) {
            demoStudioContent
        }
        .onReceive(undoNotifications) { _ in undoTick += 1 }
    }

    @ViewBuilder private var demoStudioContent: some View {
        if let session = demoStudio, let library = partsProvider.library {
            PhotoPartStudioView(session: session, library: library,
                                onSave: { canvasHandle.view?.placePart($0); demoStudio = nil; updatesTick += 1 },
                                onCancel: { demoStudio = nil })
        } else {
            ProgressView()
        }
    }

    private struct UpdatesKey: Equatable {
        var ready: Bool
        var tick: Int
    }

    private struct ExportSession: Identifiable {
        let id = UUID()
        var format: ExportFormat
        var snapshot: SketchDocument
        var selectionIDs: Set<ObjectID>
        var baseName: String
    }

    private var exportMenu: some View {
        Menu {
            ForEach(ExportFormat.allCases) { format in
                Button(format.title) { openExport(format) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").padding(6)
        }
        .accessibilityLabel("Export")
    }

    private func openExport(_ format: ExportFormat) {
        let name = documentConfiguration?.fileURL?.deletingPathExtension().lastPathComponent ?? ""
        exportSession = ExportSession(format: format, snapshot: document.model.document, selectionIDs: selection.ids,
                                      baseName: name.isEmpty ? "Sketch" : name)
    }

    @ViewBuilder private var updatesButton: some View {
        if !outdated.isEmpty {
            Button { showsUpdates = true } label: {
                Label("Updates (\(outdated.count))", systemImage: "arrow.triangle.2.circlepath").padding(6)
            }
        }
    }

    /// Compares the document's embedded definitions with the library; the library read runs off the main actor.
    private func refreshOutdated() async {
        guard let library = partsProvider.library, let view = canvasHandle.view else { return }
        let all = await library.allParts()
        guard !Task.isCancelled else { return }
        outdated = view.outdatedParts(comparedTo: all).map { OutdatedPart(current: $0.current, newer: $0.newer) }
        if outdated.isEmpty { showsUpdates = false }
    }

    private func applyUpdate(_ entry: OutdatedPart) {
        canvasHandle.view?.updatePart(libraryID: entry.current.libraryID, to: entry.newer)
        updatesTick += 1
    }

    /// One edit per part, sequential.
    private func updateAll() {
        for entry in outdated { canvasHandle.view?.updatePart(libraryID: entry.current.libraryID, to: entry.newer) }
        updatesTick += 1
    }

    @ViewBuilder private var pinInfoCard: some View {
        if let info = netHighlight.info {
            Text(info.summary)
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
                .accessibilityLabel(info.summary)
        }
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

    private var undoRedoNotifications: some Publisher<Notification, Never> {
        let c = NotificationCenter.default
        return Publishers.Merge(c.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager),
                                c.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager))
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
