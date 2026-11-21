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
    /// Phase 1 starts no new step after this many linear solves (the retraction of the last step may run past
    /// it by up to `maxRetractionSteps`).
    static let maxSoftIterations = 30
    /// Linear solves reserved for the final projection, whatever phase 1 used.
    static let maxProjectionIterations = 20
    /// Projection solves that retract each phase-1 trial step, and how exact the retraction must be (mm):
    /// enough that drag leakage is far below the stay term that decides between trial steps.
    static let maxRetractionSteps = 4
    static let retractionTolerance = 1e-8
    /// Tikhonov damping of the projections (relative to the stay metric); keeps redundant / rank-deficient
    /// constraint sets solvable.
    static let projectionDamping = 1e-8
    /// Share of the stay metric the dragged body keeps, in the phase-1 stay rows and in the projections. The
    /// finger moves that body, so its own motion must not compete with the stay of the bodies it is pinned to
    /// (charged in full, rotating a free bar costs as much as translating the whole assembly and the minimum
    /// splits the motion). Nonzero so a grab on a pin keeps the systems definite; the projections keep more,
    /// because their damping is already tiny (`projectionDamping`) and must stay well above round-off.
    static let grabbedStayScale = 1e-6
    static let grabbedProjectionScale = 1e-3
    /// Most unknowns (3 per moving body) a solve takes on; beyond it (a hostile document) it returns `initial`
    /// unsolved. Twice what `MechanismDrag.maxBodies` can produce.
    static let maxUnknowns = 3000
    /// A solve that brings the drag point less than this closer (mm) keeps `initial` when that is assembled.
    static let minimumGain = 1e-6

    /// `initial`: poses to start from (previous frame); points in constraints / drag are given at the identity pose.
    public static func solve(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?,
                             initial: [BodyPose]) -> SolveResult {
        var stats = SolveStats()
        return solve(bodies: bodies, constraints: constraints, drag: drag, initial: initial, stats: &stats)
    }

    /// `solve`, reporting how the linear solves were spent.
    static func solve(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?,
                      initial: [BodyPose], stats: inout SolveStats) -> SolveResult {
        guard let problem = Problem(bodies: bodies, constraints: constraints, drag: drag, initial: initial) else {
            return SolveResult(poses: initial, residual: .infinity, converged: false)
        }
        var poses = initial
        var iterations = 0
        if drag != nil, problem.unknowns > 0 {
            poses = problem.minimizeSoft(from: poses, iterations: &iterations)
        }
        stats.softIterations = iterations
        stats.softResidual = problem.constraintResidual(poses)
        var projectionIterations = 0
        poses = problem.project(from: poses, holdingDrag: false, iterations: &projectionIterations)
        stats.projectionIterations = projectionIterations
        let residual = problem.constraintResidual(poses)
        guard residual.isFinite, poses.allSatisfy(\.isFinite) else {
            return SolveResult(poses: initial, residual: problem.constraintResidual(initial), converged: false)
        }
        // Keep the previous frame when the drag point would come no measurably closer (a steady drag beyond
        // reach): staying is then optimal, and the projections' near-free directions (the grabbed body barely
        // counts in their metric) would otherwise turn round-off into frame-to-frame jitter.
        if drag != nil, case let still = problem.constraintResidual(initial), still < tolerance,
           problem.dragDistance(initial) - problem.dragDistance(poses) < minimumGain {
            return SolveResult(poses: initial, residual: still, converged: true)
        }
        return SolveResult(poses: poses, residual: residual, converged: residual < tolerance)
    }
}

/// Linear solves one `solve` spent per phase, and the constraint residual the soft phase left (mm).
struct SolveStats {
    var softIterations = 0
    var softResidual = 0.0
    var projectionIterations = 0
}

extension BodyPose {
    var isFinite: Bool { translation.isFinite && angle.isFinite }
}

private extension Vec2 {
    var isFinite: Bool { x.isFinite && y.isFinite }
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
    /// Weight of each body in the stay metric: 1, `grabbedStayScale` for the dragged body.
    let stay: [Double]
    /// The same for the projections' metric: 1, `grabbedProjectionScale` for the dragged body.
    let projectionStay: [Double]
    let unknowns: Int
    /// Where the normal equations can be non-zero, given the column order.
    let envelope: Envelope

