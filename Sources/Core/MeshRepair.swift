import Foundation
import simd

/// Deterministic mesh cleanup so exported geometry imports into slicers
/// (Cura / PrusaSlicer) without "not watertight / non-manifold" warnings — no
/// manual repair step. Runs on print-intended exports (STL) before serialization.
///
/// The generated shape mesh is already a Marching-Cubes surface (closed, manifold),
/// so most real breakage comes downstream: xatlas UV-unwrap splits vertices at
/// seams, QEM decimation can leave degenerate/near-duplicate faces, and MC leaves
/// floating specks in low-density regions. `makePrintable` fixes exactly those.
///
/// Pipeline (order matters): weld coincident verts → drop degenerate/duplicate
/// faces → drop small disconnected components → orient outward → compact.
///
/// Properties (covered by MeshRepairTests):
/// - **Deterministic**: no RNG, no set-iteration order — identical input yields
///   byte-identical output (indices assigned in first-appearance / ascending order).
/// - **Idempotent**: a clean closed mesh passes through unchanged.
/// - **Safe**: never crashes on degenerate input; never emits out-of-range indices.
///
/// Pure value logic in Sources/Core (Foundation + simd only) — unit-testable with
/// no UI, network, or GPU. Not yet handled (P2/route B): hole filling, non-manifold
/// edge splitting, mixed-winding flood-fill, self-intersection.
enum MeshRepair {

    /// What the repair changed — surfaced to the UI and used as a test oracle.
    /// `watertight` reports whether the *result* is a closed 2-manifold.
    struct Report: Equatable {
        var welded = 0
        var degenerateRemoved = 0
        var holesFilled = 0
        var componentsDropped = 0
        var flippedToOutward = false
        var watertight = false
    }

    /// Clean `positions`/`faces` for printing. Never fails: if it can't reach a
    /// fully watertight result, it returns the best-effort mesh with `watertight`
    /// false (the caller may warn or escalate to an SDF re-mesh — route B).
    static func makePrintable(positions: [SIMD3<Float>], faces: [SIMD3<UInt32>])
    -> (positions: [SIMD3<Float>], faces: [SIMD3<UInt32>], report: Report) {
        var report = Report()
        let (verts, welded) = weld(positions, faces, &report)
        let clean = removeDegenerate(welded, verts, &report)
        let kept = dropSmallComponents(clean, verts, &report)
        let oriented = orientOutward(kept, verts, &report)
        let (finalVerts, finalFaces) = compact(verts, oriented)
        report.watertight = isClosedManifold(finalFaces)
        return (finalVerts, finalFaces, report)
    }

    /// Every edge shared by exactly two faces ⇒ closed, 2-manifold (watertight).
    static func isClosedManifold(_ faces: [SIMD3<UInt32>]) -> Bool {
        guard !faces.isEmpty else { return false }
        var count: [UInt64: Int] = [:]
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { (UInt64(min(a, b)) << 32) | UInt64(max(a, b)) }
        for f in faces {
            count[key(f.x, f.y), default: 0] += 1
            count[key(f.y, f.z), default: 0] += 1
            count[key(f.z, f.x), default: 0] += 1
        }
        return count.values.allSatisfy { $0 == 2 }
    }

    // MARK: - weld coincident vertices

