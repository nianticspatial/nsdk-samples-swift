import Foundation
import RealityKit
import ARKit
import SwiftyNsdk
import Metal

class MeshingManager: NSObject {
    var meshingSession: NsdkMeshingSession
    weak var arView: ARView!
    weak var infoLabel: UILabel!

    // Dictionary to track mesh chunks by their IDs
    private var meshChunks: [Int64: ModelEntity] = [:]
    private var meshMaterial: CustomMaterial
    private var lastUpdateTime: UInt64 = 0
    private var meshAnchor: AnchorEntity!

    init(nsdk: NsdkSession, arView: ARView, infoLabel: UILabel) {
        meshingSession = nsdk.createMeshingSession()
        self.arView = arView
        self.infoLabel = infoLabel
        let mtlLibrary = MTLCreateSystemDefaultDevice()!.makeDefaultLibrary()!
        
        let surfaceShader = CustomMaterial.SurfaceShader(named: "normalSurfaceShader", in: mtlLibrary)
        // Create a custom material for the mesh
        let simpleMaterial = SimpleMaterial(
            color: UIColor(white: 1.0, alpha: 1),
            roughness: 0.5,
            isMetallic: false
        )
        // Create a custom material for the mesh
        meshMaterial = try! CustomMaterial(from: simpleMaterial, surfaceShader: surfaceShader)

        super.init()
        
        // Create an anchor for all mesh entities
        meshAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(meshAnchor)
    }

    func start() {
        clearMeshChunks()
        var config = NsdkMeshingSession.Configuration()
        config.fuseKeyframesOnly = true
        do {
            try meshingSession.configure(with: config)
            meshingSession.start()
        } catch {
            print("Invalid meshing configuration")
        }
    }

    func stop() {
        meshingSession.stop()
    }

    func updateMesh() {
        let timestamp = meshingSession.lastMeshUpdateTime()

        guard let timestamp = timestamp else {
            // No mesh is available yet
            return
        }

        if lastUpdateTime == timestamp {
            // It's still the same mesh as last time
            return
        }

        lastUpdateTime = timestamp

        let meshInfos = meshingSession.updatedMeshInfos()

        guard let meshInfos = meshInfos else {
            return
        }

        let totalChunks = meshInfos.ids.count / MemoryLayout<Int64>.stride
        var chunksToRemove = Set(meshChunks.keys)
        var numUpdated = 0

        // Process updated chunks
        for (index, chunkId) in meshInfos.ids.enumerated() {
            // If the chunk is still valid, keep it in the scene
            if chunksToRemove.contains(chunkId) {
                chunksToRemove.remove(chunkId)
            }

            // Only process chunks that have been updated
            if meshInfos.updated[index] == 1 {
                let chunkData = meshingSession.meshDataById(id: chunkId)

                if (chunkData != nil) {
                    updateMeshChunk(id: chunkId, chunkData: chunkData!)
                    numUpdated += 1
                } else {
                    print("Error getting mesh data for chunk \(chunkId): ")
                }
            }
        }

        // Process removed chunks
        for id in chunksToRemove {
            if let node = meshChunks[id] {
                node.removeFromParent()
                meshChunks.removeValue(forKey: id)
            }
        }

        // Update info label on main thread
        DispatchQueue.main.async {
            self.infoLabel.text = "Total mesh chunks: \(totalChunks)\nUpdating \(numUpdated), removing \(chunksToRemove.count)"
        }
    }

    private func updateMeshChunk(id: Int64, chunkData: MeshData) {
        // Remove existing chunk if it exists
        if let existingEntity = meshChunks[id] {
            existingEntity.removeFromParent()
        }

        if let meshResource = chunkData.toMeshResource() {
            let modelEntity = ModelEntity(mesh: meshResource, materials: [meshMaterial])
            
            // Store the mesh chunk and render it in the scene
            meshChunks[id] = modelEntity
            meshAnchor.addChild(modelEntity)
        }
    }

    private func clearMeshChunks() {
        for (_, entity) in meshChunks {
            entity.removeFromParent()
        }
        meshChunks.removeAll()
    }
}
