import Foundation
import simd

/// A user-pickable export format for the generated mesh.
enum MeshExportFormat: String, CaseIterable, Identifiable {
    case glb, obj, stl, ply

    var id: String { rawValue }
    var ext: String { rawValue }

    /// Menu label. Hints stay true whether or not the source has a texture
    /// (the shape mesh has none; the painted mesh does).
    var menuTitle: String {
        switch self {
        case .glb: return "GLB · 3D / AR / web (single file)"
        case .obj: return "OBJ · mesh + material"
        case .stl: return "STL · geometry (3D printing)"
        case .ply: return "PLY · geometry data"
        }
    }

    var icon: String {
        switch self {
        case .glb: return "shippingbox"
        case .obj: return "cube"
        case .stl: return "printer"
        case .ply: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Converts Modelr's compact binary meshes into standard interchange formats.
///
/// Pure-Foundation (no AppKit / SceneKit) so it can be unit-tested standalone and
/// run off the main thread. Source layouts:
///   `.mesh`  = [i32 n][i32 m][f32 verts n*3][f32 normals n*3][i32 faces m*3]
///   `.tmesh` = [i32 n][i32 m][f32 verts n*3][f32 normals n*3][f32 uvs n*2][i32 faces m*3] + separate PNG
enum MeshExporter {
    enum ExportError: Error { case unreadable, empty, truncated }

    struct MeshData {
        let vertCount: Int
        let faceCount: Int
        let verts: [Float]        // 3 * vertCount
        let normals: [Float]      // 3 * vertCount
        let uvs: [Float]?         // 2 * vertCount, or nil (untextured)
        let indices: [UInt32]     // 3 * faceCount
        // Raw little-endian source slices (same byte layout glTF wants) for fast GLB packing.
        let rawVerts: Data
        let rawNormals: Data
        let rawUVs: Data?
        let rawFaces: Data
        let texturePNG: Data?     // raw PNG bytes (textured export: baseColor/albedo)
        /// Optional metallic-roughness PNG (glTF 2.0 convention: G = roughness,
        /// B = metallic). Provided by the PBR paint path; GLB embeds it alongside
        /// the base color.
        let metallicRoughnessPNG: Data?
    }

    // MARK: - Public entry point

    /// Read `meshURL` (+ optional `texture` and `metallicRoughness`) and write
    /// `format` to `dest`. OBJ additionally writes a companion `.mtl` and `.png`
    /// next to `dest`. `metallicRoughness` affects GLB only (§4.8: PBR GLB carries
    /// albedo + metallic-roughness); the other formats have no standard slot for it.
    static func export(meshURL: URL, texture: URL?, metallicRoughness: URL? = nil,
                       format: MeshExportFormat, to dest: URL) throws {
        let mesh = try read(meshURL: meshURL, textureURL: texture,
                            metallicRoughnessURL: metallicRoughness)
        switch format {
        // STL is the 3D-printing format: repair the geometry first so slicers accept
        // it without a "not watertight / non-manifold" warning (§ mesh-repair spec).
        case .stl: try encodeSTL(makePrintable(mesh)).write(to: dest)
        case .ply: try encodePLY(mesh).write(to: dest)
        case .glb: try encodeGLB(mesh).write(to: dest)
        case .obj:
            let dir = dest.deletingLastPathComponent()
            let base = dest.deletingPathExtension().lastPathComponent
            var textureName: String? = nil
            if let png = mesh.texturePNG, mesh.uvs != nil {
                textureName = base + ".png"
                try png.write(to: dir.appendingPathComponent(textureName!))
            }
            let mtlName = textureName != nil ? base + ".mtl" : nil
            let (objData, mtlData) = encodeOBJ(mesh, mtlName: mtlName, textureName: textureName)
            try objData.write(to: dest)
            if let mtlData, let mtlName {
                try mtlData.write(to: dir.appendingPathComponent(mtlName))
            }
        }
    }

    // MARK: - Reading

    static func read(meshURL: URL, textureURL: URL?,
                     metallicRoughnessURL: URL? = nil) throws -> MeshData {
        guard let data = try? Data(contentsOf: meshURL), data.count >= 8 else { throw ExportError.unreadable }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        let m = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) })
        guard n > 0, m > 0 else { throw ExportError.empty }

        let textured = textureURL != nil
        let vBytes = n * 12, nBytes = n * 12, uvBytes = textured ? n * 8 : 0, fBytes = m * 12
        guard data.count >= 8 + vBytes + nBytes + uvBytes + fBytes else { throw ExportError.truncated }

        var off = 8
        let rawVerts = data.subdata(in: off ..< off + vBytes); off += vBytes
        let rawNormals = data.subdata(in: off ..< off + nBytes); off += nBytes
        var rawUVs: Data? = nil
        if textured { rawUVs = data.subdata(in: off ..< off + uvBytes); off += uvBytes }
        let rawFaces = data.subdata(in: off ..< off + fBytes)

        let verts = floats(rawVerts, count: n * 3)
        let normals = floats(rawNormals, count: n * 3)
        let uvs = rawUVs.map { floats($0, count: n * 2) }
        let indices = uints(rawFaces, count: m * 3)

        var png: Data? = nil
        if let textureURL { png = try? Data(contentsOf: textureURL) }
        var mrPNG: Data? = nil
        if let metallicRoughnessURL { mrPNG = try? Data(contentsOf: metallicRoughnessURL) }

        return MeshData(vertCount: n, faceCount: m, verts: verts, normals: normals, uvs: uvs,
                        indices: indices, rawVerts: rawVerts, rawNormals: rawNormals,
                        rawUVs: rawUVs, rawFaces: rawFaces, texturePNG: png,
                        metallicRoughnessPNG: mrPNG)
    }

