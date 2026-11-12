// Copyright 2026 Niantic Spatial.

import RealityKit
import NSDK

/// Holds meshing chunks as RealityKit model entities under a single world anchor.
///
/// Each `apply(_:)` call corresponds to one `meshUpdates` emission: entities are inserted,
/// replaced, or removed per chunk id (a `nil` entity removes that chunk). The mesh is not
/// persistent — `clear()` removes every chunk so a new meshing pass can start fresh.
final class MeshChunkEntityStore {

    private let nsdkView: NSDKView
    private let meshAnchor: AnchorEntity
    private var meshChunks: [Int64: ModelEntity] = [:]

    var chunkCount: Int { meshChunks.count }

    // MARK: - Initialization

    init(nsdkView: NSDKView) {
        self.nsdkView = nsdkView
        self.meshAnchor = AnchorEntity(world: .zero)
        nsdkView.scene.addAnchor(meshAnchor)
    }

    // MARK: - Rendering

    /// Apply one batch of chunk changes. A `nil` entity for an id removes that chunk.
    func apply(_ changes: [Int64: ModelEntity?]) {
        for (id, entity) in changes {
            renderChunk(id: id, entity: entity)
        }
    }

    func clear() {
        for entity in meshChunks.values {
            entity.removeFromParent()
        }
        meshChunks.removeAll()
    }

    /// Remove the mesh anchor from the scene (call when leaving the screen).
    func detach() {
        meshAnchor.removeFromParent()
    }

    // MARK: - Private

    private func renderChunk(id: Int64, entity: ModelEntity?) {
        if let existingEntity = meshChunks[id] {
            existingEntity.removeFromParent()
        }

        guard let entity else {
            meshChunks.removeValue(forKey: id)
            return
        }

        meshChunks[id] = entity
        meshAnchor.addChild(entity)
    }
}
