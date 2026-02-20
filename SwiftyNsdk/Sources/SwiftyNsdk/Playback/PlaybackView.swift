import RealityKit
import UIKit

@MainActor
public class PlaybackView : PlaybackRenderer
{
    private var camera: PerspectiveCamera
    private var cameraAnchor: AnchorEntity
    private var backgroundRenderer: PlaybackBackgroundRenderer
    
    public init(in view: UIView, arView: ARView)
    {
        backgroundRenderer = PlaybackBackgroundRenderer(frame: view.frame)
        backgroundRenderer.setup(in: view)
        arView.environment.background = .color(.clear)
        
        let camera = PerspectiveCamera()
        self.camera = camera
        
        let cameraAnchor = AnchorEntity(world:.zero)
        self.cameraAnchor = cameraAnchor
        cameraAnchor.addChild(camera)
        
        arView.scene.addAnchor(cameraAnchor)
    }
    
    public func renderFrame(_ frame: NsdkPlaybackFrame)
    {
        updateCameraPosition(frame.metadata)
        backgroundRenderer.updateBackgroundImage(image: frame.image)
    }
    
    private func updateCameraPosition(_ metadata: PlaybackDataset.FrameMetadata)
    {
        let pose4x4 = metadata.pose4x4
        guard pose4x4.count == 16 else {
            return
        }
        
        let matrix = simd_float4x4(
            SIMD4<Float>(Float(pose4x4[0]), Float(pose4x4[1]), Float(pose4x4[2]), Float(pose4x4[3])),
            SIMD4<Float>(Float(pose4x4[4]), Float(pose4x4[5]), Float(pose4x4[6]), Float(pose4x4[7])),
            SIMD4<Float>(Float(pose4x4[8]), Float(pose4x4[9]), Float(pose4x4[10]), Float(pose4x4[11])),
            SIMD4<Float>(Float(pose4x4[12]), Float(pose4x4[13]), Float(pose4x4[14]), Float(pose4x4[15]))
        )
        cameraAnchor.transform = Transform(matrix: matrix)
    }
}
