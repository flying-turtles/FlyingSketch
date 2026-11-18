import SwiftUI
import CanvasUI
import PhotoPartKit

/// SwiftUI-owned but unobserved reference to the live studio canvas.
final class StudioCanvasHandle {
    weak var view: StudioCanvasView?
}

/// Hosts `StudioCanvasView`. The view does not observe the session, so the session values the app
/// can change (`draft`, `cutoutState`, `mask`) are passed in: any change triggers `updateUIView` → `refresh()`.
struct StudioCanvasRepresentable: UIViewRepresentable {
    let session: StudioSession
    var mode: StudioCanvasMode
    var selectedPinID: String?
    var draft: PhotoPartDraft
    var cutoutState: CutoutState
    var mask: MaskBitmap
    let handle: StudioCanvasHandle
    var onPinSelected: (String) -> Void
    var onError: (PhotoPartError) -> Void

    func makeUIView(context: Context) -> StudioCanvasView {
        let view = StudioCanvasView(session: session)
        handle.view = view // plain reference, not SwiftUI state: no mutation during a view update
        return view
    }

    func updateUIView(_ view: StudioCanvasView, context: Context) {
        view.onPinSelected = onPinSelected
        view.onError = onError
        view.mode = mode
        view.selectedPinID = selectedPinID
        view.refresh()
    }
}
