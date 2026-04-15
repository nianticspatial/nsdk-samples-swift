// Copyright 2026 Niantic Spatial.

import Foundation
import Metal
import RealityKit
import simd
import NSDK
import Combine
import UIKit

/// Converts NSDKMeshingSession mesh updates into RealityKit ModelEntity chunks for rendering.
///
/// Subscribes to:
/// - `meshingSession.meshUpdates` for insert/update/remove mesh events
///
/// Publishes:
/// - `updatedMeshChunks`: `[Int64: ModelEntity?]` — all chunk insert/update/remove changes from a single `meshUpdates` emission (`nil` = removal). This publisher emits exactly once per `meshUpdates` emission (PassthroughSubject does not replay prior values to new subscribers).
final class MeshingViewModel {

    // MARK: - Published State

    let updatedMeshChunks = PassthroughSubject<[Int64: ModelEntity?], Never>()

    // MARK: - Private

    private var meshMaterial: CustomMaterial?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(meshingSession: NSDKMeshingSession) {
        let mtlLibrary = MTLCreateSystemDefaultDevice()!.makeDefaultLibrary()!
        let surfaceShader = CustomMaterial.SurfaceShader(named: "normalSurfaceShader", in: mtlLibrary)
        let simpleMaterial = SimpleMaterial(
            color: UIColor(white: 1.0, alpha: 1),
            roughness: 0.5,
            isMetallic: false
        )
        self.meshMaterial = try! CustomMaterial(from: simpleMaterial, surfaceShader: surfaceShader)

        // One `updatedMeshChunks` emission per `meshUpdates` emission: aggregate that emission's chunk updates into one `[Int64: ModelEntity?]` dictionary, then send.
        meshingSession.meshUpdates
        .sink { [weak self] updates in
            guard let self else { return }
            var chunkChanges: [Int64: ModelEntity?] = [:]
            for chunkUpdate in updates {
                switch chunkUpdate {
                case .insert(let id, let data), .update(let id, let data):
                    if let meshResource = data.toMeshResource() {
                        chunkChanges[id] = ModelEntity(mesh: meshResource, materials: [meshMaterial!])
                    }
                case .remove(let id):
                    chunkChanges[id] = nil
                }
            }
            updatedMeshChunks.send(chunkChanges)
        }
        .store(in: &cancellables)
    }

    func cleanup() {
        meshMaterial = nil
    }
}
