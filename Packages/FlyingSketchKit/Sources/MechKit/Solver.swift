import SketchCore

/// Rigid motion of one body: p -> origin + (p - origin).rotated(by: angle) + translation.
public struct BodyPose: Equatable, Sendable {
    public var translation: Vec2
    public var angle: Double

    public init(translation: Vec2 = .zero, angle: Double = 0) {
        self.translation = translation
        self.angle = angle
    }

    public static let identity = BodyPose()

    public func apply(_ p: Vec2, origin: Vec2) -> Vec2 {
        origin + (p - origin).rotated(by: angle) + translation
    }
}

public struct SolverBody: Sendable {
    public var origin: Vec2
    public var isFixed: Bool

    public init(origin: Vec2, isFixed: Bool = false) {
        self.origin = origin
        self.isFixed = isFixed
    }
}

/// Keeps point `pointA` of body `a` on point `pointB` of body `b` (`b == nil`: `pointB` is a fixed world point).
public struct PointConstraint: Sendable {
    public var a: Int
    public var pointA: Vec2
    public var b: Int?
    public var pointB: Vec2

    public init(a: Int, pointA: Vec2, b: Int?, pointB: Vec2) {
        self.a = a
        self.pointA = pointA
        self.b = b
        self.pointB = pointB
    }
}

public struct DragTarget: Sendable {
    public var body: Int
    public var point: Vec2
    public var target: Vec2

    public init(body: Int, point: Vec2, target: Vec2) {
        self.body = body
        self.point = point
        self.target = target
    }
}

public struct SolveResult: Sendable {
    public var poses: [BodyPose]
    public var residual: Double
    public var converged: Bool

    public init(poses: [BodyPose], residual: Double, converged: Bool) {
        self.poses = poses
        self.residual = residual
        self.converged = converged
    }
}

/// Planar mechanism solver: rigid bodies, point (hinge) constraints, one soft drag target.
///
/// Unknowns are (tx, ty, angle) per non-fixed body. Phase 1 runs Levenberg–Marquardt on the stacked residual
/// (weighted constraint rows, soft drag rows, soft "stay near `initial`" rows); each trial step is first
/// retracted onto constraints + drag, so the tiny stay term decides between steps instead of second-order
/// leakage off the curved mechanism. Phase 2 projects onto the constraints alone (damped Gauss–Newton,
/// minimal motion in the stay metric) until they hold exactly.
public enum MechanismSolver {
    /// Weights of the stacked phase-1 residual. Constraints dominate, the drag is much stronger than staying put.
    static let constraintWeight = 10.0
    static let dragWeight = 1.0
    static let stayWeight = 1e-3
    /// `residual` below this counts as converged (mm).
    static let tolerance = 1e-6
    /// Projections keep going until here (mm), well inside `tolerance`.
    static let projectionTolerance = 1e-10
    /// Cap on linear solves per call, all phases together.
    static let maxIterations = 40
    /// Phase 1 starts no new step after this many solves, leaving the rest to the final projection.
    static let maxSoftIterations = 30
    /// Projection solves that retract each phase-1 trial step, and how exact the retraction must be (mm):
    /// enough that drag leakage is far below the stay term that decides between trial steps.
    static let maxRetractionSteps = 4
    static let retractionTolerance = 1e-8
    /// Tikhonov damping of the projections (relative to the stay metric); keeps redundant / rank-deficient
    /// constraint sets solvable.
    static let projectionDamping = 1e-8

    /// `initial`: poses to start from (previous frame); points in constraints / drag are given at the identity pose.
    public static func solve(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?,
                             initial: [BodyPose]) -> SolveResult {
        guard let problem = Problem(bodies: bodies, constraints: constraints, drag: drag, initial: initial) else {
            return SolveResult(poses: initial, residual: .infinity, converged: false)
        }
        var poses = initial
        var iterations = 0
        if drag != nil, problem.unknowns > 0 {
            poses = problem.minimizeSoft(from: poses, iterations: &iterations)
        }
        poses = problem.project(from: poses, holdingDrag: false, iterations: &iterations)
        let residual = problem.constraintResidual(poses)
        guard residual.isFinite, poses.allSatisfy(\.isFinite) else {
            return SolveResult(poses: initial, residual: problem.constraintResidual(initial), converged: false)
        }
        return SolveResult(poses: poses, residual: residual, converged: residual < tolerance)
    }
}

