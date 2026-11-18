import SwiftUI
import CanvasUI
import PartsKit
import PhotoPartKit

/// Full-screen photo-part studio: step bar (Cutout · Refine · Crop · Scale · Pins · Details) over the
/// studio canvas and a per-step control panel. Saves the built part plus its studio files to `library`.
struct PhotoPartStudioView: View {
    @Bindable var session: StudioSession
    let library: PartsLibrary
    let onSave: (LibraryPart) -> Void
    let onCancel: () -> Void

    @State private var initialDraft: PhotoPartDraft
    @State private var initialMask: MaskBitmap
    @State private var canvasHandle = StudioCanvasHandle()
    @State private var tracing = false
    @State private var scaleState: ScaleState
    @State private var editingPinID: String?
    @State private var showsBuses = false
    @State private var confirmsDiscard = false
    @State private var saving = false
    @State private var alertMessage: String?

    init(session: StudioSession, library: PartsLibrary,
         onSave: @escaping (LibraryPart) -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.library = library
        self.onSave = onSave
        self.onCancel = onCancel
        _initialDraft = State(initialValue: session.draft)
        _initialMask = State(initialValue: session.mask)
        _scaleState = State(initialValue: ScaleState(session.draft.scale))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StudioStepBar(step: $session.step)
                Divider()
                HStack(spacing: 0) {
                    canvas
                    Divider()
                    panel.frame(width: 360)
                }
            }
            .navigationTitle(session.draft.metadata.title.isEmpty ? "New Photo Part" : session.draft.metadata.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled()
        .disabled(saving)
        .overlay { if saving { savingOverlay } }
        .task { await runFirstCutout() }
        .onChange(of: session.step) { tracing = false; editingPinID = nil }
        .onChange(of: session.mask) { tracing = false } // one trace replaces the mask, then back to viewing
        .onChange(of: session.draft.scale) { old, new in adoptTypedDistance(old: old, new: new) }
        .sheet(isPresented: $showsBuses) { BusEditorView(session: session) }
        .alert("Photo part", isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        #if DEBUG
        .onAppear(perform: applyDemoArguments)
        #endif
    }

    // MARK: Canvas

    private var canvasMode: StudioCanvasMode {
        switch session.step {
        case .cutout:
            if case .choosing = session.cutoutState { return .chooseInstance }
            return tracing ? .trace : .view
        case .refine: return .brush
        case .crop: return .crop
        case .scale: return scaleState.mode == .twoPoints ? .calibrate : .view
        case .pins: return .pins
        case .details: return .view
        }
    }

    private var canvas: some View {
        StudioCanvasRepresentable(
            session: session, mode: canvasMode, selectedPinID: session.step == .pins ? editingPinID : nil,
            draft: session.draft, cutoutState: session.cutoutState, mask: session.mask, handle: canvasHandle,
            onPinSelected: { editingPinID = $0 },
            onError: { alertMessage = $0.message(in: session.draft) })
        .padding(20) // keeps crop handles and edge pins clear of the panel and screen edges
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .topTrailing) {
            Button("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { canvasHandle.view?.fitToBounds() }
                .labelStyle(.iconOnly)
                .padding(10)
                .background(.regularMaterial, in: Circle())
                .padding(12)
                .accessibilityLabel("Fit to screen")
        }
    }

    // MARK: Panel

    private var panel: some View {
        ScrollViewReader { proxy in
            panelForm
                .onChange(of: editingPinID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
        }
        .modifier(PinEditorPresenter(session: session, editingPinID: $editingPinID))
    }

    private var panelForm: some View {
        Form {
            switch session.step {
            case .cutout: CutoutControls(session: session, tracing: $tracing)
            case .refine: RefineControls(session: session)
            case .crop: CropControls(session: session)
            case .scale: ScaleControls(session: session, state: $scaleState)
            case .pins: PinsStepControls(session: session, editingPinID: $editingPinID, showsBuses: $showsBuses)
            case .details: PartDetailsForm(metadata: $session.draft.metadata)
            }
            if let error = session.blockingError {
                Section("Before saving") {
                    Label(error.message(in: session.draft), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { if hasChanges { confirmsDiscard = true } else { onCancel() } }
                .confirmationDialog("Discard photo part?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                    Button("Discard", role: .destructive, action: onCancel)
                    Button("Keep editing", role: .cancel) {}
                }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save).disabled(session.blockingError != nil || saving)
        }
    }

    private var savingOverlay: some View {
        ProgressView("Saving…")
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    /// Compared only on Cancel (mask equality is a full-bitmap compare).
    private var hasChanges: Bool { session.draft != initialDraft || session.mask != initialMask }

    /// The first automatic cutout is not a user change: re-baseline the mask for the Cancel confirmation.
    private func runFirstCutout() async {
        guard session.cutoutState == .idle else { return }
        let before = session.mask
        await session.runAutoCutout()
        if initialMask == before { initialMask = session.mask }
    }

    /// A calibration placed on the canvas starts at the default distance; apply the distance typed beforehand.
    private func adoptTypedDistance(old: ScaleSpec?, new: ScaleSpec?) {
        guard case let .twoPoints(a, b, mm)? = new else { return }
        if case .twoPoints? = old { return }
        if mm != scaleState.twoPointMM { session.draft.scale = .twoPoints(a, b, mm: scaleState.twoPointMM) }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let part = try session.build()
                let files = try session.studioFiles().encoded()
                try await library.save(part, studio: files)
                onSave(part)
            } catch let error as PhotoPartError {
                alertMessage = error.message(in: session.draft)
            } catch {
                alertMessage = "The part couldn't be saved: \(error.localizedDescription)"
            }
        }
    }

    #if DEBUG
    /// Simulator screenshots: `-photoStudioStep <n>` opens step n, `-photoStudioPin` opens the last pin's editor,
    /// `-photoStudioBuses` the bus sheet, `-photoStudioSave` saves.
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-photoStudioStep"), i + 1 < args.count,
           let n = Int(args[i + 1]), let step = StudioStep(rawValue: n) {
            session.step = step
        }
        // After the step's onChange (which clears the pin editor) and the panel's first layout.
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            if args.contains("-photoStudioPin") { editingPinID = session.draft.pins.last?.id }
            if args.contains("-photoStudioBuses") { showsBuses = true }
            if args.contains("-photoStudioSave"), session.blockingError == nil { save() }
        }
    }
    #endif
}

/// Back · step segments · Next. Steps can be revisited freely.
struct StudioStepBar: View {
    @Binding var step: StudioStep

    var body: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left") { move(-1) }
                .disabled(step == StudioStep.allCases.first)
            Picker("Step", selection: $step) {
                ForEach(StudioStep.allCases, id: \.self) { s in
                    Text("\(s.rawValue + 1). \(s.title)").tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 720)
            Button("Next", systemImage: "chevron.right") { move(1) }
                .disabled(step == StudioStep.allCases.last)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func move(_ d: Int) {
        if let next = StudioStep(rawValue: step.rawValue + d) { step = next }
    }
}
