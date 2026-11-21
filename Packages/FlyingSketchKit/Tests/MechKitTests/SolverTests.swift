import Foundation
import Testing
import SketchCore
@testable import MechKit

// MARK: - Helpers

private func v(_ x: Double, _ y: Double) -> Vec2 { Vec2(x: x, y: y) }

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double) -> Bool { a.distance(to: b) <= tol }

private func mid(_ a: Vec2, _ b: Vec2) -> Vec2 { (a + b) / 2 }

/// Largest constraint distance, computed independently of the solver.
private func constraintError(_ bodies: [SolverBody], _ constraints: [PointConstraint], _ poses: [BodyPose]) -> Double {
    constraints.map { c in
        let wa = poses[c.a].apply(c.pointA, origin: bodies[c.a].origin)
        let wb = c.b.map { poses[$0].apply(c.pointB, origin: bodies[$0].origin) } ?? c.pointB
        return wa.distance(to: wb)
    }.max() ?? 0
}

private func world(_ result: SolveResult, _ bodies: [SolverBody], _ body: Int, _ p: Vec2) -> Vec2 {
    result.poses[body].apply(p, origin: bodies[body].origin)
}

private func isFinite(_ result: SolveResult) -> Bool {
    result.poses.allSatisfy { $0.translation.x.isFinite && $0.translation.y.isFinite && $0.angle.isFinite }
        && result.residual.isFinite
}

private func identity(_ n: Int) -> [BodyPose] { Array(repeating: .identity, count: n) }

// MARK: - Tests

@Test func twoBodiesOneHingeFollowDrag() {
    let bodies = [SolverBody(origin: v(0, 0)), SolverBody(origin: v(10, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(5, 0), b: 1, pointB: v(5, 0))]
    let drag = DragTarget(body: 1, point: v(15, 0), target: v(15, 6))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: identity(2))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(constraintError(bodies, constraints, r.poses) < 1e-6)
    #expect(near(world(r, bodies, 1, v(15, 0)), drag.target, 1e-3))
}

@Test func groundedCrankRotates() {
    let bodies = [SolverBody(origin: v(5, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    let drag = DragTarget(body: 0, point: v(10, 0), target: v(0, 10))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: identity(1))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(near(world(r, bodies, 0, v(10, 0)), v(0, 10), 1e-4))
    #expect(abs(r.poses[0].angle - .pi / 2) < 1e-4)
}

@Test func fourBarMatchesClosedForm() {
    let a = v(0, 0), d = v(40, 0), b0 = v(0, -10)
    let c0 = circleIntersections(b0, 35, d, 25).min { $0.y < $1.y }!
    // 0 crank AB, 1 coupler BC, 2 rocker DC.
    let bodies = [SolverBody(origin: mid(a, b0)), SolverBody(origin: mid(b0, c0)), SolverBody(origin: mid(d, c0))]
    let constraints = [
        PointConstraint(a: 0, pointA: a, b: nil, pointB: a),
        PointConstraint(a: 2, pointA: d, b: nil, pointB: d),
        PointConstraint(a: 0, pointA: b0, b: 1, pointB: b0),
        PointConstraint(a: 1, pointA: c0, b: 2, pointB: c0),
    ]
    var poses = identity(3)
    var previousC = c0
    for degrees in stride(from: -90.0, through: 0, by: 5) {
        let angle = degrees * .pi / 180
        let target = v(10 * cos(angle), 10 * sin(angle))
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: 0, point: b0, target: target), initial: poses)
        #expect(r.converged, "step \(degrees)")
        #expect(r.residual < 1e-6, "step \(degrees)")
        #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "step \(degrees)")
        let b = world(r, bodies, 0, b0)
        #expect(near(b, target, 1e-4), "step \(degrees): B \(b) vs \(target)")
        let expectedC = circleIntersections(target, 35, d, 25).min { $0.distance(to: previousC) < $1.distance(to: previousC) }!
        let c = world(r, bodies, 1, c0)
        #expect(near(c, expectedC, 1e-4), "step \(degrees): C \(c) vs \(expectedC)")
        #expect(abs(world(r, bodies, 1, b0).distance(to: c) - 35) < 1e-9)
        #expect(abs(world(r, bodies, 2, d).distance(to: world(r, bodies, 2, c0)) - 25) < 1e-9)
        previousC = expectedC
        poses = r.poses
    }
}