extension BodyPose {
    var isFinite: Bool { translation.x.isFinite && translation.y.isFinite && angle.isFinite }
}

/// One 2-row residual block's dependence on one body. With `r` the rotated lever of the point and `w` the
/// row weight, the Jacobian rows over (tx, ty, angle) are x: (w, 0, ax) and y: (0, w, ay), ax = -w·r.y,
/// ay = w·r.x.
private struct Term {
    var column: Int
    var w: Double
    var ax: Double
    var ay: Double
}

private struct Problem {
    let bodies: [SolverBody]
    let constraints: [PointConstraint]
    let drag: DragTarget?
    let initial: [BodyPose]
    /// First unknown of each body, -1 for fixed bodies.
    let column: [Int]
    /// Lever that makes a body's angle comparable to its translation (mm per radian, at least 1).
    let reach: [Double]
    let unknowns: Int

    init?(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?, initial: [BodyPose]) {
        let range = bodies.indices
        guard initial.count == bodies.count, initial.allSatisfy(\.isFinite),
              constraints.allSatisfy({ range.contains($0.a) && ($0.b.map(range.contains) ?? true) }),
              drag.map({ range.contains($0.body) }) ?? true
        else { return nil }
        self.bodies = bodies
        self.constraints = constraints
        self.drag = drag
        self.initial = initial
        var reach = [Double](repeating: 1, count: bodies.count)
        func reachOut(_ body: Int, _ p: Vec2) { reach[body] = max(reach[body], p.distance(to: bodies[body].origin)) }
        for c in constraints {
            reachOut(c.a, c.pointA)
            if let b = c.b { reachOut(b, c.pointB) }
        }
        if let drag { reachOut(drag.body, drag.point) }
        self.reach = reach
        var column = [Int](repeating: -1, count: bodies.count)
        var next = 0
        for i in range where !bodies[i].isFixed {
            column[i] = next
            next += 3
        }
        self.column = column
        unknowns = next
    }

    // MARK: Residuals

    private func world(_ poses: [BodyPose], _ body: Int, _ p: Vec2) -> Vec2 {
        poses[body].apply(p, origin: bodies[body].origin)
    }

    private func constraintError(_ poses: [BodyPose], _ c: PointConstraint) -> Vec2 {
        world(poses, c.a, c.pointA) - (c.b.map { world(poses, $0, c.pointB) } ?? c.pointB)
    }

    /// Largest distance between a constraint's two points.
    func constraintResidual(_ poses: [BodyPose]) -> Double {
        var worst = 0.0
        for c in constraints { worst = max(worst, constraintError(poses, c).length) }
        return worst
    }

    /// Phase-1 objective: squared norm of the stacked weighted residual.
    private func softCost(_ poses: [BodyPose]) -> Double {
        let ws = MechanismSolver.stayWeight
        var cost = projectionCost(poses, holdingDrag: true)
        for i in bodies.indices where column[i] >= 0 {
            let t = poses[i].translation - initial[i].translation
            let a = reach[i] * (poses[i].angle - initial[i].angle)
            cost += ws * ws * (t.x * t.x + t.y * t.y + a * a)
        }
        return cost
    }

    /// Derivative of `world(p)` for body `body`, scaled by `weight`; nil for fixed bodies.
    private func term(_ poses: [BodyPose], _ body: Int, _ p: Vec2, _ weight: Double) -> Term? {
        let col = column[body]
        guard col >= 0 else { return nil }
        let r = (p - bodies[body].origin).rotated(by: poses[body].angle)
        return Term(column: col, w: weight, ax: -weight * r.y, ay: weight * r.x)
    }

