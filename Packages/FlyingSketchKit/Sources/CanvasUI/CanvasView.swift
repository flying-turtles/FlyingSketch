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
    private var activeInkTouch: UITouch?
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

        let previous = model.onChange
        model.onChange = { [weak self] doc in
            previous?(doc)
            self?.render(settled: true)
        }

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
        render(settled: true)
    }

    private var viewSize: Vec2 { Vec2(x: bounds.width, y: bounds.height) }

    private func render(settled: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderer.update(document: model.document, viewport: liveViewport ?? viewport, viewSize: viewSize, settled: settled)
    }

    // MARK: Ink touches

    /// Viewport the user currently sees (includes an in-flight pan/pinch).
    private var currentViewport: Viewport { liveViewport ?? viewport }

    private func acceptsInk(_ touch: UITouch) -> Bool {
        guard case .ink = toolState.kind else { return false }
        return touch.type == .pencil || !toolState.pencilOnly
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeInkTouch == nil, case .ink(let tool) = toolState.kind,
              let touch = touches.first(where: acceptsInk) else { return }
        activeInkTouch = touch
        activeInkStyle = (tool, toolState.color, toolState.inkWidth)
        ink.begin(sample(touch), tool: tool, color: toolState.color, width: toolState.inkWidth, params: toolState.params)
        drawLive(ink.move(coalesced: coalescedSamples(touch, event), predicted: predictedSamples(touch, event)))
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeInkTouch, touches.contains(touch) else { return }
        drawLive(ink.move(coalesced: coalescedSamples(touch, event), predicted: predictedSamples(touch, event)))
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeInkTouch, touches.contains(touch) else { return }
        _ = ink.move(coalesced: coalescedSamples(touch, event), predicted: [])
        activeInkTouch = nil
        // One transaction: committed layer appears and live path disappears together.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ink.end()
        liveStroke.clear()
        CATransaction.commit()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeInkTouch, touches.contains(touch) else { return }
        activeInkTouch = nil
        ink.cancel()
        liveStroke.clear()
    }

    private func drawLive(_ points: [InkPoint]) {
        liveStroke.update(points: points, tool: activeInkStyle.tool, color: activeInkStyle.color,
                          width: activeInkStyle.width, viewport: currentViewport, viewSize: viewSize)
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

    public func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        true
    }
}
