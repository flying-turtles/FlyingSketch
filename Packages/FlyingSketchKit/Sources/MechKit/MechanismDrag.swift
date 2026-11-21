import SketchCore

/// One finger drag of a mechanism. Every frame solves from the previous frame's poses and transforms each moving
/// object from its drag-start value (no accumulation). Not thread-safe: create and use it on one actor (the canvas
/// keeps it on the main actor).
public final class MechanismDrag {
    /// Rigid poses whose points all move less than this (mm) are treated as identity, so bodies held still by
    /// their pins report no change instead of solver round-off.
    static let stillTolerance = 1e-9
    /// Largest mechanism (bodies) a drag solves; beyond it (e.g. a hostile file) there is no mechanism drag, as the
    /// solver's dense normal equations grow with the square of the body count.
    static let maxBodies = 500

    private struct Body {
        var members: [SceneObject]
        var origin: Vec2
        /// Largest distance of a member anchor from `origin` (mm), the lever of the angle.
        var reach: Double
    }

    private let start: SketchDocument
    private let joints: [Joint]
    private let wires: [Wire]
    /// In solver order (breadth-first from grounded / locked bodies).
    private let bodies: [Body]
    private let bodyIndex: [ObjectID: Int]
    /// Leg ends of moving parts that do not simply ride with their own body, by part id.
    private let legRules: [ObjectID: [(connector: String, rule: LegRule)]]
    private let solverBodies: [SolverBody]
    private let constraints: [PointConstraint]
    private let grabbed: Int
    private let grabPoint: Vec2
    private var poses: [BodyPose]

    /// Last result of `move` (empty before the first successful frame).
    public private(set) var replacements: [SceneObject] = []

    /// nil when `object`'s body has no joint, or the mechanism has more than `maxBodies` bodies.
    public init?(grabbing object: ObjectID, at world: Vec2, in doc: SketchDocument) {
        guard let mechanism = Mechanism(containing: object, in: doc), mechanism.bodies.count <= Self.maxBodies
        else { return nil }
        start = doc
        let jointIDs = Set(mechanism.joints)
        var joints: [Joint] = []
        for case .joint(let j) in doc.objects where jointIDs.contains(j.id) { joints.append(j) }
        self.joints = joints

        let order = solverOrder(mechanism, joints: joints, grabbed: bodyID(of: object, in: doc), in: doc)
        var index: [ObjectID: Int] = [:]
        for (i, id) in order.enumerated() { index[id] = i }
        var anchorPoints = [[Vec2]](repeating: [], count: order.count)
        var fixed = [Bool](repeating: false, count: order.count)
        var memberBody: [ObjectID: Int] = [:]
        for (i, id) in order.enumerated() {
            for m in mechanism.members(of: id) { memberBody[m] = i }
        }
        func body(of anchor: JointAnchor) -> Int? { index[bodyID(of: anchor.object, in: doc)] }
        for j in joints {
            for a in j.anchors {
                guard let b = body(of: a) else { continue }
                anchorPoints[b].append(a.point)
                if j.kind == .fixed { fixed[b] = true }
            }
        }
        var members = [[SceneObject]](repeating: [], count: order.count)
        for o in doc.objects {
            if let b = memberBody[o.id] { members[b].append(o) }
        }
        let bodies = order.indices.map { i in
            let points = anchorPoints[i]
            let origin = points.isEmpty ? world : points.reduce(Vec2.zero, +) / Double(points.count)
            let reach = points.map { $0.distance(to: origin) }.max() ?? 0
            return Body(members: members[i], origin: origin, reach: max(reach, 1))
        }
        self.bodies = bodies
        bodyIndex = memberBody
        legRules = legRulesOf(memberBody, in: doc)
        solverBodies = order.indices.map { SolverBody(origin: bodies[$0].origin, isFixed: fixed[$0]) }

        var constraints: [PointConstraint] = []
        for j in joints where j.kind == .hinge {
            let anchored = j.anchors.compactMap { a in body(of: a).map { (body: $0, point: a.point) } }
            guard let first = anchored.first else { continue }
            if j.grounded {
                constraints += anchored.map { PointConstraint(a: $0.body, pointA: $0.point, b: nil, pointB: j.position) }
            } else {
                constraints += anchored.dropFirst().map {
                    PointConstraint(a: $0.body, pointA: $0.point, b: first.body, pointB: first.point)
                }
            }
        }
        self.constraints = constraints
        guard let g = index[bodyID(of: object, in: doc)] else { return nil }
        grabbed = g
        grabPoint = world
        poses = Array(repeating: .identity, count: order.count)
        var wires: [Wire] = []
        for case .wire(let w) in doc.objects { wires.append(w) }
        self.wires = wires
    }