@Test func unreachableTargetStopsAtFullExtension() {
    let bodies = [SolverBody(origin: v(5, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    let drag = DragTarget(body: 0, point: v(10, 0), target: v(100, 0))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: identity(1))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(constraintError(bodies, constraints, r.poses) < 1e-6)
    #expect(near(world(r, bodies, 0, v(10, 0)), v(10, 0), 1e-3))
}

@Test func unreachableTargetFromPerpendicularStart() {
    let bodies = [SolverBody(origin: v(5, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    let drag = DragTarget(body: 0, point: v(10, 0), target: v(0, 100))
    var poses = identity(1)
    var ends: [Vec2] = []
    for frame in 0...10 {
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: poses)
        #expect(r.converged, "frame \(frame)")
        #expect(r.residual < 1e-6, "frame \(frame)")
        #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "frame \(frame)")
        let end = world(r, bodies, 0, drag.point)
        #expect(near(end, v(0, 10), 1e-2), "frame \(frame): \(end)")
        ends.append(end)
        poses = r.poses
    }
    #expect(ends[ends.count - 1].distance(to: ends[ends.count - 2]) < 1e-3)
}

@Test func fourBarPastToggleKeepsBranch() {
    let a = v(0, 0), d = v(40, 0), b0 = v(0, -10)
    let c0 = circleIntersections(b0, 35, d, 25).min { $0.y < $1.y }!
    let bodies = [SolverBody(origin: mid(a, b0)), SolverBody(origin: mid(b0, c0)), SolverBody(origin: mid(d, c0))]
    let constraints = [
        PointConstraint(a: 0, pointA: a, b: nil, pointB: a),
        PointConstraint(a: 2, pointA: d, b: nil, pointB: d),
        PointConstraint(a: 0, pointA: b0, b: 1, pointB: b0),
        PointConstraint(a: 1, pointA: c0, b: 2, pointB: c0),
    ]
    func cross(_ u: Vec2, _ w: Vec2) -> Double { u.x * w.y - u.y * w.x }
    let startSign = cross(c0 - b0, d - b0).sign
    var poses = identity(3)
    var previousC = c0
    for frame in 1...40 {
        // The target moves for 30 frames, then holds; from frame 31 on C must stay put.
        let target = c0 + v(60, 0) * (Double(min(frame, 30)) / 30)
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: 1, point: c0, target: target), initial: poses)
        #expect(r.converged, "frame \(frame)")
        #expect(r.residual < 1e-6, "frame \(frame)")
        #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "frame \(frame)")
        // Pins as carried by the crank (B, 0), the coupler (B, C, 1) and the rocker (C, 2).
        let bCrank = world(r, bodies, 0, b0), b = world(r, bodies, 1, b0)
        let c = world(r, bodies, 1, c0), cRocker = world(r, bodies, 2, c0)
        #expect(cross(c - b, d - b).sign == startSign, "frame \(frame): mirror flip")
        #expect(cross(cRocker - bCrank, d - bCrank).sign == startSign, "frame \(frame): mirror flip")
        // Link lengths between pins of different bodies: crank A–B, coupler B–C, rocker D–C.
        #expect(abs(a.distance(to: b) - 10) < 1e-5, "frame \(frame)")
        #expect(abs(bCrank.distance(to: cRocker) - 35) < 1e-5, "frame \(frame)")
        #expect(abs(d.distance(to: c) - 25) < 1e-5, "frame \(frame)")
        if frame > 30 { #expect(c.distance(to: previousC) < 1e-3, "frame \(frame): C moved \(c.distance(to: previousC))") }
        previousC = c
        poses = r.poses
    }
}

@Test func rigidTriangleDoesNotDeform() {
    let p1 = v(0, 0), p2 = v(20, 0), p3 = v(10, -15)
    let bodies = [SolverBody(origin: mid(p1, p2)), SolverBody(origin: mid(p2, p3)), SolverBody(origin: mid(p3, p1))]
    let constraints = [
        PointConstraint(a: 0, pointA: p1, b: nil, pointB: p1),
        PointConstraint(a: 0, pointA: p2, b: nil, pointB: p2),
        PointConstraint(a: 0, pointA: p2, b: 1, pointB: p2),
        PointConstraint(a: 1, pointA: p3, b: 2, pointB: p3),
        PointConstraint(a: 2, pointA: p1, b: 0, pointB: p1),
    ]
    let drag = DragTarget(body: 1, point: p3, target: p3 + v(20, 0))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: identity(3))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    for pose in r.poses {
        #expect(pose.translation.length < 1e-6 && abs(pose.angle) < 1e-6, "\(pose)")
    }
}

/// Plate P (0) with bar B1 (1) hinged at (0,0) and bar B2 (2) hinged at (20,0). B1's far end sits 2.5 mm
/// above the hinge, so dragging it down by 5 mm is reachable by rotating B1 alone.
private func plateWithBars(plateFixed: Bool) -> (bodies: [SolverBody], constraints: [PointConstraint], drag: DragTarget) {
    let h1 = v(0, 0), h2 = v(20, 0), e1 = v(-10, -2.5), e2 = v(20, 10)
    let bodies = [SolverBody(origin: mid(h1, h2), isFixed: plateFixed),
                  SolverBody(origin: mid(h1, e1)), SolverBody(origin: mid(h2, e2))]
    let constraints = [PointConstraint(a: 0, pointA: h1, b: 1, pointB: h1),
                       PointConstraint(a: 0, pointA: h2, b: 2, pointB: h2)]
    return (bodies, constraints, DragTarget(body: 1, point: e1, target: e1 + v(0, 5)))
}

@Test func ungroundedChainMovesLeast() {
    let (bodies, constraints, drag) = plateWithBars(plateFixed: false)
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: identity(3))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(constraintError(bodies, constraints, r.poses) < 1e-6)
    print("ungroundedChainMovesLeast: plate \(r.poses[0])")
    #expect(r.poses[0].translation.length < 1e-5, "\(r.poses[0])")
    #expect(abs(r.poses[0].angle) < 1e-6, "\(r.poses[0])")
    #expect(near(world(r, bodies, 1, drag.point), drag.target, 1e-3))
}

/// Point at `degrees` (clockwise positive) on the circle of `radius` about `center`, starting at +x.
private func onCircle(_ center: Vec2, _ radius: Double, _ degrees: Double) -> Vec2 {
    let a = degrees * .pi / 180
    return center + v(radius * cos(a), radius * sin(a))
}

@Test func freePlateStaysWhenBarSwings() {
    // Plate P (0) and bar B (1) hinged at (0,0), tip at (30,0); nothing fixed.
    let pin = v(0, 0), tip = v(30, 0)
    let bodies = [SolverBody(origin: pin), SolverBody(origin: mid(pin, tip))]
    let constraints = [PointConstraint(a: 0, pointA: pin, b: 1, pointB: pin)]
    var poses = identity(2)
    var worst = 0.0
    for step in 1...9 {
        let target = onCircle(pin, 30, Double(step) * 5)
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: 1, point: tip, target: target), initial: poses)
        #expect(r.converged, "step \(step)")
        #expect(r.residual < 1e-6, "step \(step)")
        worst = max(worst, r.poses[0].translation.length)
        #expect(r.poses[0].translation.length < 1e-3, "step \(step): plate \(r.poses[0])")
        #expect(abs(r.poses[0].angle) < 1e-4, "step \(step): plate \(r.poses[0])")
        #expect(near(world(r, bodies, 1, tip), target, 1e-3), "step \(step)")
        poses = r.poses
    }
    print("freePlateStaysWhenBarSwings: plate translation \(poses[0].translation.length) mm (worst \(worst)), angle \(poses[0].angle)")
}

