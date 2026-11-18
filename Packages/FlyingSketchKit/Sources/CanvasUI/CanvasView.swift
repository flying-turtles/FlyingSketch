import UIKit
import SketchCore
import InkEngine

/// Infinite canvas. Two-finger pan + pinch navigate; the viewport persists to the model on gesture end.
public final class CanvasView: UIView, UIGestureRecognizerDelegate {
    let model: DocumentModel
    let factory = CALayerObjectFactory()
    private(set) var renderer: SceneRenderer!
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private var liveViewport: Viewport?
    private var activeGestures = 0

    private var storedViewport: Viewport
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()
    /// Called on a Pencil double-tap whose system preferred action is not `.ignore`; the app swaps tools.
    public var onPencilDoubleTap: (() -> Void)?

    public var toolState = ToolState() {
        didSet {
            guard toolState.kind != oldValue.kind else { return }
            endTextEditing()
            if oldValue.kind == .wire { endWireSession() }
        }
    }
    /// Snap shape endpoints and text/image placement to the 10 mm grid.
    public var snapsToGrid = false
    /// Font size in mm for newly placed text.
    public var textFontSize: Double = 5
    private(set) var shapes: ShapeController!
    private(set) var wires: WireController!
    var wirePreview: CALayer?
    var wireTouch = WireTouch()
    private(set) var textController: TextController!
    var shapePreview: CALayer?
    var textSession: TextSession?
    private let ink: InkInputController
    private let liveStroke = LiveStrokeLayer()
    var activeTouch: UITouch?
    var interaction: Interaction?
    private(set) var eraser: EraserController!
    private(set) var lasso: LassoController!
    let lassoPath = LassoPathLayer()
    let selectionOverlay = SelectionOverlay()
    private(set) var legs: LegController!
    /// Replacement part + wires shown while a leg is dragged.
    var legPreview: [SceneObject] = []
    /// Accent circles at leg ends of selected legged parts.
    let legHandles: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        l.strokeColor = UIColor.systemBlue.cgColor
        l.lineWidth = 1
        l.isHidden = true
        return l
    }()
    /// Selected objects; the app may observe or set it.
    public let selection: SelectionState
    /// Highlighted net and pin info; the app may supply it (like `selection`) so SwiftUI observes it from the first render.
    public let netHighlight: NetHighlightState
    /// Move gesture in progress: world delta applied so far (visual only until release).
    var moveStart: Vec2?
    /// Ids moved by the in-flight gesture (selection plus carried parts); set once the drag engages.
    var moveSet: Set<ObjectID> = []
    /// Directly dragged ids (the selection at engagement): their parts move rigidly, legs unplug.
    var moveRigid: Set<ObjectID> = []
    var moveDelta: Vec2 = .zero
    var moveEngaged = false
    var editMenu: UIEditMenuInteraction!
    let longPress = UILongPressGestureRecognizer()
    var menuAnchor: CGPoint?
    private var activeInkStyle: (tool: InkTool, color: RGBAColor, width: Double) = (.pen, .black, 0.5)

    public var viewport: Viewport {
        get { storedViewport }
        set {
            storedViewport = newValue
            if liveViewport == nil { render(settled: true) }
        }
    }

    public var showsGrid: Bool = true {
        didSet {
            guard showsGrid != oldValue else { return }
            renderer.showsGrid = showsGrid
            render(settled: true)
        }
    }

    /// `selection` may be supplied by the app so SwiftUI can observe it from the first render.
    public init(model: DocumentModel, selection: SelectionState = SelectionState(),
                netHighlight: NetHighlightState = NetHighlightState()) {
        self.model = model
        self.selection = selection
        self.netHighlight = netHighlight
        self.ink = InkInputController(model: model)
        self.storedViewport = model.document.viewport
        super.init(frame: .zero)
        renderer = SceneRenderer(rootLayer: layer, factory: factory)
        backgroundColor = .white
        isMultipleTouchEnabled = true
        layer.addSublayer(liveStroke.layer)
        layer.addSublayer(selectionOverlay.layer)
        layer.addSublayer(legHandles)
        layer.addSublayer(lassoPath.layer)

        let lookup: (Rect) -> [SceneObject] = { [weak self] rect in self?.renderer.objects(in: rect) ?? [] }
        eraser = EraserController(model: model, candidates: lookup)
        eraser.onHiddenChange = { [weak self] ids in self?.renderer.hiddenIDs = ids }
        lasso = LassoController(model: model, candidates: lookup)
        shapes = ShapeController(model: model)
        wires = WireController(model: model, candidates: lookup)
        legs = LegController(model: model)
        textController = TextController(model: model)

        let previous = model.onChange
        model.onChange = { [weak self] doc in
            previous?(doc)
            self?.documentChanged(doc)
        }
        setUpSelectionUI()

        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        for g in [pan, pinch] as [UIGestureRecognizer] {
            g.delegate = self
            g.addTarget(self, action: #selector(handle(_:)))
            addGestureRecognizer(g)
        }

        // Two-finger tap = undo, three-finger tap = redo. A tap fails once fingers travel (allowableMovement),
        // so it cannot fire after a pan/pinch has begun; the handler also ignores taps during a live gesture.
        for (tap, count, action) in [(undoTap, 2, #selector(handleUndoTap)), (redoTap, 3, #selector(handleRedoTap))] {
            tap.numberOfTouchesRequired = count
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            tap.cancelsTouchesInView = false
            tap.delegate = self
            tap.addTarget(self, action: action)
            addGestureRecognizer(tap)
        }
        addInteraction(UIPencilInteraction(delegate: self))
    }

    /// Undo/redo taps are ignored while a single-touch interaction (typically the Pencil, which fingers never
    /// cancel) is editing: undoing under a live move/leg drag/lasso/erase/shape/ink/wire would desync it.
    static func allowsUndoTap(during interaction: Interaction?) -> Bool {
        switch interaction {
        case nil, .pending, .text, .ignored: true
        case .ink, .erase, .lasso, .move, .shape, .wire, .leg, .wireEnd: false
        }
    }

    @objc func handleUndoTap() {
        guard liveViewport == nil, activeGestures == 0, Self.allowsUndoTap(during: interaction) else { return }
        // An open wire is finished (free end) instead of undone.
        if wires.isOpen { endWireSession(); return }
        if model.undoManager.canUndo { model.undoManager.undo() }
    }

    @objc func handleRedoTap() {
        guard liveViewport == nil, activeGestures == 0, Self.allowsUndoTap(during: interaction) else { return }
        if model.undoManager.canRedo { model.undoManager.redo() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        factory.screenScale = traitCollection.displayScale
        renderer.screenScale = traitCollection.displayScale
        liveStroke.setFrame(bounds)
        selectionOverlay.setFrame(bounds)
        lassoPath.layer.frame = bounds
        render(settled: true)
    }

    var viewSize: Vec2 { Vec2(x: bounds.width, y: bounds.height) }

    func render(settled: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderer.update(document: model.document, viewport: liveViewport ?? viewport, viewSize: viewSize, settled: settled)
        updateSelectionOverlay()
        refreshWirePreview()
        if settled { layoutTextEditor() }
    }

    // MARK: Touches

    /// Viewport the user currently sees (includes an in-flight pan/pinch).
    var currentViewport: Viewport { liveViewport ?? viewport }

    /// What a touch does. Pencil (or any touch when `pencilOnly` is false) uses the active tool; with
    /// `pencilOnly` a finger selects: tap selects/clears, drag in the selection moves, drag elsewhere lassos.
    enum Interaction {
        case ink, erase, lasso, move, shape
        /// Wire tool: draws or continues a wire.
        case wire
        /// Selected part's leg end dragged (lasso tool or finger selection mode).
        case leg(ConnectorRef)
        /// Wire tool: touch-down on an existing wire end drags it.
        case wireEnd
        /// Text tool tap; the editor opens on release.
        case text(start: CGPoint)
        /// Text-tool touch that travelled too far to be a tap; does nothing.
        case ignored
        /// Finger down outside the selection; becomes a lasso once it travels, else a tap on release.
        case pending(start: CGPoint)
    }

    private func interaction(for touch: UITouch) -> Interaction? {
        route(isPencil: touch.type == .pencil, at: location(of: touch))
    }

    /// Routing seam. A drag starting inside the selection moves it for the finger (pencilOnly) and the lasso tool.
    func route(isPencil: Bool, at p: CGPoint) -> Interaction? {
        let insideSelection = selectionViewRect?
            .insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(p) == true
        let selecting = (isPencil || !toolState.pencilOnly) ? toolState.kind == .lasso : true
        if selecting, let end = legEnd(at: p) { return .leg(end) }
        if isPencil || !toolState.pencilOnly {
            switch toolState.kind {
            case .ink: return .ink
            case .eraser: return .erase
            case .lasso: return insideSelection ? .move : .lasso
            case .shape: return .shape
            case .text: return .text(start: p)
            case .wire:
                let w = worldPoint(p)
                let hitsEnd = !wires.isOpen && wires.end(near: w, radius: wireRadius) != nil
                return hitsEnd ? .wireEnd : .wire
            case .image: return nil
            }
        }
        return insideSelection ? .move : .pending(start: p)
    }

    /// Two or more fingers down means pan/pinch/tap gestures own the touches.
    static func isMultiTouch(_ event: UIEvent?) -> Bool {
        (event?.allTouches?.filter { $0.type == .direct }.count ?? 0) > 1
    }

    /// Multi-touch guard applies to finger interactions only: a Pencil interaction is never cancelled by
    /// direct touches, and a new Pencil touch is never blocked by resting fingers.
    static func shouldCancelForMultiTouch(activeIsPencil: Bool?, newTouchIsPencil: Bool, directTouchCount: Int) -> Bool {
        if activeIsPencil == true || newTouchIsPencil { return false }
        return directTouchCount > 1
    }

    /// A Pencil touch-down while a finger interaction (palm, tap, lasso) is active takes over: the finger one is cancelled.
    static func pencilPreemptsFinger(activeIsPencil: Bool?, newTouchIsPencil: Bool) -> Bool {
        newTouchIsPencil && activeIsPencil == false
    }

    static let hitSlop: CGFloat = 8
    /// Max travel (pt) for a text-tool touch to count as a tap.
    static let textTapSlop: CGFloat = 4

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if textSession != nil {
            endTextEditing() // tap elsewhere commits; the tap itself is consumed
            return
        }
        let directCount = event?.allTouches?.filter { $0.type == .direct }.count ?? 0
        if Self.pencilPreemptsFinger(activeIsPencil: activeTouch.map { $0.type == .pencil },
                                     newTouchIsPencil: touches.contains { $0.type == .pencil }) {
            cancelInteraction() // no edit; feedback restored, then the Pencil interaction starts below
        }
        if Self.shouldCancelForMultiTouch(activeIsPencil: activeTouch.map { $0.type == .pencil },
                                          newTouchIsPencil: touches.contains { $0.type == .pencil },
                                          directTouchCount: directCount) {
            cancelInteraction() // two fingers: pan/pinch/tap gestures take over
            return
        }
        if let active = activeTouch, active.type != .pencil, !touches.contains(active),
           touches.contains(where: { $0.type == .direct }) {
            cancelInteraction()
            return
        }
        guard activeTouch == nil else { return }
        for touch in touches {
            // Resting fingers (2+) belong to pan/pinch; only a Pencil may start an interaction then.
            if touch.type == .direct, directCount > 1 { continue }
            guard let kind = interaction(for: touch) else { continue }
            activeTouch = touch
            interaction = kind
            begin(kind, touch, event)
            return
        }
    }

    private func begin(_ kind: Interaction, _ touch: UITouch, _ event: UIEvent?) {
        let coalesced = coalescedSamples(touch, event)
        switch kind {
        case .ink:
            guard case .ink(let tool) = toolState.kind else { return }
            activeInkStyle = (tool, toolState.color, toolState.inkWidth)
            // Coalesced list at began already includes the began touch: start with its first, move with the rest.
            ink.begin(coalesced.first ?? sample(touch), tool: tool, color: toolState.color,
                      width: toolState.inkWidth, params: toolState.params)
            drawLive(ink.move(coalesced: Array(coalesced.dropFirst()), predicted: predictedSamples(touch, event)))
        case .erase:
            let first = coalesced.first ?? sample(touch)
            eraser.begin(at: first.position, radius: EraserController.worldRadius(zoom: currentViewport.zoom))
            for s in coalesced.dropFirst() { eraser.move(to: s.position) }
        case .lasso:
            lasso.begin(at: (coalesced.first ?? sample(touch)).position)
            for s in coalesced.dropFirst() { lasso.move(to: s.position) }
            drawLasso()
        case .move:
            beginMove(at: sample(touch).position)
        case .shape:
            beginShape(at: sample(touch).position, event: event)
        case .wire:
            beginWire(at: sample(touch).position)
        case .wireEnd:
            beginWireEndDrag(at: sample(touch).position)
        case .leg(let ref):
            beginLegDrag(ref, at: sample(touch).position)
        case .pending, .text, .ignored:
            break
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let kind = interaction else { return }
        switch kind {
        case .ink:
            drawLive(ink.move(coalesced: coalescedSamples(touch, event), predicted: predictedSamples(touch, event)))
        case .erase:
            for s in coalescedSamples(touch, event) { eraser.move(to: s.position) }
        case .lasso:
            for s in coalescedSamples(touch, event) { lasso.move(to: s.position) }
            drawLasso()
        case .move:
            updateMove(to: sample(touch).position)
        case .shape:
            moveShape(to: sample(touch).position, event: event)
        case .wire:
            moveWire(to: sample(touch).position)
        case .wireEnd:
            moveWireEnd(to: sample(touch).position)
        case .leg:
            moveLeg(to: sample(touch).position)
        case .text(let start):
            let p = location(of: touch)
            if hypot(p.x - start.x, p.y - start.y) > Self.textTapSlop { interaction = .ignored }
        case .ignored:
            break
        case .pending(let start):
            let p = location(of: touch)
            guard hypot(p.x - start.x, p.y - start.y) > Self.hitSlop else { return }
            interaction = .lasso
            lasso.begin(at: worldPoint(start))
            lasso.move(to: worldPoint(p))
            drawLasso()
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let kind = interaction else { return }
        activeTouch = nil
        interaction = nil
        switch kind {
        case .ink:
            _ = ink.move(coalesced: coalescedSamples(touch, event), predicted: [])
            // One transaction: committed layer appears and live path disappears together.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            ink.end()
            liveStroke.clear()
            CATransaction.commit()
        case .erase:
            for s in coalescedSamples(touch, event) { eraser.move(to: s.position) }
            eraser.end()
            renderer.hiddenIDs = []
        case .lasso:
            for s in coalescedSamples(touch, event) { lasso.move(to: s.position) }
            if !highlightNetOnLassoTap() { finishLasso() }
        case .move:
            endMove()
        case .shape:
            moveShape(to: sample(touch).position, event: event)
            endShape()
        case .wire:
            endWire(at: sample(touch).position)
        case .wireEnd:
            endWireEndDrag(at: sample(touch).position)
        case .leg:
            endLegDrag(at: sample(touch).position)
        case .text(let start):
            beginTextEditing(at: start)
        case .ignored:
            break
        case .pending(let start):
            handleTap(at: start)
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        cancelInteraction()
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { cancelInteraction() }
    }

    func cancelInteraction() {
        guard let kind = interaction else { return }
        activeTouch = nil
        interaction = nil
        switch kind {
        case .ink: ink.cancel(); liveStroke.clear()
        case .erase: eraser.cancel(); renderer.hiddenIDs = []
        case .lasso: lasso.cancel(); lassoPath.clear()
        case .move: cancelMove()
        case .shape: cancelShape()
        case .wire: cancelWireTouch()
        case .wireEnd: cancelWireEndDrag()
        case .leg: cancelLegDrag()
        case .pending, .text, .ignored: break
        }
    }

    private func drawLive(_ points: [InkPoint]) {
        liveStroke.update(points: points, tool: activeInkStyle.tool, color: activeInkStyle.color,
                          width: activeInkStyle.width, viewport: currentViewport, viewSize: viewSize)
    }

    private func drawLasso() {
        lassoPath.update(lasso.points, viewport: currentViewport, viewSize: viewSize)
    }

    func location(of touch: UITouch) -> CGPoint { touch.preciseLocation(in: self) }

    func worldPoint(_ p: CGPoint) -> Vec2 {
        currentViewport.viewToWorld(Vec2(x: p.x, y: p.y), viewSize: viewSize)
    }

    private func coalescedSamples(_ touch: UITouch, _ event: UIEvent?) -> [InkSample] {
        (event?.coalescedTouches(for: touch) ?? [touch]).map(sample)
    }

    private func predictedSamples(_ touch: UITouch, _ event: UIEvent?) -> [InkSample] {
        (event?.predictedTouches(for: touch) ?? []).map(sample)
    }

    private func sample(_ t: UITouch) -> InkSample {
        let loc = t.preciseLocation(in: self)
        let world = currentViewport.viewToWorld(Vec2(x: loc.x, y: loc.y), viewSize: viewSize)
        guard t.type == .pencil else { return InkSample(position: world, timestamp: t.timestamp) }
        let force = t.maximumPossibleForce > 0 ? min(max(Double(t.force / t.maximumPossibleForce), 0), 1) : 0.5
        return InkSample(position: world, force: force, altitude: Double(t.altitudeAngle),
                         azimuth: Double(t.azimuthAngle(in: self)), timestamp: t.timestamp)
    }

    // MARK: Gestures

    @objc private func handle(_ g: UIGestureRecognizer) {
        switch g.state {
        case .began:
            endTextEditing() // editor would drift from the text during pan/pinch: commit first
            activeGestures += 1
            if liveViewport == nil { liveViewport = viewport }
        case .changed:
            guard var v = liveViewport else { return }
            if let pan = g as? UIPanGestureRecognizer {
                let t = pan.translation(in: self)
                v.pan(byView: Vec2(x: t.x, y: t.y))
                pan.setTranslation(.zero, in: self)
            } else if let pinch = g as? UIPinchGestureRecognizer {
                let p = pinch.location(in: self)
                v.zoom(by: pinch.scale, around: Vec2(x: p.x, y: p.y), viewSize: viewSize)
                pinch.scale = 1
            }
            liveViewport = v
            render(settled: false)
        case .ended, .cancelled:
            activeGestures = max(activeGestures - 1, 0)
            if activeGestures == 0, let v = liveViewport { endGesture(with: v) }
        default: break
        }
    }

    /// Persists the viewport; `model.onChange` performs the single settle.
    func endGesture(with v: Viewport) {
        liveViewport = nil
        storedViewport = v
        model.setViewport(v)
    }

    public override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === longPress else { return super.gestureRecognizerShouldBegin(g) }
        switch interaction {
        case nil, .pending: return true
        default: return false
        }
    }

    public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        true
    }
}

extension CanvasView: UIPencilInteractionDelegate {
    public func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard Self.togglesEraser(for: UIPencilInteraction.preferredTapAction) else { return }
        onPencilDoubleTap?()
    }
}

extension CanvasView {
    /// Only the system's "switch eraser" / "switch previous" preferences map to the eraser toggle.
    static func togglesEraser(for action: UIPencilPreferredAction) -> Bool {
        action == .switchEraser || action == .switchPrevious
    }
}