    /// Replacement objects for the finger at `world`: moved body members, carried parts, joints with updated
    /// anchor points and positions, and re-synced wires; only objects that differ from the drag-start document.
    /// Keeps the previous result when the solve fails.
    public func move(to world: Vec2) -> [SceneObject] {
        let result = MechanismSolver.solve(bodies: solverBodies, constraints: constraints,
                                           drag: DragTarget(body: grabbed, point: grabPoint, target: world),
                                           initial: poses)
        guard result.converged else { return replacements }
        poses = result.poses
        let motions = bodies.indices.map { motion(of: $0) }

        var changed: [ObjectID: SceneObject] = [:]
        for (i, body) in bodies.enumerated() {
            for o in body.members {
                let rules = legRules[o.id]
                guard motions[i] != nil || rules != nil else { continue }
                changed[o.id] = moved(o, motion: motions[i], rules: rules ?? [], motions: motions)
            }
        }
        for j in joints {
            var moved = j
            for k in moved.anchors.indices {
                guard let b = bodyIndex[moved.anchors[k].object], let m = motions[b] else { continue }
                moved.anchors[k].point = m.apply(moved.anchors[k].point)
            }
            if !moved.grounded, let first = moved.anchors.first { moved.position = first.point }
            changed[j.id] = .joint(moved)
        }
        for w in wires {
            guard case .connector(let p, _)? = w.start.attachment, case .connector(let q, _)? = w.end.attachment,
                  let b = bodyIndex[p], bodyIndex[q] == b, let m = motions[b] else { continue }
            var moved = w
            moved.bends = w.bends.map(m.apply)
            changed[w.id] = .wire(moved)
        }

        var doc = start
        for i in doc.objects.indices {
            if let o = changed[doc.objects[i].id] { doc.objects[i] = o }
        }
        for o in reconcileWires(in: doc) { changed[o.id] = o }
        replacements = start.objects.compactMap { o in
            guard let new = changed[o.id], new != o else { return nil }
            return new
        }
        return replacements
    }

    /// `o` moved with its body (`motion`, nil: stays); leg ends with a rule are placed by it instead.
    private func moved(_ o: SceneObject, motion: RigidMotion?, rules: [(connector: String, rule: LegRule)],
                       motions: [RigidMotion?]) -> SceneObject {
        let new = motion?.apply(o) ?? o
        guard !rules.isEmpty, case .part(var p) = new else { return new }
        for (c, rule) in rules {
            switch rule {
            case .hold(let end):
                if motion != nil { p.legEnds[c] = end }
            case .follow(let k, let end):
                if motion != nil || motions[k] != nil { p.legEnds[c] = motions[k]?.apply(end) ?? end }
            }
        }
        return .part(p)
    }

    /// Body `i`'s motion this frame; nil when it (practically) stays put.
    private func motion(of i: Int) -> RigidMotion? {
        let pose = poses[i]
        guard pose.translation.length + abs(pose.angle) * bodies[i].reach >= Self.stillTolerance else { return nil }
        return RigidMotion(origin: bodies[i].origin, angle: pose.angle, translation: pose.translation)
    }
}

/// How a leg end of a moving part moves, decided as in a free part move (`LegPlugs`): an end plugged into a part
/// outside the moving set holds its world point and the leg stretches; an end plugged into a part of another body
/// rides with that body. Ends that ride with their own part's body need no rule.
private enum LegRule {
    case hold(Vec2)
    case follow(body: Int, end: Vec2)
}

/// Leg rules of the parts in `memberBody` (moving object -> body index), from the drag-start positions.
private func legRulesOf(_ memberBody: [ObjectID: Int], in doc: SketchDocument)
    -> [ObjectID: [(connector: String, rule: LegRule)]] {
    let moving = Set(memberBody.keys)
    let plugs = LegPlugs(moving, in: doc)
    var result: [ObjectID: [(connector: String, rule: LegRule)]] = [:]
    for case .part(let p) in doc.objects {
        guard let own = memberBody[p.id], let def = doc.parts[p.definitionKey] else { continue }
        let ends = connectorPositions(p, def)
        for c in def.connectors where c.leg != nil {
            let ref = ConnectorRef(part: p.id, connector: c.id)
            guard let end = ends[c.id] else { continue }
            if plugs.holds(ref, moving: moving) {
                result[p.id, default: []].append((c.id, .hold(end)))
            } else if let k = plugs.females(of: ref).compactMap({ memberBody[$0] }).min(), k != own {
                result[p.id, default: []].append((c.id, .follow(body: k, end: end)))
            }
        }
    }
    return result
}

/// `BodyPose` applied exactly as `SceneObject.rotated(by:around:)` then `translated(by:)`, so anchor copies and
/// bends move bit-identically with their body's objects.
private struct RigidMotion {
    var origin: Vec2
    var angle: Double
    var translation: Vec2

    func apply(_ p: Vec2) -> Vec2 { origin + (p - origin).rotated(by: angle) + translation }
    func apply(_ o: SceneObject) -> SceneObject { o.rotated(by: angle, around: origin).translated(by: translation) }
}

/// Mechanism bodies breadth-first from grounded / locked bodies (from `grabbed` when there are none), so chains
/// give the solver a banded system.
private func solverOrder(_ m: Mechanism, joints: [Joint], grabbed: ObjectID, in doc: SketchDocument) -> [ObjectID] {
    var jointsByBody: [ObjectID: [Joint]] = [:]
    var seeds: [ObjectID] = []
    for j in joints {
        for a in j.anchors {
            let body = bodyID(of: a.object, in: doc)
            jointsByBody[body, default: []].append(j)
            if j.grounded || j.kind == .fixed { seeds.append(body) }
        }
    }
    let members = Set(m.bodies)
    var order: [ObjectID] = []
    var seen = Set<ObjectID>()
    func visit(_ body: ObjectID) {
        if members.contains(body), seen.insert(body).inserted { order.append(body) }
    }
    let grounded = Set(seeds)
    m.bodies.filter(grounded.contains).forEach(visit)
    if order.isEmpty { visit(grabbed) }
    var next = 0
    while next < order.count {
        for j in jointsByBody[order[next]] ?? [] {
            for a in j.anchors { visit(bodyID(of: a.object, in: doc)) }
        }
        next += 1
    }
    // Defensive: a mechanism is connected, so this only matters for inconsistent documents.
    m.bodies.forEach(visit)
    return order
}
