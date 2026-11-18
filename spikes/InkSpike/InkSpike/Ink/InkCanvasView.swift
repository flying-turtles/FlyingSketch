import QuartzCore
import UIKit

enum ActiveStrokeRenderer: String {
    case coreAnimation = "Core Animation"
    case metal = "Metal"
}

/// Custom ink canvas. Finished strokes are always CAShapeLayers (approach C).
/// Only the live stroke under the Pencil differs: CAShapeLayer vs a Metal overlay.
final class InkCanvasView: UIView {
    let renderer: ActiveStrokeRenderer
    let settings: InkSettings

    private let committedLayer = CALayer()
    private let activeShapeLayer = CAShapeLayer()
    private var metalView: MetalStrokeView?

    private var activeTouch: UITouch?
    private var builder: StrokeBuilder?

    private var latencySum: Double = 0
    private var latencyCount = 0
    private var lastLatencyPublish: CFTimeInterval = 0

    init(renderer: ActiveStrokeRenderer, settings: InkSettings) {
        self.renderer = renderer
        self.settings = settings
        super.init(frame: .zero)
        backgroundColor = .white
        isMultipleTouchEnabled = false
        layer.addSublayer(committedLayer)

        switch renderer {
        case .coreAnimation:
            activeShapeLayer.fillColor = UIColor.black.cgColor
            activeShapeLayer.fillRule = .nonZero
            layer.addSublayer(activeShapeLayer)
        case .metal:
            let mv = MetalStrokeView()
            mv.isUserInteractionEnabled = false
            addSubview(mv)
            metalView = mv
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.frame = bounds
        activeShapeLayer.frame = bounds
        CATransaction.commit()
        metalView?.frame = bounds
    }

    func clear() {
        committedLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        activeShapeLayer.path = nil
        metalView?.render(triangles: [])
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        if settings.pencilOnly && touch.type != .pencil { return }
        activeTouch = touch
        builder = StrokeBuilder(params: settings.strokeParams)
        ingest(touch, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        ingest(touch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        ingest(touch, event: event, final: true)
        commitStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        commitStroke()
    }

    private func ingest(_ touch: UITouch, event: UIEvent?, final: Bool = false) {
        guard var builder else { return }
        let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
        for t in coalesced { builder.add(sample(t)) }
        self.builder = builder
        guard !final else { return }

        let predicted = settings.usePrediction ? (event?.predictedTouches(for: touch) ?? []).map(sample) : []
        let points = StrokeGeometry.smooth(builder.points(predicted: predicted))
        drawActive(points)
        recordLatency(since: touch.timestamp)
    }

    private func sample(_ t: UITouch) -> InkSample {
        let pressure: Double
        if t.type == .pencil || t.maximumPossibleForce > 0, t.force > 0 {
            pressure = min(Double(t.force / max(t.maximumPossibleForce, 0.0001)), 1)
        } else {
            pressure = 0.5
        }
        return InkSample(location: t.preciseLocation(in: self), pressure: pressure, time: t.timestamp)
    }

    private func drawActive(_ points: [StrokePoint]) {
        switch renderer {
        case .coreAnimation:
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            activeShapeLayer.path = StrokeGeometry.outlinePath(points)
            CATransaction.commit()
        case .metal:
            metalView?.render(triangles: StrokeGeometry.triangles(points))
        }
    }

    private func commitStroke() {
        defer {
            activeTouch = nil
            builder = nil
        }
        guard let builder, !builder.committed.isEmpty else { return }
        let points = StrokeGeometry.smooth(builder.committed)
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.fillColor = UIColor.black.cgColor
        shape.fillRule = .nonZero
        shape.path = StrokeGeometry.outlinePath(points)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedLayer.addSublayer(shape)
        activeShapeLayer.path = nil
        CATransaction.commit()
        metalView?.render(triangles: [])
    }

    // MARK: - Stats

    private func recordLatency(since timestamp: TimeInterval) {
        let now = CACurrentMediaTime()
        latencySum += (now - timestamp) * 1000
        latencyCount += 1
        if now - lastLatencyPublish > 0.25 {
            settings.latencyMs[renderer.rawValue] = latencySum / Double(latencyCount)
            latencySum = 0
            latencyCount = 0
            lastLatencyPublish = now
        }
    }
}