    /// Adds `JᵀJ` and `-Jᵀe` of one 2-row block (`e` already weighted).
    private func accumulate(_ eq: inout NormalEquations, _ e: Vec2, _ t1: Term?, _ t2: Term?) {
        if let t1 { addTerm(&eq, e, t1, t2) }
        if let t2 { addTerm(&eq, e, t2, t1) }
    }

    /// `p`'s share of one block: its `-Jᵀe` entries and the lower-triangle entries of `pᵀp` and `pᵀ other`
    /// (zero entries skipped).
    private func addTerm(_ eq: inout NormalEquations, _ e: Vec2, _ p: Term, _ other: Term?) {
        let c = p.column
        eq.addRHS(c, -p.w * e.x)
        eq.addRHS(c + 1, -p.w * e.y)
        eq.addRHS(c + 2, -(p.ax * e.x + p.ay * e.y))
        eq.addLower(c, c, p.w * p.w)
        eq.addLower(c + 1, c + 1, p.w * p.w)
        eq.addLower(c + 2, c, p.ax * p.w)
        eq.addLower(c + 2, c + 1, p.ay * p.w)
        eq.addLower(c + 2, c + 2, p.ax * p.ax + p.ay * p.ay)
        guard let q = other else { return }
        let d = q.column
        func add(_ row: Int, _ col: Int, _ value: Double) {
            if row >= col { eq.addLower(row, col, value) }
        }
        add(c, d, p.w * q.w)
        add(c, d + 2, p.w * q.ax)
        add(c + 1, d + 1, p.w * q.w)
        add(c + 1, d + 2, p.w * q.ay)
        add(c + 2, d, p.ax * q.w)
        add(c + 2, d + 1, p.ay * q.w)
        add(c + 2, d + 2, p.ax * q.ax + p.ay * q.ay)
    }

    private func addConstraintRows(_ eq: inout NormalEquations, _ poses: [BodyPose], weight w: Double) {
        for c in constraints {
            let e = constraintError(poses, c) * w
            accumulate(&eq, e, term(poses, c.a, c.pointA, w), c.b.flatMap { term(poses, $0, c.pointB, -w) })
        }
    }

    /// Bending stiffness per body that Gauss–Newton leaves out: `Σ e·∂²e/∂angle²` over the weighted constraint
    /// and drag residuals `e` *predicted* by the linear model after `step` (for constraints that is the
    /// constraint force). It matters only when those residuals stay large at the solution, i.e. a drag beyond
    /// reach: there the drag point swings on an arc around its pivots and Gauss–Newton, blind to that
    /// curvature, overshoots by a factor of about distance/arm and stalls. Clamped at zero per body so the
    /// system stays positive definite (the softening side only occurs far from a minimum, where damping rules).
    func bending(_ poses: [BodyPose], after step: [Double]) -> [Double] {
        var bend = [Double](repeating: 0, count: bodies.count)
        // Linearized move of point `p` of `body`, and the curvature ∂²w/∂angle² = -r.
        func lever(_ body: Int, _ p: Vec2) -> Vec2 { (p - bodies[body].origin).rotated(by: poses[body].angle) }
        func move(_ body: Int, _ r: Vec2) -> Vec2 {
            let col = column[body]
            guard col >= 0 else { return .zero }
            return Vec2(x: step[col] - r.y * step[col + 2], y: step[col + 1] + r.x * step[col + 2])
        }
        func dot(_ u: Vec2, _ v: Vec2) -> Double { u.x * v.x + u.y * v.y }
        let wc2 = MechanismSolver.constraintWeight * MechanismSolver.constraintWeight
        for c in constraints {
            let ra = lever(c.a, c.pointA)
            var predicted = constraintError(poses, c) + move(c.a, ra)
            if let b = c.b {
                let rb = lever(b, c.pointB)
                predicted = predicted - move(b, rb)
                bend[b] += wc2 * dot(predicted, rb)
            }
            bend[c.a] -= wc2 * dot(predicted, ra)
        }
        if let drag {
            let wd2 = MechanismSolver.dragWeight * MechanismSolver.dragWeight
            let r = lever(drag.body, drag.point)
            let predicted = world(poses, drag.body, drag.point) - drag.target + move(drag.body, r)
            bend[drag.body] -= wd2 * dot(predicted, r)
        }
        return bend.map { max(0, $0) }
    }

