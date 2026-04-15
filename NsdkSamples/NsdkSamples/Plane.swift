// Copyright 2026 Niantic Spatial.

import ARKit
import RealityKit

extension UIColor {
    static let planeColor = UIColor(named: "planeColor")!
}

class Plane: Entity {
    let meshEntity: ModelEntity
    let extentEntity: ModelEntity
    var classificationEntity: ModelEntity?
    
    init(anchor: ARPlaneAnchor, in arView: ARView) {
        #if targetEnvironment(simulator)
        #error("ARKit is not supported in iOS Simulator. Connect a physical iOS device and select it as your Xcode run destination, or select Generic iOS Device as a build-only destination.")
        #else
        
    let meshMaterial = SimpleMaterial(color: UIColor.planeColor.withAlphaComponent(0.25), isMetallic: false)
    // ARPlaneAnchor.extent is a SIMD3<Float> containing (width, _, depth)
    let mesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    meshEntity = ModelEntity(mesh: mesh, materials: [meshMaterial])

    let extentMesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    let extentMaterial = SimpleMaterial(color: UIColor.planeColor.withAlphaComponent(0.6), isMetallic: false)
    extentEntity = ModelEntity(mesh: extentMesh, materials: [extentMaterial])

    super.init()

    self.transform = Transform(matrix: anchor.transform)
    addChild(meshEntity)
    addChild(extentEntity)
    extentEntity.position = SIMD3(anchor.center.x, 0, anchor.center.z)
        
        if #available(iOS 12.0, *), ARPlaneAnchor.isClassificationSupported {
            let classification = anchor.classification.debugDescription
            classificationEntity = makeTextEntity(classification)
            if let textEntity = classificationEntity {
                extentEntity.addChild(textEntity)
                textEntity.position = [0, 0.01, 0] // Slightly above the plane
            }
        }
        #endif
    }
    
    required init() {
        fatalError("init() has not been implemented")
    }
    
    private func makeTextEntity(_ text: String) -> ModelEntity {
        let mesh = MeshResource.generateText(text,
                                          extrusionDepth: 0.001,
                                          font: .systemFont(ofSize: 0.05),
                                          containerFrame: .zero,
                                          alignment: .center,
                                          lineBreakMode: .byTruncatingTail)
        
        let material = SimpleMaterial(color: .white, isMetallic: false)
        let textEntity = ModelEntity(mesh: mesh, materials: [material])
        textEntity.scale = [0.1, 0.1, 0.1]
        return textEntity
    }
    
    func update(anchor: ARPlaneAnchor) {
        self.transform = Transform(matrix: anchor.transform)

        let mesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
        meshEntity.model?.mesh = mesh

        let extentMesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
        extentEntity.model?.mesh = extentMesh
        extentEntity.position = SIMD3(anchor.center.x, 0, anchor.center.z)

        if #available(iOS 12.0, *), ARPlaneAnchor.isClassificationSupported {
            let newClassification = anchor.classification.debugDescription
            if let textEntity = classificationEntity {
                let newMesh = MeshResource.generateText(newClassification,
                                                     extrusionDepth: 0.001,
                                                     font: .systemFont(ofSize: 0.05),
                                                     containerFrame: .zero,
                                                     alignment: .center,
                                                     lineBreakMode: .byTruncatingTail)
                textEntity.model?.mesh = newMesh
            }
        }
    }
}
