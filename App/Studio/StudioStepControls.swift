import SwiftUI
import PhotoPartKit
import SketchCore

// Form sections for the Cutout, Refine, Crop and Scale steps (Pins: `PinsStepControls`, Details: `PartDetailsForm`).

struct CutoutControls: View {
    let session: StudioSession
    @Binding var tracing: Bool

    var body: some View {
        Section {
            status
            if case .choosing = session.cutoutState {
                Button("Keep all") { session.chooseAllInstances() }
            }
        } header: {
            Text("Cutout")
        }
        Section {
            Button(tracing ? "Cancel trace" : "Trace outline", systemImage: "lasso") { tracing.toggle() }
                .disabled(isBusyOrChoosing)
            Button("Whole photo", systemImage: "photo") {
                tracing = false
                session.useWholePhoto()
            }
            Button("Retry auto", systemImage: "wand.and.stars") {
                tracing = false
                Task { await session.runAutoCutout() }
            }
            .disabled(session.cutoutState == .running)
        } footer: {
            if tracing { Text("Draw around the part with your finger or Apple Pencil.") }
        }
    }

    private var isBusyOrChoosing: Bool {
        switch session.cutoutState {
        case .running, .choosing: true
        case .idle, .done, .failed: false
        }
    }

    @ViewBuilder private var status: some View {
        switch session.cutoutState {
        case .idle, .running:
            HStack(spacing: 10) {
                ProgressView()
                Text("Finding the part…")
            }
        case .choosing(let count):
            VStack(alignment: .leading, spacing: 4) {
                Text("Tap the part to keep").font(.headline)
                Text("\(count) parts found").font(.subheadline).foregroundStyle(.secondary)
            }
        case .done:
            Label("Cutout ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label("Automatic cutout unavailable — trace the outline or use the whole photo",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct RefineControls: View {
    @Bindable var session: StudioSession

    var body: some View {
        Section {
            Picker("Brush", selection: $session.brushAdds) {
                Text("Add").tag(true)
                Text("Erase").tag(false)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading) {
                Text("Brush size: \(Int(session.brushRadius)) px")
                Slider(value: $session.brushRadius, in: 2...200)
            }
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { session.undoMask() }
                    .disabled(!session.canUndoMask)
                Spacer()
                Button("Redo", systemImage: "arrow.uturn.forward") { session.redoMask() }
                    .disabled(!session.canRedoMask)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Refine")
        } footer: {
            Text("Paint to add to or erase from the cutout. Pinch and drag with two fingers to zoom and pan.")
        }
    }
}

struct CropControls: View {
    @Bindable var session: StudioSession

    /// `draft.crop.angle` (radians) shown in degrees, −45…45.
    private var degrees: Binding<Double> {
        Binding(get: { session.draft.crop.angle * 180 / .pi },
                set: { session.draft.crop.angle = min(max($0, -45), 45) * .pi / 180 })
    }

    var body: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Straighten: \(degrees.wrappedValue, format: .number.precision(.fractionLength(1)))°")
                Slider(value: degrees, in: -45...45)
            }
            HStack {
                Button("Rotate left", systemImage: "rotate.left") { turn(by: 3) }
                Spacer()
                Button("Rotate right", systemImage: "rotate.right") { turn(by: 1) }
            }
            .buttonStyle(.borderless)
            Button("Reset crop", systemImage: "arrow.counterclockwise") {
                session.draft.crop = .full(session.draft.sourceSize)
            }
        } header: {
            Text("Crop")
        } footer: {
            Text("Drag the corners to crop; drag inside the frame to move it.")
        }
    }

    private func turn(by n: Int) {
        session.draft.crop.quarterTurns = (session.draft.crop.quarterTurns + n) % 4
    }
}

/// Scale-step view state kept by the studio, so leaving the step doesn't forget it.
struct ScaleState {
    enum Mode: Hashable { case twoPoints, width }
    var mode: Mode
    /// The last `.twoPoints` scale, restored when switching back from width mode.
    var savedTwoPoints: ScaleSpec?
    var twoPointMM: Double
    var widthMM: Double

    init(_ scale: ScaleSpec?) {
        switch scale {
        case let .width(mm)?:
            mode = .width; twoPointMM = 2.54; widthMM = mm
        case let .twoPoints(_, _, mm)?:
            mode = .twoPoints; twoPointMM = mm; widthMM = 0
        case nil:
            mode = .twoPoints; twoPointMM = 2.54; widthMM = 0
        }
    }
}

struct ScaleControls: View {
    @Bindable var session: StudioSession
    @Binding var state: ScaleState

    private static let mmFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3))
    private static let sizeFormat = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))

    var body: some View {
        Section {
            Picker("Method", selection: modeBinding) {
                Text("Two points").tag(ScaleState.Mode.twoPoints)
                Text("Overall width").tag(ScaleState.Mode.width)
            }
            .pickerStyle(.segmented)
            switch state.mode {
            case .twoPoints:
                LabeledContent("Distance") {
                    HStack {
                        TextField("mm", value: twoPointMM, format: Self.mmFormat)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
            case .width:
                LabeledContent("Width") {
                    HStack {
                        TextField("mm", value: widthMM, format: Self.mmFormat)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        Text("mm").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Scale")
        } footer: {
            if state.mode == .twoPoints {
                Text("Tap two points a known distance apart, e.g. neighbouring pins 2.54 mm apart. Drag a point to adjust it.")
            }
        }
        Section("Part size") { partSize }
    }

    @ViewBuilder private var partSize: some View {
        let draft = session.draft
        switch Result(catching: { try draft.mmPerPixel() }) {
        case .success(let mm):
            let o = draft.outputSize()
            Text("\(o.x * mm, format: Self.sizeFormat) × \(o.y * mm, format: Self.sizeFormat) mm")
                .font(.title3.monospacedDigit())
        case .failure(let error):
            Text((error as? PhotoPartError)?.message(in: draft) ?? error.localizedDescription)
                .foregroundStyle(.secondary)
        }
    }

    private var modeBinding: Binding<ScaleState.Mode> {
        Binding(get: { state.mode }, set: { next in
            guard next != state.mode else { return }
            switch next {
            case .width:
                if case .twoPoints? = session.draft.scale { state.savedTwoPoints = session.draft.scale }
                session.draft.scale = state.widthMM > 0 ? .width(mm: state.widthMM) : nil
            case .twoPoints:
                session.draft.scale = state.savedTwoPoints
            }
            state.mode = next
        })
    }

    private var twoPointMM: Binding<Double> {
        Binding(get: { state.twoPointMM }, set: { mm in
            state.twoPointMM = mm
            if case let .twoPoints(a, b, _)? = session.draft.scale { session.draft.scale = .twoPoints(a, b, mm: mm) }
        })
    }

    private var widthMM: Binding<Double> {
        Binding(get: { state.widthMM }, set: { mm in
            state.widthMM = mm
            session.draft.scale = mm > 0 ? .width(mm: mm) : nil
        })
    }
}
