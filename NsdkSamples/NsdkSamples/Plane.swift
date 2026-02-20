/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Convenience class for visualizing Plane extent and geometry
*/

import ARKit
import RealityKit

// Convenience extension for colors defined in asset catalog.
extension UIColor {
    static let planeColor = UIColor(named: "planeColor")!
}

class Plane: Entity {
    let meshEntity: ModelEntity
    let extentEntity: ModelEntity
    var classificationEntity: ModelEntity?
    
    /// - Tag: VisualizePlane
    init(anchor: ARPlaneAnchor, in arView: ARView) {
        #if targetEnvironment(simulator)
        #error("ARKit is not supported in iOS Simulator. Connect a physical iOS device and select it as your Xcode run destination, or select Generic iOS Device as a build-only destination.")
        #else
        
    // Create a mesh to visualize the estimated shape of the plane
    let meshMaterial = SimpleMaterial(color: UIColor.planeColor.withAlphaComponent(0.25), isMetallic: false)
    // ARPlaneAnchor.extent is a SIMD3<Float> containing (width, _, depth)
    let mesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    meshEntity = ModelEntity(mesh: mesh, materials: [meshMaterial])

    // Create an entity to visualize the plane's bounding rectangle
    let extentMesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    let extentMaterial = SimpleMaterial(color: UIColor.planeColor.withAlphaComponent(0.6), isMetallic: false)
    extentEntity = ModelEntity(mesh: extentMesh, materials: [extentMaterial])
        
    // Initialize the base entity and position it at the anchor transform so children are in anchor-local space
    super.init()

    // Set this entity's transform to the AR anchor transform so child entities can use anchor-local coordinates
    self.transform = Transform(matrix: anchor.transform)

    // Add the plane extent and plane geometry as child entities
    addChild(meshEntity)
    addChild(extentEntity)

    // Position the extent entity in anchor-local coordinates (center is already in anchor-local space)
    extentEntity.position = SIMD3(anchor.center.x, 0, anchor.center.z)
        
        // Display the plane's classification, if supported on the device
        if #available(iOS 12.0, *), ARPlaneAnchor.isClassificationSupported {
            let classification = anchor.classification.description
            classificationEntity = makeTextEntity(classification)
            if let textEntity = classificationEntity {
                extentEntity.addChild(textEntity)
                // Center the text
                textEntity.position = [0, 0.01, 0] // Slightly above the plane
            }
        }
        #endif
    }
    
    required init() {
        fatalError("init() has not been implemented")
    }
    
    private func makeTextEntity(_ text: String) -> ModelEntity {
        // Create a text mesh
        let mesh = MeshResource.generateText(text,
                                          extrusionDepth: 0.001,
                                          font: .systemFont(ofSize: 0.05),
                                          containerFrame: .zero,
                                          alignment: .center,
                                          lineBreakMode: .byTruncatingTail)
        
        let material = SimpleMaterial(color: .white, isMetallic: false)
        let textEntity = ModelEntity(mesh: mesh, materials: [material])
        
        // Scale and position the text
        textEntity.scale = [0.1, 0.1, 0.1]
        
        return textEntity
    }
    
    func update(anchor: ARPlaneAnchor) {
    // Update this entity transform to match the anchor's transform
    self.transform = Transform(matrix: anchor.transform)

    // Update the mesh to match the plane's updated geometry
    let mesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    meshEntity.model?.mesh = mesh

    // Update the extent visualization
    let extentMesh = MeshResource.generatePlane(width: Float(anchor.planeExtent.width), depth: Float(anchor.planeExtent.height))
    extentEntity.model?.mesh = extentMesh
    extentEntity.position = SIMD3(anchor.center.x, 0, anchor.center.z)
        
        // Update classification text if needed
        if #available(iOS 12.0, *), ARPlaneAnchor.isClassificationSupported {
            let newClassification = anchor.classification.description
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