    /// Merge vertices that share a position (snapped to an epsilon grid), remap face
    /// indices, and drop the duplicates. Fixes UV-seam splits from xatlas unwrap.
    /// Deterministic: new indices are assigned in first-appearance order.
    private static func weld(_ positions: [SIMD3<Float>], _ faces: [SIMD3<UInt32>],
                             _ report: inout Report) -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        let eps = weldEpsilon(positions)
        struct Cell: Hashable { let x: Int64; let y: Int64; let z: Int64 }
        func cell(_ p: SIMD3<Float>) -> Cell {
            Cell(x: Int64((p.x / eps).rounded()),
                 y: Int64((p.y / eps).rounded()),
                 z: Int64((p.z / eps).rounded()))
        }
        var map: [Cell: UInt32] = [:]
        var newPos: [SIMD3<Float>] = []
        var remap = [UInt32](repeating: 0, count: positions.count)
        for (i, p) in positions.enumerated() {
            let k = cell(p)
            if let idx = map[k] {
                remap[i] = idx
            } else {
                let idx = UInt32(newPos.count)
                map[k] = idx
                newPos.append(p)
                remap[i] = idx
            }
        }
        report.welded = positions.count - newPos.count
        let newFaces = faces.map { SIMD3(remap[Int($0.x)], remap[Int($0.y)], remap[Int($0.z)]) }
        return (newPos, newFaces)
    }

    /// Weld tolerance relative to the bounding-box diagonal (never below 1e-8).
    private static func weldEpsilon(_ positions: [SIMD3<Float>]) -> Float {
        guard let first = positions.first else { return 1e-6 }
        var lo = first, hi = first
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return max(simd_length(hi - lo) * 1e-5, 1e-8)
    }

    // MARK: - remove degenerate + duplicate faces

    /// Drop faces that can't print: repeated-index, zero-area (collinear), and exact
    /// duplicates (same vertex set, first occurrence kept). Orientation is fixed later,
    /// so duplicates are matched by sorted index triple (winding-agnostic).
    private static func removeDegenerate(_ faces: [SIMD3<UInt32>], _ positions: [SIMD3<Float>],
                                         _ report: inout Report) -> [SIMD3<UInt32>] {
        let areaEps = degenerateAreaEps(positions)
        var out: [SIMD3<UInt32>] = []
        var seen: Set<SIMD3<UInt32>> = []
        var removed = 0
        for f in faces {
            if f.x == f.y || f.y == f.z || f.x == f.z { removed += 1; continue }
            let a = positions[Int(f.x)], b = positions[Int(f.y)], c = positions[Int(f.z)]
            if simd_length(simd_cross(b - a, c - a)) <= areaEps { removed += 1; continue }  // 2*area
            let key = sortedTriple(f)
            if seen.contains(key) { removed += 1; continue }
            seen.insert(key)
            out.append(f)
        }
        report.degenerateRemoved = removed
        return out
    }

    private static func sortedTriple(_ f: SIMD3<UInt32>) -> SIMD3<UInt32> {
        var a = f.x, b = f.y, c = f.z
        if a > b { swap(&a, &b) }
        if b > c { swap(&b, &c) }
        if a > b { swap(&a, &b) }
        return SIMD3(a, b, c)
    }

    /// Zero-area threshold on 2*area (|cross|), relative to the mesh scale.
    private static func degenerateAreaEps(_ positions: [SIMD3<Float>]) -> Float {
        guard let first = positions.first else { return 1e-12 }
        var lo = first, hi = first
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let diag = simd_length(hi - lo)
        return max(diag * diag * 1e-10, 1e-20)
    }

    // MARK: - drop small disconnected components

    /// Label connected components (shared-vertex adjacency via union-find) and drop
    /// any whose bounding-box diagonal is under 5% of the largest component's — the
    /// floating specks Marching Cubes leaves in low-density regions.
    private static func dropSmallComponents(_ faces: [SIMD3<UInt32>], _ positions: [SIMD3<Float>],
                                            _ report: inout Report) -> [SIMD3<UInt32>] {
        guard !faces.isEmpty else { return faces }
        var parent = Array(0 ..< positions.count)
        func find(_ x: Int) -> Int { var r = x; while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }; return r }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
        for f in faces { union(Int(f.x), Int(f.y)); union(Int(f.y), Int(f.z)) }

        // Per-component bounding box (only over vertices that faces touch).
        var lo: [Int: SIMD3<Float>] = [:], hi: [Int: SIMD3<Float>] = [:]
        for f in faces {
            for vi in [Int(f.x), Int(f.y), Int(f.z)] {
                let r = find(vi), p = positions[vi]
                lo[r] = lo[r].map { simd_min($0, p) } ?? p
                hi[r] = hi[r].map { simd_max($0, p) } ?? p
            }
        }
        var diag: [Int: Float] = [:]
        for (r, l) in lo { diag[r] = simd_length((hi[r] ?? l) - l) }
        let maxDiag = diag.values.max() ?? 0
        guard maxDiag > 0 else { return faces }
        let threshold = maxDiag * 0.05

        let dropped = Set(diag.filter { $0.value < threshold }.keys)
        report.componentsDropped = dropped.count
        guard !dropped.isEmpty else { return faces }
        return faces.filter { !dropped.contains(find(Int($0.x))) }
    }

    // MARK: - orient faces outward

    /// If the mesh's signed volume is negative, its winding faces inward — reverse
    /// every triangle so normals point outward (what slicers expect). Assumes
    /// consistent winding (true for Marching Cubes output); mixed-winding meshes
    /// need a flood-fill pass first (P2).
    private static func orientOutward(_ faces: [SIMD3<UInt32>], _ positions: [SIMD3<Float>],
                                      _ report: inout Report) -> [SIMD3<UInt32>] {
        guard signedVolume(positions, faces) < 0 else { return faces }
        report.flippedToOutward = true
        return faces.map { SIMD3($0.x, $0.z, $0.y) }   // reverse winding
    }

    private static func signedVolume(_ positions: [SIMD3<Float>], _ faces: [SIMD3<UInt32>]) -> Double {
        func d(_ p: SIMD3<Float>) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), Double(p.z)) }
        var v = 0.0
        for f in faces {
            v += simd_dot(d(positions[Int(f.x)]), simd_cross(d(positions[Int(f.y)]), d(positions[Int(f.z)])))
        }
        return v / 6
    }

    // MARK: - compact unreferenced vertices

    /// Remove vertices no surviving face references; remap indices. Deterministic
    /// (new indices assigned in ascending old-index order).
    private static func compact(_ positions: [SIMD3<Float>], _ faces: [SIMD3<UInt32>])
    -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        var remap = [UInt32?](repeating: nil, count: positions.count)
        var newPos: [SIMD3<Float>] = []
        func map(_ old: UInt32) -> UInt32 {
            if let n = remap[Int(old)] { return n }
            let n = UInt32(newPos.count); remap[Int(old)] = n; newPos.append(positions[Int(old)]); return n
        }
        var used = Set<UInt32>()
        for f in faces { used.insert(f.x); used.insert(f.y); used.insert(f.z) }
        for old in used.sorted() { _ = map(old) }   // ascending → stable remap
        let newFaces = faces.map { SIMD3(map($0.x), map($0.y), map($0.z)) }
        return (newPos, newFaces)
    }
}
