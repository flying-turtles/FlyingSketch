import UIKit
import Observation
import SketchCore
import NetKit

/// Pin under the last net-highlight tap.
public struct PinInfo: Equatable, Sendable {
    public var partLabel: String
    public var connectorName: String
    public var role: PinRole?
    /// nil: the pin is on no net (R5: bus-only nets are omitted).
    public var netName: String?
    /// Connectors in the net (0 without a net).
    public var memberCount: Int

    public init(partLabel: String, connectorName: String, role: PinRole? = nil, netName: String? = nil, memberCount: Int = 0) {
        self.partLabel = partLabel
        self.connectorName = connectorName
        self.role = role
        self.netName = netName
        self.memberCount = memberCount
    }

    /// "R1 · leg1 — N3 (4 pins)", "U1 · GPIO4 · digital — N3 (4 pins)", "R1 · leg1 — no connection".
    public var summary: String {
        var head = "\(partLabel) · \(connectorName)"
        if let role { head += " · \(role.rawValue)" }
        guard let netName else { return "\(head) — no connection" }
        return "\(head) — \(netName) (\(memberCount) \(memberCount == 1 ? "pin" : "pins"))"
    }
}

/// Highlighted net + pin info, owned by `CanvasView` (the app may inject its own instance to observe it).
@Observable
public final class NetHighlightState {
    public internal(set) var info: PinInfo?
    var net: Net?
    /// Tapped connector; the highlight follows it across edits.
    var anchor: ConnectorRef?
    /// Nets of the last document parts/objects they were computed from.
    @ObservationIgnored var cache: (objects: [SceneObject], parts: [String: PartDefinition], nets: [Net])?

    public init() {}
}

/// World-space geometry of a highlighted net.
struct NetOverlay: Equatable {
    var rings: [Vec2]
    /// Polylines of the net's wires with their (un-widened) width, mm.
    var wires: [(id: ObjectID, points: [Vec2], width: Double)]

    static func == (a: NetOverlay, b: NetOverlay) -> Bool {
        a.rings == b.rings && a.wires.count == b.wires.count
            && zip(a.wires, b.wires).allSatisfy { $0.id == $1.id && $0.points == $1.points && $0.width == $1.width }
    }
}

/// Connector rings (above parts) and wire glow (each glow layer sits in the objects layer directly beneath its wire),
/// repainted in view space on every settle.
final class NetOverlayLayers {
    static let ringRadius = 1.2
    static let glowExtra = 1.2
    static let glowAlpha: CGFloat = 0.35
    static let accent = UIColor.systemBlue

    /// Glow layers currently in `glowParent`.
    private(set) var glowLayers: [CALayer] = []
    private let glowParent: CALayer
    let rings = CAShapeLayer()
    private(set) var contentsScale: CGFloat = 2
    /// Hidden while move/leg previews substitute geometry (the highlight does not follow previews).
    var suppressed = false {
        didSet {
            for l in glowLayers { l.isHidden = suppressed }
            rings.isHidden = suppressed
        }
    }

    init(glowParent: CALayer) {
        self.glowParent = glowParent
        rings.fillColor = nil
        rings.strokeColor = Self.accent.cgColor
        rings.lineWidth = 2
        rings.actions = ["path": NSNull(), "hidden": NSNull()]
    }

    /// Callers disable implicit animations.
    func update(_ overlay: NetOverlay?, viewport: Viewport, viewSize: Vec2, scale: CGFloat,
                zPosition: (ObjectID) -> CGFloat) {
        contentsScale = scale
        rings.contentsScale = scale
        for l in glowLayers { l.removeFromSuperlayer() }
        glowLayers = []
        guard let overlay else {
            rings.path = nil
            return
        }
        let pt = Viewport.pointsPerMillimetre * viewport.zoom
        func view(_ p: Vec2) -> CGPoint {
            let v = viewport.worldToView(p, viewSize: viewSize)
            return CGPoint(x: v.x, y: v.y)
        }
        let path = CGMutablePath()
        let r = Self.ringRadius * pt
        for p in overlay.rings {
            let c = view(p)
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        rings.path = path
        for wire in overlay.wires {
            let line = CGMutablePath()
            for (i, p) in wire.points.enumerated() { i == 0 ? line.move(to: view(p)) : line.addLine(to: view(p)) }
            let layer = CAShapeLayer()
            layer.path = line
            layer.fillColor = nil
            layer.strokeColor = Self.accent.withAlphaComponent(Self.glowAlpha).cgColor
            layer.lineWidth = (wire.width + Self.glowExtra) * pt
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.contentsScale = scale
            layer.zPosition = zPosition(wire.id) - 0.5 // just below its wire, above any part under it
            layer.isHidden = suppressed
            glowParent.addSublayer(layer)
            glowLayers.append(layer)
        }
    }
}

extension CanvasView {
    /// Highlights the net of the connector within the hit radius of `viewPoint` (shows the pin info card). With no
    /// connector there, clears the highlight. True when a connector was hit.
    @discardableResult
    func highlightNet(at viewPoint: CGPoint) -> Bool {
        guard let (ref, _) = wires.connector(near: worldPoint(viewPoint), radius: wireRadius) else {
            clearNetHighlight()
            return false
        }
        netHighlight.anchor = ref
        applyNetHighlight(in: model.document)
        return true
    }