@Test func freePlateReturnsAfterRoundTrip() {
    // Plate P (0), bar 1 hinged at (0,0) with its tip at (-30,0), bar 2 hinged at (20,0); nothing fixed.
    let h1 = v(0, 0), h2 = v(20, 0), e1 = v(-30, 0), e2 = v(20, 30)
    let bodies = [SolverBody(origin: mid(h1, h2)), SolverBody(origin: mid(h1, e1)), SolverBody(origin: mid(h2, e2))]
    let constraints = [PointConstraint(a: 0, pointA: h1, b: 1, pointB: h1),
                       PointConstraint(a: 0, pointA: h2, b: 2, pointB: h2)]
    var poses = identity(3)
    let path = Array(stride(from: 185.0, through: 240, by: 5)) + Array(stride(from: 235.0, through: 180, by: -5))
    for degrees in path {
        let target = onCircle(h1, 30, degrees)
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: 1, point: e1, target: target), initial: poses)
        #expect(r.converged, "\(degrees)°")
        #expect(r.residual < 1e-6, "\(degrees)°")
        poses = r.poses
    }
    print("freePlateReturnsAfterRoundTrip: plate \(poses[0]), bar 2 \(poses[2])")
    for i in [0, 2] {
        #expect(poses[i].translation.length < 1e-3, "body \(i): \(poses[i])")
        #expect(abs(poses[i].angle) < 1e-4, "body \(i): \(poses[i])")
    }
}

