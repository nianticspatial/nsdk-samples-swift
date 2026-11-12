// Copyright 2026 Niantic Spatial.

import RealityKit
import NSDK
import UIKit
import simd

/// Renders accumulated map feature points as a cloud of small cubes anchored in the AR scene.
///
/// The point set is uniformly subsampled to at most `maxDisplayedPoints` cubes so the mesh
/// stays bounded regardless of how large the underlying map grows. `updateAnchorTransform`
/// repositions the existing cloud without rebuilding any geometry.
final class PointCloudRenderer {

    private let nsdkView: NSDKView

    // MARK: - State

    private var mapAnchorEntity: AnchorEntity?
    private var visualizedEntities: [Entity] = []
    private var cachedPointMaterial: UnlitMaterial?
    private let maxDisplayedPoints = 3000

    // MARK: - Initialization

    init(nsdkView: NSDKView) {
        self.nsdkView = nsdkView
    }

    // MARK: - Rendering

    func visualize(points: [SIMD3<Float>], anchorTransform: simd_float4x4) {
        clear()
        guard !points.isEmpty else { return }

        let step = max(1, points.count / maxDisplayedPoints)
        let halfSize: Float = 0.0035

        let baseVerts: [SIMD3<Float>] = [
            [-halfSize, -halfSize,  halfSize], [ halfSize, -halfSize,  halfSize],
            [ halfSize,  halfSize,  halfSize], [-halfSize,  halfSize,  halfSize],
            [-halfSize, -halfSize, -halfSize], [ halfSize, -halfSize, -halfSize],
            [ halfSize,  halfSize, -halfSize], [-halfSize,  halfSize, -halfSize],
        ]
        let baseIdx: [UInt32] = [
            0,1,2, 0,2,3,  5,4,7, 5,7,6,
            3,2,6, 3,6,7,  4,5,1, 4,1,0,
            1,5,6, 1,6,2,  4,0,3, 4,3,7,
        ]

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var vertexOffset: UInt32 = 0

        for i in stride(from: 0, to: points.count, by: step) {
            guard positions.count / baseVerts.count < maxDisplayedPoints else { break }
            let center = points[i]
            positions.append(contentsOf: baseVerts.map { $0 + center })
            indices.append(contentsOf: baseIdx.map { $0 + vertexOffset })
            vertexOffset += UInt32(baseVerts.count)
        }

        var descriptor = MeshDescriptor(name: "mapCubes")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)

        guard let mesh = try? MeshResource.generate(from: [descriptor]) else {
            print("[PointCloudRenderer] Failed to generate mesh")
            return
        }

        if cachedPointMaterial == nil {
            cachedPointMaterial = UnlitMaterial(color: .init(red: 0.3, green: 0.8, blue: 0.0, alpha: 1.0))
        }

        let entity = ModelEntity(mesh: mesh, materials: [cachedPointMaterial!])
        let anchor = AnchorEntity()
        anchor.transform = Transform(matrix: anchorTransform)
        anchor.addChild(entity)

        nsdkView.scene.addAnchor(anchor)
        mapAnchorEntity = anchor
        visualizedEntities.append(anchor)
    }

    /// Reposition the existing anchor entity — no geometry rebuild.
    func updateAnchorTransform(_ transform: simd_float4x4) {
        mapAnchorEntity?.transform = Transform(matrix: transform)
    }

    func clear() {
        for entity in visualizedEntities {
            if let anchor = entity as? AnchorEntity {
                nsdkView.scene.removeAnchor(anchor)
            } else {
                entity.removeFromParent()
            }
        }
        visualizedEntities.removeAll()
        mapAnchorEntity = nil
    }
}