    init?(bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget?, initial: [BodyPose]) {
        let range = bodies.indices
        guard initial.count == bodies.count, initial.allSatisfy(\.isFinite),
              bodies.allSatisfy({ $0.origin.isFinite }),
              constraints.allSatisfy({
                  range.contains($0.a) && ($0.b.map(range.contains) ?? true) && $0.pointA.isFinite && $0.pointB.isFinite
              }),
              drag.map({ range.contains($0.body) && $0.point.isFinite && $0.target.isFinite }) ?? true,
              3 * bodies.count(where: { !$0.isFixed }) <= MechanismSolver.maxUnknowns
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
        var stay = [Double](repeating: 1, count: bodies.count)
        var projectionStay = stay
        if let drag {
            stay[drag.body] = MechanismSolver.grabbedStayScale
            projectionStay[drag.body] = MechanismSolver.grabbedProjectionScale
        }
        self.stay = stay
        self.projectionStay = projectionStay
        var column = [Int](repeating: -1, count: bodies.count)
        for (k, i) in Self.bandOrder(bodies: bodies, constraints: constraints).enumerated() { column[i] = 3 * k }
        self.column = column
        unknowns = 3 * bodies.count(where: { !$0.isFixed })
        // Each body's three rows reach back to the first unknown of any moving body it shares a constraint with.
        var first = column
        for c in constraints {
            guard let b = c.b, column[c.a] >= 0, column[b] >= 0 else { continue }
            let (lo, hi) = column[c.a] < column[b] ? (c.a, b) : (b, c.a)
            first[hi] = min(first[hi], column[lo])
        }
        var rowFirst = [Int](repeating: 0, count: unknowns)
        for i in range where column[i] >= 0 {
            for row in column[i]..<column[i] + 3 { rowFirst[row] = first[i] }
        }
        envelope = Envelope(first: rowFirst)
    }

    /// Moving bodies in reverse Cuthill–McKee order over the constraint graph: neighbours get nearby unknowns,
    /// so the envelope stays narrow (a chain banded, a star with its hub last) whatever the input order.
    private static func bandOrder(bodies: [SolverBody], constraints: [PointConstraint]) -> [Int] {
        var neighbours = [[Int]](repeating: [], count: bodies.count)
        for c in constraints {
            guard let b = c.b, b != c.a, !bodies[c.a].isFixed, !bodies[b].isFixed else { continue }
            neighbours[c.a].append(b)
            neighbours[b].append(c.a)
        }
        for i in neighbours.indices where neighbours[i].count > 1 {
            neighbours[i] = Array(Set(neighbours[i])).sorted()
        }
        // Breadth-first from `start` over unvisited moving bodies, neighbours by ascending degree; marks them.
        func levels(from start: Int, _ visited: inout [Bool]) -> [Int] {
            var queue = [start]
            visited[start] = true
            var head = 0
            while head < queue.count {
                let i = queue[head]
                head += 1
                for j in neighbours[i].sorted(by: { (neighbours[$0].count, $0) < (neighbours[$1].count, $1) })
                where !visited[j] {
                    visited[j] = true
                    queue.append(j)
                }
            }
            return queue
        }
        var visited = bodies.map(\.isFixed)
        var probe = visited
        var order: [Int] = []
        for seed in bodies.indices where !visited[seed] {
            // Pseudo-peripheral start: a body of the deepest level reached from `seed`.
            let reached = levels(from: seed, &probe)
            order += levels(from: reached[reached.count - 1], &visited)
        }
        return order.reversed()
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
            cost += ws * ws * stay[i] * (t.x * t.x + t.y * t.y + a * a)
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

    /// Adds `scale · M + damping · diag(1, 1, reach²)` to the diagonal, M = stay · diag(1, 1, reach²) per body
    /// (the stay metric; `projection`: with `projectionStay`).
    private func addMetric(_ eq: inout NormalEquations, scale: Double, damping: Double = 0, projection: Bool = false) {
        let stay = projection ? projectionStay : self.stay
        for i in bodies.indices where column[i] >= 0 {
            let col = column[i]
            let d = scale * stay[i] + damping
            eq.addLower(col, col, d)
            eq.addLower(col + 1, col + 1, d)
            eq.addLower(col + 2, col + 2, d * reach[i] * reach[i])
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

    func dragDistance(_ poses: [BodyPose]) -> Double {
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
            var eq = NormalEquations(envelope: envelope)
            addConstraintRows(&eq, poses, weight: MechanismSolver.constraintWeight)
            addDragRows(&eq, poses)
            for i in bodies.indices where column[i] >= 0 {
                let col = column[i]
                let t = poses[i].translation - initial[i].translation
                let a = poses[i].angle - initial[i].angle
                let w = ws * ws * stay[i]
                eq.addRHS(col, -w * t.x)
                eq.addRHS(col + 1, -w * t.y)
                eq.addRHS(col + 2, -w * reach[i] * reach[i] * a)
            }
            addMetric(&eq, scale: ws * ws, damping: damping)
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
            // Trust region: shorten the step so its size in the stay metric (all bodies together, angles at
            // their reach) is at most the drag point's distance from its target, but never below 1 mm.
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
    /// reachable) with minimal motion. Every linear solve counts towards `iterations`, which stops at `limit`.
    func project(from start: [BodyPose], holdingDrag: Bool, iterations: inout Int,
                 limit: Int = MechanismSolver.maxProjectionIterations,
                 tolerance: Double = MechanismSolver.projectionTolerance) -> [BodyPose] {
        let wc = MechanismSolver.constraintWeight
        let done = wc * wc * tolerance * tolerance
        var poses = start
        var cost = projectionCost(poses, holdingDrag: holdingDrag)
        while iterations < limit, cost >= done, unknowns > 0 {
            iterations += 1
            var eq = NormalEquations(envelope: envelope)
            addConstraintRows(&eq, poses, weight: wc)
            if holdingDrag { addDragRows(&eq, poses) }
            addMetric(&eq, scale: MechanismSolver.projectionDamping, projection: true)
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