    private static func floats(_ d: Data, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        d.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: Float32.self) }
        }
        return out
    }

    private static func uints(_ d: Data, count: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: count)
        d.withUnsafeBytes { raw in
            for i in 0..<count { out[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
        }
        return out
    }

    // MARK: - print repair (STL)

    /// Run `MeshRepair` over the mesh geometry and return a geometry-only `MeshData`
    /// (STL carries no normals/UVs/texture — `encodeSTL` recomputes face normals).
    /// Bridges the exporter's flat arrays to MeshRepair's SIMD3 representation.
    static func makePrintable(_ mesh: MeshData) -> MeshData {
        var positions = [SIMD3<Float>](); positions.reserveCapacity(mesh.vertCount)
        for i in 0..<mesh.vertCount {
            positions.append(SIMD3(mesh.verts[i*3], mesh.verts[i*3+1], mesh.verts[i*3+2]))
        }
        var faces = [SIMD3<UInt32>](); faces.reserveCapacity(mesh.faceCount)
        for f in 0..<mesh.faceCount {
            faces.append(SIMD3(mesh.indices[f*3], mesh.indices[f*3+1], mesh.indices[f*3+2]))
        }
        let r = MeshRepair.makePrintable(positions: positions, faces: faces)

        var verts = [Float](repeating: 0, count: r.positions.count * 3)
        for (i, p) in r.positions.enumerated() { verts[i*3] = p.x; verts[i*3+1] = p.y; verts[i*3+2] = p.z }
        var idx = [UInt32](repeating: 0, count: r.faces.count * 3)
        for (i, f) in r.faces.enumerated() { idx[i*3] = f.x; idx[i*3+1] = f.y; idx[i*3+2] = f.z }

        return MeshData(vertCount: r.positions.count, faceCount: r.faces.count,
                        verts: verts, normals: [], uvs: nil, indices: idx,
                        rawVerts: Data(), rawNormals: Data(), rawUVs: nil, rawFaces: Data(),
                        texturePNG: nil, metallicRoughnessPNG: nil)
    }

    // MARK: - STL (binary, little-endian)

    static func encodeSTL(_ mesh: MeshData) -> Data {
        var out = Data(capacity: 84 + mesh.faceCount * 50)
        out.append(Data(count: 80))                 // header
        out.appendLE(UInt32(mesh.faceCount))
        let v = mesh.verts
        for f in 0..<mesh.faceCount {
            let i0 = Int(mesh.indices[f * 3]) * 3
            let i1 = Int(mesh.indices[f * 3 + 1]) * 3
            let i2 = Int(mesh.indices[f * 3 + 2]) * 3
            let ax = v[i0], ay = v[i0 + 1], az = v[i0 + 2]
            let bx = v[i1], by = v[i1 + 1], bz = v[i1 + 2]
            let cx = v[i2], cy = v[i2 + 1], cz = v[i2 + 2]
            // geometric normal = (b-a) × (c-a), normalized
            let ux = bx - ax, uy = by - ay, uz = bz - az
            let wx = cx - ax, wy = cy - ay, wz = cz - az
            var nx = uy * wz - uz * wy
            var ny = uz * wx - ux * wz
            var nz = ux * wy - uy * wx
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0 { nx /= len; ny /= len; nz /= len } else { nx = 0; ny = 0; nz = 0 }
            out.appendLE(nx); out.appendLE(ny); out.appendLE(nz)
            out.appendLE(ax); out.appendLE(ay); out.appendLE(az)
            out.appendLE(bx); out.appendLE(by); out.appendLE(bz)
            out.appendLE(cx); out.appendLE(cy); out.appendLE(cz)
            out.appendLE(UInt16(0))                 // attribute byte count
        }
        return out
    }

    // MARK: - OBJ (+ MTL)

    static func encodeOBJ(_ mesh: MeshData, mtlName: String?, textureName: String?) -> (obj: Data, mtl: Data?) {
        let hasUV = mesh.uvs != nil && textureName != nil
        var s = "# Modelr export\n"
        s.reserveCapacity(mesh.vertCount * 64 + mesh.faceCount * 40)
        if hasUV, let mtlName { s += "mtllib \(mtlName)\nusemtl material0\n" }

        let v = mesh.verts, nrm = mesh.normals
        for i in 0..<mesh.vertCount {
            s += "v \(v[i*3]) \(v[i*3+1]) \(v[i*3+2])\n"
        }
        for i in 0..<mesh.vertCount {
            s += "vn \(nrm[i*3]) \(nrm[i*3+1]) \(nrm[i*3+2])\n"
        }
        if hasUV, let uv = mesh.uvs {
            // Our UVs use a top-left origin (SceneKit); OBJ's vt origin is bottom-left → flip V.
            for i in 0..<mesh.vertCount {
                s += "vt \(uv[i*2]) \(1 - uv[i*2+1])\n"
            }
        }
        for f in 0..<mesh.faceCount {
            let a = Int(mesh.indices[f*3]) + 1
            let b = Int(mesh.indices[f*3+1]) + 1
            let c = Int(mesh.indices[f*3+2]) + 1
            if hasUV {
                s += "f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n"
            } else {
                s += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            }
        }

        var mtl: Data? = nil
        if hasUV, let textureName {
            // OBJ/MTL has no standard metallic-roughness slot, so a PBR export carries
            // the albedo (base color) only — note it so the dropped map isn't a surprise.
            let pbrNote = mesh.metallicRoughnessPNG != nil
                ? "# albedo (base color) only — OBJ/MTL has no metallic-roughness slot; use GLB for full PBR\n"
                : ""
            let m = """
            # Modelr material
            \(pbrNote)newmtl material0
            Ka 1.000 1.000 1.000
            Kd 1.000 1.000 1.000
            Ks 0.000 0.000 0.000
            d 1.0
            illum 2
            map_Kd \(textureName)
            """
            mtl = Data(m.utf8)
        }
        return (Data(s.utf8), mtl)
    }

    // MARK: - PLY (binary little-endian)

    static func encodePLY(_ mesh: MeshData) -> Data {
        let hasUV = mesh.uvs != nil
        var header = """
        ply
        format binary_little_endian 1.0
        comment Modelr export
        element vertex \(mesh.vertCount)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz

        """
        if hasUV { header += "property float s\nproperty float t\n" }
        header += """
        element face \(mesh.faceCount)
        property list uchar uint vertex_indices
        end_header

        """
        var out = Data(header.utf8)
        out.reserveCapacity(header.count + mesh.vertCount * 32 + mesh.faceCount * 13)
        let v = mesh.verts, nrm = mesh.normals
        for i in 0..<mesh.vertCount {
            out.appendLE(v[i*3]); out.appendLE(v[i*3+1]); out.appendLE(v[i*3+2])
            out.appendLE(nrm[i*3]); out.appendLE(nrm[i*3+1]); out.appendLE(nrm[i*3+2])
            if hasUV, let uv = mesh.uvs { out.appendLE(uv[i*2]); out.appendLE(uv[i*2+1]) }
        }
        for f in 0..<mesh.faceCount {
            out.append(UInt8(3))
            out.appendLE(mesh.indices[f*3]); out.appendLE(mesh.indices[f*3+1]); out.appendLE(mesh.indices[f*3+2])
        }
        return out
    }

    // MARK: - GLB (glTF 2.0 binary, single file with embedded PNG)

    static func encodeGLB(_ mesh: MeshData) -> Data {
        let n = mesh.vertCount
        let m3 = mesh.faceCount * 3
        let hasUV = mesh.rawUVs != nil && mesh.texturePNG != nil
        // PBR: a metallic-roughness map rides along only when the base color does
        // (both sample the same TEXCOORD_0 per glTF 2.0 pbrMetallicRoughness).
        let hasMR = hasUV && mesh.metallicRoughnessPNG != nil

        // BIN buffer — concatenate the raw LE slices (already in glTF's expected byte layout),
        // 4-byte aligned by construction (12n, 12n, 8n, 12m are all multiples of 4).
        var bin = Data()
        bin.reserveCapacity(mesh.rawVerts.count + mesh.rawNormals.count
                            + (mesh.rawUVs?.count ?? 0) + mesh.rawFaces.count
                            + (mesh.texturePNG?.count ?? 0) + 4)
        let posOffset = 0
        bin.append(mesh.rawVerts)
        let norOffset = bin.count
        bin.append(mesh.rawNormals)
        var uvOffset = 0
        if hasUV, let uv = mesh.rawUVs { uvOffset = bin.count; bin.append(uv) }
        let idxOffset = bin.count
        bin.append(mesh.rawFaces)
        var imgOffset = 0, imgLen = 0
        if hasUV, let png = mesh.texturePNG {
            imgOffset = bin.count       // already 4-aligned (follows 12m indices)
            imgLen = png.count
            bin.append(png)
        }
        var mrOffset = 0, mrLen = 0
        if hasMR, let mr = mesh.metallicRoughnessPNG {
            while bin.count % 4 != 0 { bin.append(0) }  // PNG lengths aren't 4-aligned
            mrOffset = bin.count
            mrLen = mr.count
            bin.append(mr)
        }
        let bufferLen = bin.count       // logical buffer length (unpadded)
        while bin.count % 4 != 0 { bin.append(0) }     // pad chunk to 4 bytes

        // POSITION accessor requires min/max.
        var mn = [Double](repeating: .greatestFiniteMagnitude, count: 3)
        var mx = [Double](repeating: -.greatestFiniteMagnitude, count: 3)
        let v = mesh.verts
        for i in 0..<n {
            for k in 0..<3 {
                let val = Double(v[i*3 + k])
                if val < mn[k] { mn[k] = val }
                if val > mx[k] { mx[k] = val }
            }
        }

        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3",
             "min": mn, "max": mx],
            ["bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"],
        ]
        var bufferViews: [[String: Any]] = [
            ["buffer": 0, "byteOffset": posOffset, "byteLength": n * 12, "target": 34962],
            ["buffer": 0, "byteOffset": norOffset, "byteLength": n * 12, "target": 34962],
        ]
        var attributes: [String: Any] = ["POSITION": 0, "NORMAL": 1]
        var nextAccessor = 2, nextBV = 2

        if hasUV {
            attributes["TEXCOORD_0"] = nextAccessor
            accessors.append(["bufferView": nextBV, "componentType": 5126, "count": n, "type": "VEC2"])
            bufferViews.append(["buffer": 0, "byteOffset": uvOffset, "byteLength": n * 8, "target": 34962])
            nextAccessor += 1; nextBV += 1
        }
        let idxAccessor = nextAccessor
        accessors.append(["bufferView": nextBV, "componentType": 5125, "count": m3, "type": "SCALAR"])
        bufferViews.append(["buffer": 0, "byteOffset": idxOffset, "byteLength": m3 * 4, "target": 34963])
        nextAccessor += 1; nextBV += 1

        var primitive: [String: Any] = ["attributes": attributes, "indices": idxAccessor]
        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Modelr"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "buffers": [["byteLength": bufferLen]],
        ]

        if hasUV {
            let imgBV = nextBV
            bufferViews.append(["buffer": 0, "byteOffset": imgOffset, "byteLength": imgLen])
            nextBV += 1
            var textures: [[String: Any]] = [["sampler": 0, "source": 0]]
            var images: [[String: Any]] = [["bufferView": imgBV, "mimeType": "image/png"]]
            var pbr: [String: Any] = ["baseColorTexture": ["index": 0]]
            if hasMR {
                // glTF 2.0 pbrMetallicRoughness: the map's G channel is roughness,
                // B is metallic; factors are multipliers, so both stay 1.0.
                let mrBV = nextBV
                bufferViews.append(["buffer": 0, "byteOffset": mrOffset, "byteLength": mrLen])
                nextBV += 1
                images.append(["bufferView": mrBV, "mimeType": "image/png"])
                textures.append(["sampler": 0, "source": 1])
                pbr["metallicRoughnessTexture"] = ["index": 1]
                pbr["metallicFactor"] = 1.0
                pbr["roughnessFactor"] = 1.0
            } else {
                // RGB-only texture: matte fallback (no metals without an MR map).
                pbr["metallicFactor"] = 0.0
                pbr["roughnessFactor"] = 1.0
            }
            primitive["material"] = 0
            json["materials"] = [["name": "painted", "pbrMetallicRoughness": pbr]]
            json["textures"] = textures
            json["images"] = images
            json["samplers"] = [["magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497]]
        }

        json["accessors"] = accessors
        json["bufferViews"] = bufferViews
        json["meshes"] = [["primitives": [primitive]]]

        let jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        var jsonChunk = jsonData
        while jsonChunk.count % 4 != 0 { jsonChunk.append(0x20) }   // pad with spaces

        var glb = Data()
        glb.reserveCapacity(12 + 8 + jsonChunk.count + 8 + bin.count)
        let total = 12 + 8 + jsonChunk.count + 8 + bin.count
        glb.appendLE(UInt32(0x4654_6C67))           // magic 'glTF'
        glb.appendLE(UInt32(2))                      // version
        glb.appendLE(UInt32(total))
        glb.appendLE(UInt32(jsonChunk.count)); glb.appendLE(UInt32(0x4E4F_534A)); glb.append(jsonChunk)  // 'JSON'
        glb.appendLE(UInt32(bin.count)); glb.appendLE(UInt32(0x004E_4942)); glb.append(bin)              // 'BIN\0'
        return glb
    }
}

private extension Data {
    mutating func appendLE(_ value: Float) {
        var x = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        var x = value.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt16) {
        var x = value.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
