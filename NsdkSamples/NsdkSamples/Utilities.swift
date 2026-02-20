/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Convenience extensions on system types.
*/

import ARKit
import RealityKit

@available(iOS 12.0, *)
extension ARPlaneAnchor.Classification {
    var description: String {
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