    /// A Pencil lasso that never left the hit slop is a tap: highlight a connector at its start, else fall back to
    /// the normal lasso. Cancels the lasso when it highlights.
    func highlightNetOnLassoTap() -> Bool {
        let points = lasso.points
        guard let first = points.first else { return false }
        let start = currentViewport.worldToView(first, viewSize: viewSize)
        let isTap = points.allSatisfy {
            let v = currentViewport.worldToView($0, viewSize: viewSize)
            return hypot(v.x - start.x, v.y - start.y) <= Self.hitSlop
        }
        guard isTap, highlightNet(at: CGPoint(x: start.x, y: start.y)) else { return false }
        lasso.cancel()
        lassoPath.clear()
        return true
    }

    func clearNetHighlight() {
        guard netHighlight.anchor != nil || netHighlight.info != nil else { return }
        netHighlight.anchor = nil
        netHighlight.net = nil
        netHighlight.info = nil
        netHighlight.cache = nil
        renderer.netOverlay = nil
    }

    /// Called from `documentChanged`: recomputes only when objects or parts changed since the last computation.
    func refreshNetHighlight(after doc: SketchDocument) {
        guard netHighlight.anchor != nil else { return }
        if let c = netHighlight.cache, c.objects == doc.objects, c.parts == doc.parts { return }
        applyNetHighlight(in: doc)
    }

    private func applyNetHighlight(in doc: SketchDocument) {
        let state = netHighlight
        guard let ref = state.anchor,
              case .part(let part)? = doc.objects.first(where: { $0.id == ref.part }),
              let def = doc.parts[part.definitionKey],
              let connector = def.connectors.first(where: { $0.id == ref.connector }) else {
            clearNetHighlight() // tapped connector no longer exists (undo, delete)
            return
        }
        if state.cache == nil || state.cache!.objects != doc.objects || state.cache!.parts != doc.parts {
            state.cache = (doc.objects, doc.parts, nets(in: doc))
        }
        let net = net(containing: ref, in: state.cache!.nets)
        let info = PinInfo(partLabel: part.label.isEmpty ? def.title : part.label, connectorName: connector.name,
                           role: connector.role, netName: net?.name, memberCount: net?.members.count ?? 0)
        if state.info != info { state.info = info }
        if state.net != net { state.net = net }
        renderer.netOverlay = overlay(for: net, anchor: ref, in: doc)
    }

    private func overlay(for net: Net?, anchor: ConnectorRef, in doc: SketchDocument) -> NetOverlay {
        let members = net?.members ?? [anchor]
        let wireIDs = net?.wires ?? []
        var rings: [Vec2] = []
        var wires: [(id: ObjectID, points: [Vec2], width: Double)] = []
        let memberParts = Set(members.map(\.part))
        var positions: [ObjectID: [String: Vec2]] = [:]
        for object in doc.objects {
            switch object {
            case .part(let p) where memberParts.contains(p.id):
                if let def = doc.parts[p.definitionKey] { positions[p.id] = connectorPositions(p, def) }
            case .wire(let w) where wireIDs.contains(w.id):
                wires.append((w.id, w.polyline, w.width))
            default: break
            }
        }
        for m in members {
            if let p = positions[m.part]?[m.connector] { rings.append(p) }
        }
        return NetOverlay(rings: rings, wires: wires)
    }
}
