import UIKit
import SketchCore

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
        self.storedViewport = model.document.viewport
        super.init(frame: .zero)
        renderer = SceneRenderer(rootLayer: layer, factory: factory)
        backgroundColor = .white

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
        render(settled: true)
    }

    private var viewSize: Vec2 { Vec2(x: bounds.width, y: bounds.height) }

    private func render(settled: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        renderer.update(document: model.document, viewport: liveViewport ?? viewport, viewSize: viewSize, settled: settled)
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