    private func addBending(_ eq: inout NormalEquations, _ bend: [Double]) {
        for i in bodies.indices where column[i] >= 0 && bend[i] > 0 {
            eq.addLower(column[i] + 2, column[i] + 2, bend[i])
        }
    }

    /// Adds `scale · M` to the diagonal, M = diag(1, 1, reach²) per body (the stay metric).
    private func addMetric(_ eq: inout NormalEquations, scale: Double) {
        for i in bodies.indices where column[i] >= 0 {
            let col = column[i]
            eq.addLower(col, col, scale)
            eq.addLower(col + 1, col + 1, scale)
            eq.addLower(col + 2, col + 2, scale * reach[i] * reach[i])
        }
    }

    private func applied(_ step: [Double], scale: Double = 1, to poses: [BodyPose]) -> [BodyPose] {
        var out = poses
        for i in bodies.indices where column[i] >= 0 {
            let col = column[i]
            out[i].translation = out[i].translation + Vec2(x: step[col], y: step[col + 1]) * scale
            out[i].angle += step[col + 2] * scale
        }
        return out
    }

    /// Size of a step in the stay metric (mm).
    private func metricNorm(_ step: [Double]) -> Double {
        var sum = 0.0
        for i in bodies.indices where column[i] >= 0 {
            let col = column[i]
            let a = reach[i] * step[col + 2]
            sum += step[col] * step[col] + step[col + 1] * step[col + 1] + a * a
        }
        return sum.squareRoot()
    }

    /// Weighted squared error of the rows a projection drives to zero: constraints, plus the drag if held.
    private func projectionCost(_ poses: [BodyPose], holdingDrag: Bool) -> Double {
        let wc = MechanismSolver.constraintWeight, wd = MechanismSolver.dragWeight
        var cost = 0.0
        for c in constraints {
            let e = constraintError(poses, c)
            cost += wc * wc * (e.x * e.x + e.y * e.y)
        }
        if holdingDrag, let drag {
            let e = world(poses, drag.body, drag.point) - drag.target
            cost += wd * wd * (e.x * e.x + e.y * e.y)
        }
        return cost
    }

    private func dragDistance(_ poses: [BodyPose]) -> Double {
        guard let drag else { return 0 }
        return world(poses, drag.body, drag.point).distance(to: drag.target)
    }

    private func addDragRows(_ eq: inout NormalEquations, _ poses: [BodyPose]) {
        guard let drag else { return }
        let w = MechanismSolver.dragWeight
        let e = (world(poses, drag.body, drag.point) - drag.target) * w
        accumulate(&eq, e, term(poses, drag.body, drag.point, w), nil)
    }

    // MARK: Phase 1: soft objective (Levenberg–Marquardt with retraction)

