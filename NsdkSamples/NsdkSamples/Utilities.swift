// Copyright 2026 Niantic Spatial.

import ARKit
import RealityKit
import NSDK


@available(iOS 12.0, *)
extension ARPlaneAnchor.Classification {
    var debugDescription: String {
        switch self {
        case .wall:
            return "Wall"
        case .floor:
            return "Floor"
        case .ceiling:
            return "Ceiling"
        case .table:
            return "Table"
        case .seat:
            return "Seat"
        case .none(.unknown):
            return "Unknown"
        default:
            return ""
        }
    }
}

extension ModelEntity {
    func centerAlign() {
        guard let model = model else { return }
        let bounds = model.mesh.bounds
        let center = (bounds.max + bounds.min) / 2
        position = center
    }
}

extension Transform {
    init(translation vector: SIMD3<Float>) {
        self.init(matrix: float4x4(
            float4(1, 0, 0, 0),
            float4(0, 1, 0, 0),
            float4(0, 0, 1, 0),
            float4(vector.x, vector.y, vector.z, 1)
        ))
    }
}

extension MeshData {
    /// Creates a RealityKit `MeshResource` from this mesh data.
    public func toMeshResource() -> MeshResource? {
        // Positions
        let numVertices = verticesPtr.count / 3
        var positions = [SIMD3<Float>]()
        var descriptor = MeshDescriptor(name: "MeshDescriptor")
        positions.reserveCapacity(numVertices)

        for i in 0..<numVertices {
            let index = i * 3
            // Convert NSDK (right-handed?) -> RealityKit (right-handed, Y-up) coordinate adjustment
            // Here we mirror the SCN conversion: invert Y and Z
            let x = verticesPtr[index]
            let y = -verticesPtr[index + 1]
            let z = -verticesPtr[index + 2]
            positions.append(SIMD3<Float>(x, y, z))
        }
        descriptor.positions = MeshBuffers.Positions(positions)

        // Normals (optional)
        var normals: [SIMD3<Float>]? = nil
        if let normalsPtr = normalsPtr {
            normals = [SIMD3<Float>]()
            normals!.reserveCapacity(numVertices)
            for i in 0..<numVertices {
                let index = i * 3
                let nx = normalsPtr[index]
                let ny = -normalsPtr[index + 1]
                let nz = -normalsPtr[index + 2]
                normals!.append(SIMD3<Float>(nx, ny, nz))
            }
            descriptor.normals = MeshBuffers.Normals(normals!)
        }

        // UVs (optional)
        var uvs: [SIMD2<Float>]? = nil
        if let uvsPtr = uvsPtr {
            let numUVs = uvsPtr.count / 2
            uvs = [SIMD2<Float>]()
            uvs!.reserveCapacity(numUVs)
            for i in 0..<numUVs {
                let idx = i * 2
                let u = uvsPtr[idx]
                let v = uvsPtr[idx + 1]
                uvs!.append(SIMD2<Float>(u, v))
            }
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs!)
        }

        // Indices
        let indexCount = indicesPtr.count
        var indices = [UInt32](repeating: 0, count: indexCount)
        for i in 0..<indexCount {
            indices[i] = indicesPtr[i]
        }
        descriptor.primitives = .triangles(indices)
        do {
            let mesh = try MeshResource.generate(from: [descriptor])
            return mesh
        } catch {
            return nil
        }

    }
}