@Test func fixedBodyNeverMoves() {
    let (bodies, constraints, drag) = plateWithBars(plateFixed: true)
    let initial = [BodyPose(translation: v(1, 2), angle: 0.1), .identity, .identity]
    // Bring the bars onto the moved plate so the start is consistent.
    let start = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: nil, initial: initial)
    #expect(start.converged)
    #expect(start.poses[0] == initial[0])
    let target = initial[0].apply(drag.target, origin: bodies[0].origin)
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                  drag: DragTarget(body: 1, point: drag.point, target: target), initial: start.poses)
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(r.poses[0] == initial[0])
    #expect(near(world(r, bodies, 1, drag.point), target, 1e-3))
}

@Test func redundantConstraintsStaySolvable() {
    // Parallelogram: cranks at (0,0) and (20,0), coupler (0,-10)-(20,-10), plus a duplicated coupler.
    let g1 = v(0, 0), g2 = v(20, 0), t1 = v(0, -10), t2 = v(20, -10)
    let bodies = [SolverBody(origin: mid(g1, t1)), SolverBody(origin: mid(g2, t2)),
                  SolverBody(origin: mid(t1, t2)), SolverBody(origin: mid(t1, t2))]
    let constraints = [
        PointConstraint(a: 0, pointA: g1, b: nil, pointB: g1),
        PointConstraint(a: 1, pointA: g2, b: nil, pointB: g2),
        PointConstraint(a: 0, pointA: t1, b: 2, pointB: t1),
        PointConstraint(a: 1, pointA: t2, b: 2, pointB: t2),
        PointConstraint(a: 0, pointA: t1, b: 3, pointB: t1),
        PointConstraint(a: 1, pointA: t2, b: 3, pointB: t2),
    ]
    let point = v(10, -10)
    let target = v(10 + 10 * sin(Double.pi / 6), -10 * cos(Double.pi / 6))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                  drag: DragTarget(body: 2, point: point, target: target), initial: identity(4))
    #expect(isFinite(r))
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    #expect(constraintError(bodies, constraints, r.poses) < 1e-6)
    #expect(near(world(r, bodies, 2, point), target, 1e-3))
}