    func minimizeSoft(from start: [BodyPose], iterations: inout Int) -> [BodyPose] {
        let ws = MechanismSolver.stayWeight
        var poses = start
        var cost = softCost(poses)
        var damping = 1e-7
        let tolerance = MechanismSolver.constraintWeight * MechanismSolver.retractionTolerance
        let settledCost = tolerance * tolerance
        var settled = false
        var bend: [Double]?
        while iterations < MechanismSolver.maxSoftIterations {
            iterations += 1
            var eq = NormalEquations(size: unknowns)
            addConstraintRows(&eq, poses, weight: MechanismSolver.constraintWeight)
            addDragRows(&eq, poses)
            for i in bodies.indices where column[i] >= 0 {
                let col = column[i]
                let t = poses[i].translation - initial[i].translation
                let a = poses[i].angle - initial[i].angle
                eq.addRHS(col, -ws * ws * t.x)
                eq.addRHS(col + 1, -ws * ws * t.y)
                eq.addRHS(col + 2, -ws * ws * reach[i] * reach[i] * a)
            }
            addMetric(&eq, scale: ws * ws + damping)
            var bent = eq
            if let bend { addBending(&bent, bend) }
            guard var step = bent.solve() else {
                damping *= 10
                continue
            }
            if bend == nil {
                // First step: Gauss–Newton predicts the residuals left at the solution; if they bend the
                // mechanism (drag beyond reach), solve once more with that stiffness.
                let predicted = bending(poses, after: step)
                bend = predicted
                if predicted.contains(where: { $0 > 0 }), iterations < MechanismSolver.maxSoftIterations {
                    iterations += 1
                    bent = eq
                    addBending(&bent, predicted)
                    guard let refined = bent.solve() else { continue }
                    step = refined
                }
            }
            let stepNorm = metricNorm(step)
            if stepNorm < MechanismSolver.projectionTolerance { break }
            // Trust region: no point needs to move further than the drag point is from its target.
            let maxStep = max(1, dragDistance(poses))
            let candidate = project(from: applied(step, scale: min(1, maxStep / stepNorm), to: poses),
                                    holdingDrag: true, iterations: &iterations,
                                    limit: iterations + MechanismSolver.maxRetractionSteps,
                                    tolerance: MechanismSolver.retractionTolerance)
            bend = bending(poses, after: step)
            let newCost = softCost(candidate)
            if newCost.isFinite, newCost < cost {
                let decrease = cost - newCost
                poses = candidate
                cost = newCost
                damping = max(damping / 10, 1e-12)
                if decrease <= 1e-6 * cost { break }
                settled = projectionCost(poses, holdingDrag: true) < settledCost
            } else {
                // Once constraints and drag hold, further steps only redistribute motion; not worth fighting
                // the model for.
                if settled { break }
                // At the minimum up to rounding (e.g. drag beyond reach): no step can improve.
                if newCost.isFinite, newCost - cost <= 1e-12 * cost { break }
                damping *= 10
                if damping > 1e8 { break }
            }
        }
        return poses
    }

    // MARK: Projection (damped Gauss–Newton)

    /// Moves `start` onto the constraints (and onto the drag target if `holdingDrag`, as far as it is
    /// reachable) with minimal motion. Every linear solve counts towards `iterations`, which stops at `limit`
    /// (never beyond `maxIterations`).
    func project(from start: [BodyPose], holdingDrag: Bool, iterations: inout Int,
                 limit: Int = MechanismSolver.maxIterations,
                 tolerance: Double = MechanismSolver.projectionTolerance) -> [BodyPose] {
        let wc = MechanismSolver.constraintWeight
        let done = wc * wc * tolerance * tolerance
        var poses = start
        var cost = projectionCost(poses, holdingDrag: holdingDrag)
        let limit = min(limit, MechanismSolver.maxIterations)
        while iterations < limit, cost >= done, unknowns > 0 {
            iterations += 1
            var eq = NormalEquations(size: unknowns)
            addConstraintRows(&eq, poses, weight: wc)
            if holdingDrag { addDragRows(&eq, poses) }
            addMetric(&eq, scale: MechanismSolver.projectionDamping)
            guard let step = eq.solve() else { break }
            // Halve the step while it makes things worse (far from the constraint manifold).
            var scale = 1.0, accepted = false
            for _ in 0..<6 {
                let candidate = applied(step, scale: scale, to: poses)
                let c = projectionCost(candidate, holdingDrag: holdingDrag)
                if c.isFinite, c < cost {
                    poses = candidate
                    cost = c
                    accepted = true
                    break
                }
                scale /= 2
            }
            if !accepted { break }
        }
        return poses
    }
}
