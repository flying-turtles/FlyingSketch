import UIKit
import SketchCore
import InkEngine

/// Infinite canvas. Two-finger pan + pinch navigate; the viewport persists to the model on gesture end.
public final class CanvasView: UIView, UIGestureRecognizerDelegate {
    let model: DocumentModel
    private let factory = CALayerObjectFactory()
    private(set) var renderer: SceneRenderer!
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private var liveViewport: Viewport?
    private var activeGestures = 0

    private var storedViewport: Viewport

    public var toolState = ToolState()
    private let ink: InkInputController
    private let liveStroke = LiveStrokeLayer()
    var activeTouch: UITouch?
    var interaction: Interaction?
    private(set) var eraser: EraserController!
    private(set) var lasso: LassoController!
    let lassoPath = LassoPathLayer()
    let selectionOverlay = SelectionOverlay()
    /// Selected objects; the app may observe or set it.
    public let selection = SelectionState()
    /// Move gesture in progress: world delta applied so far (visual only until release).
    var moveStart: Vec2?
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
            renderer.showsGrid = showsGrid
            render(settled: true)
        }
    }

    public init(model: DocumentModel) {
        self.model = model
        self.ink = InkInputController(model: model)
        self.storedViewport = model.document.viewport
        super.init(frame: .zero)
        renderer = SceneRenderer(rootLayer: layer, factory: factory)
        backgroundColor = .white
        isMultipleTouchEnabled = true
        layer.addSublayer(liveStroke.layer)
        layer.addSublayer(selectionOverlay.layer)
        layer.addSublayer(lassoPath.layer)

        let lookup: (Rect) -> [SceneObject] = { [weak self] rect in self?.renderer.objects(in: rect) ?? [] }
        eraser = EraserController(model: model, candidates: lookup)
        eraser.onHiddenChange = { [weak self] ids in self?.renderer.hiddenIDs = ids }
        lasso = LassoController(model: model, candidates: lookup)

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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        factory.screenScale = traitCollection.displayScale
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
    }

    // MARK: Touches

    /// Viewport the user currently sees (includes an in-flight pan/pinch).
    var currentViewport: Viewport { liveViewport ?? viewport }

    /// What a touch does. Pencil (or any touch when `pencilOnly` is false) uses the active tool; with
    /// `pencilOnly` a finger selects: tap selects/clears, drag in the selection moves, drag elsewhere lassos.
    enum Interaction {
        case ink, erase, lasso, move
        /// Finger down outside the selection; becomes a lasso once it travels, else a tap on release.
        case pending(start: CGPoint)
    }

    private func interaction(for touch: UITouch) -> Interaction? {
        if touch.type == .pencil || !toolState.pencilOnly {
            switch toolState.kind {
            case .ink: return .ink
            case .eraser: return .erase
            case .lasso: return .lasso
            default: return nil
            }
        }
        let p = location(of: touch)
        if let rect = selectionViewRect, rect.insetBy(dx: -Self.hitSlop, dy: -Self.hitSlop).contains(p) { return .move }
        return .pending(start: p)
    }

    static let hitSlop: CGFloat = 8

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let active = activeTouch, active.type != .pencil, !touches.contains(active),
           touches.contains(where: { $0.type == .direct }) {
            cancelInteraction() // second finger: pan/pinch takes over
            return
        }
        guard activeTouch == nil else { return }
        for touch in touches {
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
        case .pending:
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
            finishLasso()
        case .move:
            endMove()
        case .pending(let start):
            tap(at: start)
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
        case .pending: break
        }
    }

    private func drawLive(_ points: [InkPoint]) {
        liveStroke.update(points: points, tool: activeInkStyle.tool, color: activeInkStyle.color,
                          width: activeInkStyle.width, viewport: currentViewport, viewSize: viewSize)
    }

    private func drawLasso() {
        lassoPath.update(lasso.points, viewport: currentViewport, viewSize: viewSize)
    }

    private func location(of touch: UITouch) -> CGPoint { touch.preciseLocation(in: self) }

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
