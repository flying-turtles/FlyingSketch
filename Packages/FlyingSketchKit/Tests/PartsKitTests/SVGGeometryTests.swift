import Foundation
import Testing
import SketchCore
@testable import PartsKit

private func svg(_ s: String) throws -> SVGGeometry { try SVGGeometry(data: Data(s.utf8)) }
private func near(_ a: Vec2?, _ x: Double, _ y: Double, _ tol: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a.x - x) < tol && abs(a.y - y) < tol
}

@Suite struct SVGGeometryTests {
    @Test func inchesAndViewBox() throws {
        let g = try svg(#"<svg xmlns="http://www.w3.org/2000/svg" width="1in" height="1in" viewBox="0 0 1000 1000"><rect id="a" x="500" y="500" width="10" height="10"/></svg>"#)
        #expect(near(g.sizeMM, 25.4, 25.4))
        #expect(near(g.centerMM(ofElement: "a"), 12.7 + 0.127, 12.7 + 0.127))
        let g2 = try svg(#"<svg width="1in" height="1in" viewBox="0 0 1000 1000"><rect id="a" x="495" y="495" width="10" height="10"/></svg>"#)
        #expect(near(g2.centerMM(ofElement: "a"), 12.7, 12.7))
    }

    @Test func pxUses90dpi() throws {
        let g = try svg(#"<svg width="90px" height="45" ><circle id="c" cx="90" cy="45" r="5"/></svg>"#)
        #expect(near(g.sizeMM, 25.4, 12.7))
        #expect(near(g.centerMM(ofElement: "c"), 25.4, 12.7))
    }

    @Test func otherUnits() throws {
        #expect(near(try svg(#"<svg width="2cm" height="10mm"/>"#).sizeMM, 20, 10))
        #expect(near(try svg(#"<svg width="72pt" height="36pt"/>"#).sizeMM, 25.4, 12.7))
    }

    @Test func missingOrPercentSize() {
        #expect(throws: SVGError.missingSize) { try svg(#"<svg width="10"/>"#) }
        #expect(throws: SVGError.missingSize) { try svg(#"<svg width="100%" height="100%"/>"#) }
        #expect(throws: SVGError.notSVG) { try svg(#"<html/>"#) }
        #expect(throws: SVGError.notSVG) { try svg("garbage") }
    }

    @Test func noViewBoxUsesSizeUnit() throws {
        let g = try svg(#"<svg width="10mm" height="10mm"><rect id="r" x="0" y="0" width="2" height="2"/></svg>"#)
        // 1 user unit = 1 mm here
        #expect(near(g.centerMM(ofElement: "r"), 1, 1))
    }

    @Test func viewBoxOffsetAndAspectCentering() throws {
        let g = try svg(#"<svg width="20mm" height="10mm" viewBox="10 10 10 10"><rect id="r" x="10" y="10" width="10" height="10"/></svg>"#)
        // meet: scale 1, centered horizontally by 5mm
        #expect(near(g.centerMM(ofElement: "r"), 10, 5))
        let n = try svg(#"<svg width="20mm" height="10mm" viewBox="0 0 10 10" preserveAspectRatio="none"><rect id="r" x="0" y="0" width="10" height="10"/></svg>"#)
        #expect(near(n.centerMM(ofElement: "r"), 10, 5))
    }

    @Test func nestedTransforms() throws {
        // translate(10,0) then rotate 90 then scale 2: point (1,0) -> (2,0) -> (0,2) -> (10,2)
        let g = try svg(#"<svg width="100mm" height="100mm" viewBox="0 0 100 100"><g transform="translate(10,0)"><g transform="rotate(90) scale(2)"><rect id="r" x="0.5" y="-0.5" width="1" height="1"/></g></g></svg>"#)
        #expect(near(g.centerMM(ofElement: "r"), 10, 2))
    }

    @Test func rotateAboutPointAndSkewAndMatrix() throws {
        let g = try svg(#"<svg width="100mm" height="100mm" viewBox="0 0 100 100"><circle id="a" cx="10" cy="0" r="1" transform="rotate(90,0,0)"/><circle id="b" cx="0" cy="10" r="1" transform="matrix(1 0 0 1 5,5)"/><circle id="c" cx="0" cy="10" r="1" transform="skewX(45)"/></svg>"#)
        #expect(near(g.centerMM(ofElement: "a"), 0, 10))
        #expect(near(g.centerMM(ofElement: "b"), 5, 15))
        #expect(near(g.centerMM(ofElement: "c"), 10, 10))
    }

    @Test func pathBounds() throws {
        // circle r=5 at (20,20) as two relative arcs
        let g = try svg(#"<svg width="100mm" height="100mm" viewBox="0 0 100 100"><path id="p" d="M15 20 a5 5 0 1 0 10 0 a5 5 0 1 0 -10 0z"/></svg>"#)
        #expect(near(g.centerMM(ofElement: "p"), 20, 20))
    }

    @Test func pathNumberFormsAndImplicitRepeats() throws {
        let g = try svg(#"<svg width="100mm" height="100mm" viewBox="0 0 100 100"><path id="p" d="M 0 0 10 10"/><path id="q" d="M1.5.5-1-2"/><path id="e" d="m0 0 1e1 1e-3"/><path id="h" d="M0 0H10V10h-10Z"/><path id="bad" d="X"/><path id="partial" d="M0 0 L 4 4 L x"/></svg>"#)
        #expect(near(g.centerMM(ofElement: "p"), 5, 5))
        #expect(near(g.centerMM(ofElement: "q"), 0.25, -0.75))
        #expect(near(g.centerMM(ofElement: "e"), 5, 0.0005))
        #expect(near(g.centerMM(ofElement: "h"), 5, 5))
        #expect(g.centerMM(ofElement: "bad") == nil)
        #expect(g.centerMM(ofElement: "partial") == nil)
    }

    @Test func curvesBoundedByControlPoints() throws {
        let g = try svg(#"<svg width="100mm" height="100mm"><path id="p" d="M0 0 C 0 10 10 10 10 0 S 20 -10 20 0 Q 25 5 30 0 T 40 0"/></svg>"#)
        #expect(near(g.centerMM(ofElement: "p"), 20, 0))
    }

    @Test func displayNoneStillCounts() throws {
        let g = try svg(#"<svg width="10mm" height="10mm"><rect id="r" display="none" width="2" height="2"/></svg>"#)
        #expect(near(g.centerMM(ofElement: "r"), 1, 1))
    }

    @Test func polygonEllipseAndUnknown() throws {
        let g = try svg(##"<svg width="10mm" height="10mm"><polygon id="pg" points="0,0 4,0 4,2"/><ellipse id="el" cx="5" cy="5" rx="2" ry="1"/><use id="u" href="#pg"/><text id="t">x</text><rect id="nogeo" width="oops"/></svg>"##)
        #expect(near(g.centerMM(ofElement: "pg"), 2, 1))
        #expect(near(g.centerMM(ofElement: "el"), 5, 5))
        #expect(g.centerMM(ofElement: "u") == nil)
        #expect(g.centerMM(ofElement: "t") == nil)
        #expect(g.centerMM(ofElement: "nogeo") == nil)
        #expect(g.centerMM(ofElement: "missing") == nil)
    }

    @Test func lineEndpoints() throws {
        let g = try svg(#"<svg width="100mm" height="100mm" viewBox="0 0 100 100"><g transform="translate(1,2)"><line id="l" x1="0" y1="0" x2="10" y2="5"/><path id="pl" d="M0 0 L10 5"/><path id="pm" d="M0 0 10 5"/><path id="ph" d="M0 0 H10"/><path id="multi" d="M0 0 L1 1 L2 2"/><rect id="r" width="1" height="1"/></g></svg>"#)
        let l = try #require(g.lineMM(ofElement: "l"))
        #expect(near(l.0, 1, 2)); #expect(near(l.1, 11, 7))
        for id in ["pl", "pm"] {
            let p = try #require(g.lineMM(ofElement: id))
            #expect(near(p.0, 1, 2)); #expect(near(p.1, 11, 7))
        }
        let h = try #require(g.lineMM(ofElement: "ph"))
        #expect(near(h.1, 11, 2))
        #expect(g.lineMM(ofElement: "multi") == nil)
        #expect(g.lineMM(ofElement: "r") == nil)
    }

    @Test func fixtureFile() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/connectors.svg", withExtension: nil))
        let g = try SVGGeometry(data: Data(contentsOf: url))
        #expect(near(g.sizeMM, 12.7, 6.35))
        // viewBox 500 -> 12.7mm; scale .0254
        #expect(near(g.centerMM(ofElement: "connector0pin"), 110 * 0.0254, 60 * 0.0254))
        #expect(near(g.centerMM(ofElement: "connector1pin"), 150 * 0.0254, 60 * 0.0254))
        let leg = try #require(g.lineMM(ofElement: "connector2leg"))
        #expect(near(leg.1, 200 * 0.0254, 150 * 0.0254))
    }
}

@Suite struct SVGStrictnessTests {
    @Test func badTransformOnElementAndAncestor() throws {
        let g = try svg(#"<svg width="10mm" height="10mm"><rect id="a" width="1" height="1" transform="rotate(x)"/><g transform="bogus(1)"><rect id="b" width="1" height="1"/><g><rect id="c" width="1" height="1"/></g></g><rect id="ok" width="1" height="1"/></svg>"#)
        #expect(g.centerMM(ofElement: "a") == nil)
        #expect(g.centerMM(ofElement: "b") == nil)
        #expect(g.centerMM(ofElement: "c") == nil)
        #expect(near(g.centerMM(ofElement: "ok"), 0.5, 0.5))
    }

    @Test func malformedPathsAndPolygonsAreNil() throws {
        let g = try svg(#"<svg width="10mm" height="10mm"><path id="a" d="M0 0 L10 5 L x"/><path id="b" d="M0 0 L1 1 Z 5"/><path id="c" d="M0 0 K1 1"/><polygon id="d" points="0,0 1,1 2"/><polyline id="e" points="0,0 a,b"/></svg>"#)
        for id in ["a", "b", "c", "d", "e"] { #expect(g.centerMM(ofElement: id) == nil) }
        #expect(g.lineMM(ofElement: "a") == nil)
    }

    @Test func badNumbersAreNil() throws {
        let g = try svg(#"<svg width="10mm" height="10mm"><circle id="a" cx="50%" cy="1" r="1"/><circle id="b" cx="1" cy="1" r="2mm"/><circle id="c" cx="1" cy="1" r="2px"/><rect id="d" x="zz" width="1" height="1"/></svg>"#)
        #expect(g.centerMM(ofElement: "a") == nil)
        #expect(g.centerMM(ofElement: "b") == nil)
        #expect(near(g.centerMM(ofElement: "c"), 1, 1))
        #expect(g.centerMM(ofElement: "d") == nil)
    }

    @Test func badViewBoxThrows() {
        for vb in ["0 0 0 0", "a b c d", "0 0 10", "0 0 10 10 5"] {
            #expect(throws: SVGError.unsupported("viewBox")) {
                try svg(#"<svg width="10mm" height="10mm" viewBox="\#(vb)"/>"#)
            }
        }
    }

    @Test func preserveAspectRatioRules() throws {
        #expect(throws: SVGError.unsupported("preserveAspectRatio")) {
            try svg(#"<svg width="20mm" height="10mm" viewBox="0 0 10 10" preserveAspectRatio="xMinYMin slice"/>"#)
        }
        _ = try svg(#"<svg width="10mm" height="10mm" viewBox="0 0 10 10" preserveAspectRatio="xMinYMin slice"/>"#)
        _ = try svg(#"<svg width="20mm" height="10mm" viewBox="0 0 10 10" preserveAspectRatio="xMidYMid  meet"/>"#)
    }

    @Test func rootTransformThrows() throws {
        #expect(throws: SVGError.unsupported("root transform")) {
            try svg(#"<svg width="10mm" height="10mm" transform="scale(2)"/>"#)
        }
        _ = try svg(#"<svg width="10mm" height="10mm" transform="translate(0)"/>"#)
    }

    @Test func malformedXMLThrows() {
        #expect(throws: SVGError.notSVG) { try svg(#"<svg width="10mm" height="10mm"><rect id="a">"#) }
    }

    @Test func externalEntityNotResolved() throws {
        let xml = ##"<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg width="10mm" height="10mm"><rect id="&x;" width="1" height="1"/><rect id="r" width="1" height="1"/></svg>"##
        if let g = try? svg(xml) {
            #expect(g.centerMM(ofElement: "root:x:0:0") == nil)
        }
    }
}