@Test func separateMechanismsIndependent() {
    let shift = v(0, 100)
    let bodies = [SolverBody(origin: v(0, 0)), SolverBody(origin: v(10, 0)),
                  SolverBody(origin: v(0, 0) + shift), SolverBody(origin: v(10, 0) + shift)]
    let constraints = [PointConstraint(a: 0, pointA: v(5, 0), b: 1, pointB: v(5, 0)),
                       PointConstraint(a: 2, pointA: v(5, 0) + shift, b: 3, pointB: v(5, 0) + shift)]
    let moved = BodyPose(translation: v(3, 4), angle: 0)
    let initial = [.identity, .identity, moved, moved]
    let drag = DragTarget(body: 1, point: v(15, 0), target: v(15, 6))
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: initial)
    #expect(r.converged)
    #expect(near(world(r, bodies, 1, drag.point), drag.target, 1e-3))
    #expect(r.poses[2] == initial[2])
    #expect(r.poses[3] == initial[3])
}

@Test func inconsistentConstraintsReportNotConverged() {
    // A 10 mm bar pinned to ground points 20 mm apart cannot be assembled.
    let bodies = [SolverBody(origin: v(5, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0)),
                       PointConstraint(a: 0, pointA: v(10, 0), b: nil, pointB: v(20, 0))]
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                  drag: DragTarget(body: 0, point: v(10, 0), target: v(10, 5)), initial: identity(1))
    #expect(!r.converged)
    #expect(r.residual >= 1e-6)
    #expect(isFinite(r))
}

@Test func noDragIsIdentityStep() {
    // Consistent hinged pair, rotated and moved as a whole.
    let bodies = [SolverBody(origin: v(0, 0)), SolverBody(origin: v(10, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(5, 0), b: 1, pointB: v(5, 0))]
    let pa = BodyPose(translation: v(2, -1), angle: 0.3)
    let hinge = pa.apply(v(5, 0), origin: bodies[0].origin)
    let pb0 = BodyPose(translation: .zero, angle: -0.7)
    let pb = BodyPose(translation: hinge - pb0.apply(v(5, 0), origin: bodies[1].origin), angle: -0.7)
    let initial = [pa, pb]
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: nil, initial: initial)
    #expect(r.converged)
    #expect(r.residual < 1e-6)
    for (p, q) in zip(r.poses, initial) {
        #expect((p.translation - q.translation).length < 1e-12 && abs(p.angle - q.angle) < 1e-12, "\(p) vs \(q)")
    }
}

@Test func fiftyBodyChainFrameTime() {
    let n = 50, length = 10.0
    let bodies = (0..<n).map { SolverBody(origin: v(Double($0) * length + length / 2, 0)) }
    var constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    for i in 1..<n {
        let p = v(Double(i) * length, 0)
        constraints.append(PointConstraint(a: i - 1, pointA: p, b: i, pointB: p))
    }
    let tip = v(Double(n) * length, 0)
    let radius = 30.0, center = tip - v(radius, 0)
    let frames = 60
    var poses = identity(n)
    let clock = ContinuousClock()
    var total = Duration.zero
    for k in 1...frames {
        let phi = Double(k) / Double(frames)  // 1 rad of a 30 mm radius arc = 30 mm
        let target = center + v(radius * cos(phi), -radius * sin(phi))
        var r: SolveResult!
        total += clock.measure {
            r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: n - 1, point: tip, target: target), initial: poses)
        }
        #expect(r.converged, "frame \(k)")
        #expect(r.residual < 1e-6, "frame \(k)")
        #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "frame \(k)")
        #expect(near(world(r, bodies, n - 1, tip), target, 1e-3), "frame \(k)")
        poses = r.poses
    }
    let averageMs = Double(total.components.attoseconds) / 1e15 / Double(frames)
        + Double(total.components.seconds) * 1000 / Double(frames)
    print("fiftyBodyChainFrameTime: average solve \(String(format: "%.3f", averageMs)) ms over \(frames) frames")
    #expect(averageMs < 10)
}

