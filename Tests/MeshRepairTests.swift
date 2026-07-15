import XCTest
import simd
// MeshRepair lives in Sources/Core, compiled into this test bundle — same module.

/// Print-ready mesh repair: welding, degenerate/duplicate removal, small-component
/// removal, outward orientation, compaction, watertight reporting, determinism.
/// Pure-logic — no GPU/network (mirrors MeshDecimatorTests). Verified independently
/// via the standalone RepairKit harness before landing.
final class MeshRepairTests: XCTestCase {

    // MARK: - weld coincident vertices (fixes UV-seam splits)

    func testWeldsCoincidentVertices() {
        // Two triangles forming a square; the shared diagonal's verts are duplicated
        // (as xatlas UV-unwrap leaves them). v3==v1, v4==v2 by position.
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
        ]
        let faces: [SIMD3<UInt32>] = [SIMD3(0, 1, 2), SIMD3(3, 4, 5)]

        let out = MeshRepair.makePrintable(positions: positions, faces: faces)

        XCTAssertEqual(out.positions.count, 4, "coincident verts should merge to 4 unique")
        XCTAssertEqual(out.report.welded, 2)
        XCTAssertEqual(out.faces.count, 2, "both faces survive")
        XCTAssertTrue(Self.manifoldOrOpen(out.faces), "welding must not create a non-manifold edge")
        for f in out.faces {
            XCTAssertTrue(f.x != f.y && f.y != f.z && f.x != f.z)
            XCTAssertLessThan(Int(max(f.x, max(f.y, f.z))), out.positions.count)
        }
    }

    // MARK: - remove degenerate + duplicate faces

    func testRemovesDegenerateAndDuplicateFaces() {
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(2, 0, 0),
        ]
        let faces: [SIMD3<UInt32>] = [
            SIMD3(0, 1, 2),   // valid
            SIMD3(0, 0, 1),   // repeated index → degenerate
            SIMD3(0, 1, 2),   // exact duplicate → remove
            SIMD3(0, 1, 3),   // collinear (all on x-axis) → zero area
        ]
        let out = MeshRepair.makePrintable(positions: positions, faces: faces)
        XCTAssertEqual(out.faces.count, 1, "only the one valid face survives")
        XCTAssertEqual(out.report.degenerateRemoved, 3)
        XCTAssertEqual(out.report.welded, 0)
    }

    // MARK: - orient faces outward (positive signed volume)

    func testOrientsOutward() {
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
        ]
        var faces: [SIMD3<UInt32>] = [
            SIMD3(0, 1, 2), SIMD3(0, 1, 3), SIMD3(0, 2, 3), SIMD3(1, 2, 3),
        ]
        if Self.signedVolume(positions, faces) > 0 { faces = faces.map { SIMD3($0.x, $0.z, $0.y) } }
        XCTAssertLessThan(Self.signedVolume(positions, faces), 0, "precondition: inward input")

        let out = MeshRepair.makePrintable(positions: positions, faces: faces)
        XCTAssertGreaterThan(Self.signedVolume(out.positions, out.faces), 0, "must flip to outward")
        XCTAssertTrue(out.report.flippedToOutward)
        XCTAssertEqual(out.faces.count, 4)
        XCTAssertTrue(MeshRepair.isClosedManifold(out.faces))
    }

    // MARK: - compact unreferenced vertices

    func testCompactsUnusedVertices() {
        let positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(9, 9, 9),  // v3 unused
        ]
        let out = MeshRepair.makePrintable(positions: positions, faces: [SIMD3(0, 1, 2)])
        XCTAssertEqual(out.positions.count, 3, "drops the unused vertex")
        XCTAssertEqual(out.faces.count, 1)
        XCTAssertLessThan(Int(max(out.faces[0].x, max(out.faces[0].y, out.faces[0].z))), out.positions.count)
    }

    // MARK: - drop small disconnected components (MC specks)

    func testDropsSmallComponents() {
        var positions: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
        ]
        var faces: [SIMD3<UInt32>] = [
            SIMD3(0, 2, 1), SIMD3(0, 1, 3), SIMD3(0, 3, 2), SIMD3(1, 2, 3),
        ]
        let base = UInt32(positions.count)
        let o = SIMD3<Float>(10, 10, 10), s: Float = 0.01
        positions += [o, o + SIMD3(s, 0, 0), o + SIMD3(0, s, 0), o + SIMD3(0, 0, s)]
        faces += [SIMD3(base, base+2, base+1), SIMD3(base, base+1, base+3),
                  SIMD3(base, base+3, base+2), SIMD3(base+1, base+2, base+3)]

        let out = MeshRepair.makePrintable(positions: positions, faces: faces)
        XCTAssertEqual(out.faces.count, 4, "speck faces removed")
        XCTAssertEqual(out.report.componentsDropped, 1)
        XCTAssertEqual(out.positions.count, 4, "speck verts compacted away")
        XCTAssertTrue(Self.manifoldOrOpen(out.faces))
    }

    // MARK: - idempotent + watertight on a clean closed mesh

    func testCleanSphereUnchangedAndWatertight() {
        let (pos, faces) = Self.icosphere(subdivisions: 3)
        let out = MeshRepair.makePrintable(positions: pos, faces: faces)
        XCTAssertEqual(out.report.welded, 0)
        XCTAssertEqual(out.report.degenerateRemoved, 0)
        XCTAssertEqual(out.report.componentsDropped, 0)
        XCTAssertTrue(out.report.watertight)
        XCTAssertEqual(out.faces.count, faces.count)
        XCTAssertEqual(out.positions.count, pos.count)
        XCTAssertTrue(MeshRepair.isClosedManifold(out.faces))
        XCTAssertGreaterThan(Self.signedVolume(out.positions, out.faces), 0)
    }

    // MARK: - deterministic across runs

    func testDeterministic() {
        var (pos, faces) = Self.icosphere(subdivisions: 3)
        pos.append(pos[0]); faces.append(SIMD3(UInt32(pos.count - 1), 0, 0))   // dup vert + degenerate face
        let a = MeshRepair.makePrintable(positions: pos, faces: faces)
        let b = MeshRepair.makePrintable(positions: pos, faces: faces)
        XCTAssertEqual(a.positions, b.positions)
        XCTAssertEqual(a.faces, b.faces)
        XCTAssertEqual(a.report, b.report)
    }

    // MARK: - helpers

    static func manifoldOrOpen(_ faces: [SIMD3<UInt32>]) -> Bool {
        var count: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(min(a, b)) << 32) | UInt64(max(a, b)) }
        for f in faces {
            count[key(f.x, f.y), default: 0] += 1
            count[key(f.y, f.z), default: 0] += 1
            count[key(f.z, f.x), default: 0] += 1
        }
        return count.values.allSatisfy { $0 <= 2 }
    }

    static func signedVolume(_ pos: [SIMD3<Float>], _ faces: [SIMD3<UInt32>]) -> Double {
        func d(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
        var v = 0.0
        for f in faces { v += simd_dot(d(pos[Int(f.x)]), simd_cross(d(pos[Int(f.y)]), d(pos[Int(f.z)]))) }
        return v / 6
    }

    static func icosphere(subdivisions: Int) -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        let t = Float((1.0 + 5.0.squareRoot()) / 2.0)
        var verts: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { simd_normalize($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]
        var mid: [UInt64: Int] = [:]
        func midpoint(_ a: Int, _ b: Int) -> Int {
            let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
            if let m = mid[key] { return m }
            verts.append(simd_normalize((verts[a] + verts[b]) * 0.5))
            mid[key] = verts.count - 1
            return verts.count - 1
        }
        for _ in 0..<subdivisions {
            var next: [(Int, Int, Int)] = []
            for (a, b, c) in faces {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
            faces = next
        }
        return (verts, faces.map { SIMD3(UInt32($0.0), UInt32($0.1), UInt32($0.2)) })
    }
}