@Test func fiftyBodyChainUnreachableFrameTime() {
    let n = 50, length = 10.0
    let bodies = (0..<n).map { SolverBody(origin: v(Double($0) * length + length / 2, 0)) }
    var constraints = [PointConstraint(a: 0, pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    for i in 1..<n {
        let p = v(Double(i) * length, 0)
        constraints.append(PointConstraint(a: i - 1, pointA: p, b: i, pointB: p))
    }
    let tip = v(Double(n) * length, 0)
    let radius = Double(n) * length + 200  // 200 mm beyond full reach
    let frames = 30
    var poses = identity(n)
    let clock = ContinuousClock()
    var total = Duration.zero
    for k in 1...frames {
        let phi = 0.5 * Double(k) / Double(frames)
        let target = v(radius * cos(phi), -radius * sin(phi))
        var r: SolveResult!
        total += clock.measure {
            r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                      drag: DragTarget(body: n - 1, point: tip, target: target), initial: poses)
        }
        #expect(r.converged, "frame \(k)")
        #expect(r.residual < 1e-6, "frame \(k)")
        #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "frame \(k)")
        poses = r.poses
    }
    let averageMs = (Double(total.components.seconds) * 1000 + Double(total.components.attoseconds) / 1e15) / Double(frames)
    print("fiftyBodyChainUnreachableFrameTime: average solve \(String(format: "%.3f", averageMs)) ms over \(frames) frames")
    #expect(averageMs < 10)
}

// MARK: - Body order

/// Chain of `n` 10 mm bars grounded at (0,0); body `order[i]` is bar `i`.
private func chain(_ n: Int, order: [Int]) -> (bodies: [SolverBody], constraints: [PointConstraint]) {
    let length = 10.0
    var bodies = [SolverBody](repeating: SolverBody(origin: .zero), count: n)
    for i in 0..<n { bodies[order[i]] = SolverBody(origin: v(Double(i) * length + length / 2, 0)) }
    var constraints = [PointConstraint(a: order[0], pointA: v(0, 0), b: nil, pointB: v(0, 0))]
    for i in 1..<n {
        let p = v(Double(i) * length, 0)
        constraints.append(PointConstraint(a: order[i], pointA: p, b: order[i - 1], pointB: p))
    }
    return (bodies, constraints)
}

/// Drags the chain's tip along an arc; returns the poses of bar `i` per frame, and the best run's time (s).
private func dragChain(_ n: Int, order: [Int], frames: Int) -> (poses: [[BodyPose]], seconds: Double) {
    let (bodies, constraints) = chain(n, order: order)
    let tip = v(Double(n) * 10, 0)
    let radius = 30.0, center = tip - v(radius, 0)
    var best = Double.infinity
    var out: [[BodyPose]] = []
    for _ in 0..<3 {
        var poses = identity(n)
        out = []
        let start = ContinuousClock.now
        for k in 1...frames {
            let phi = Double(k) / Double(frames)
            let target = center + v(radius * cos(phi), -radius * sin(phi))
            let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                          drag: DragTarget(body: order[n - 1], point: tip, target: target),
                                          initial: poses)
            #expect(r.converged, "frame \(k)")
            #expect(constraintError(bodies, constraints, r.poses) < 1e-6, "frame \(k)")
            poses = r.poses
            out.append(order.map { poses[$0] })
        }
        let elapsed = ContinuousClock.now - start
        best = min(best, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    return (out, best)
}

@Test func shuffledChainMatchesOrdered() {
    let n = 50, frames = 20
    let ordered = dragChain(n, order: Array(0..<n), frames: frames)
    let shuffled = dragChain(n, order: (0..<n).map { ($0 * 17 + 11) % n }, frames: frames)
    var worst = 0.0
    for (a, b) in zip(ordered.poses, shuffled.poses) {
        for (p, q) in zip(a, b) {
            worst = max(worst, (p.translation - q.translation).length + 5 * abs(p.angle - q.angle))
        }
    }
    print("shuffledChainMatchesOrdered: worst difference \(worst) mm; \(ordered.seconds) s ordered, \(shuffled.seconds) s shuffled")
    #expect(worst < 1e-6)
    #expect(shuffled.seconds < 3 * ordered.seconds + 0.005)
}

// MARK: - Hostile input

/// Poses equal bit for bit (NaN equals NaN).
private func same(_ a: [BodyPose], _ b: [BodyPose]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { p, q in
        p.translation.x.bitPattern == q.translation.x.bitPattern
            && p.translation.y.bitPattern == q.translation.y.bitPattern && p.angle.bitPattern == q.angle.bitPattern
    }
}

@Test func nonFiniteInputsKeepInitial() {
    let bodies = [SolverBody(origin: v(0, 0)), SolverBody(origin: v(10, 0))]
    let constraints = [PointConstraint(a: 0, pointA: v(5, 0), b: 1, pointB: v(5, 0))]
    let drag = DragTarget(body: 1, point: v(15, 0), target: v(15, 6))
    let initial = [BodyPose(translation: v(1, 0), angle: 0), BodyPose(translation: v(1, 0), angle: 0)]
    let bad: [Double] = [.nan, .infinity, -.infinity]
    var cases: [(String, [SolverBody], [PointConstraint], DragTarget?, [BodyPose])] = []
    for x in bad {
        var c = constraints
        c[0].pointA.x = x
        cases.append(("pointA \(x)", bodies, c, drag, initial))
        c = constraints
        c[0].pointB.y = x
        cases.append(("pointB \(x)", bodies, c, drag, initial))
        var d = drag
        d.target.y = x
        cases.append(("target \(x)", bodies, constraints, d, initial))
        d = drag
        d.point.x = x
        cases.append(("drag point \(x)", bodies, constraints, d, initial))
        var b = bodies
        b[1].origin.x = x
        cases.append(("origin \(x)", b, constraints, drag, initial))
        var i = initial
        i[1].angle = x
        cases.append(("initial angle \(x)", bodies, constraints, drag, i))
        i = initial
        i[0].translation.y = x
        cases.append(("initial translation \(x)", bodies, constraints, nil, i))
    }
    for (name, bodies, constraints, drag, initial) in cases {
        let r = MechanismSolver.solve(bodies: bodies, constraints: constraints, drag: drag, initial: initial)
        #expect(!r.converged, "\(name)")
        #expect(same(r.poses, initial), "\(name): \(r.poses)")
    }
}

@Test func tooManyUnknownsReturnFast() {
    // One hinge joining a hub to many bodies (a hostile document), just over the unknowns cap.
    let n = MechanismSolver.maxUnknowns / 3 + 1
    let bodies = (0..<n).map { SolverBody(origin: v(Double($0), 1)) }
    let constraints = (1..<n).map { PointConstraint(a: $0, pointA: v(0, 0), b: 0, pointB: v(0, 0)) }
    let initial = identity(n)
    let start = ContinuousClock.now
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                  drag: DragTarget(body: 1, point: v(1, 1), target: v(5, 5)), initial: initial)
    let elapsed = ContinuousClock.now - start
    #expect(!r.converged)
    #expect(same(r.poses, initial))
    #expect(elapsed < .milliseconds(50), "\(elapsed)")
}

@Test func largestDraggableMechanismSolves() {
    // `MechanismDrag.maxBodies` bodies on one hinge stay well within the cap.
    let n = MechanismDrag.maxBodies
    #expect(3 * n * 2 <= MechanismSolver.maxUnknowns)
    let bodies = (0..<n).map { SolverBody(origin: v(Double($0), 1), isFixed: $0 == 0) }
    let constraints = (1..<n).map { PointConstraint(a: $0, pointA: v(0, 0), b: 0, pointB: v(0, 0)) }
    let r = MechanismSolver.solve(bodies: bodies, constraints: constraints,
                                  drag: DragTarget(body: 1, point: v(1, 1), target: v(-1, 1)), initial: identity(n))
    #expect(r.converged)
    #expect(constraintError(bodies, constraints, r.poses) < 1e-6)
    #expect(near(world(r, bodies, 1, v(1, 1)), v(-1, 1), 1e-3))
}
