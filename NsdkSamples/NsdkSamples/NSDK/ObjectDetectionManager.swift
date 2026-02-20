import Foundation
import SwiftyNsdk
import ARKit

struct DetectedObject {
    let rect: CGRect
    let trackingId: UInt32?
    let className: String
    let confidence: Float
}

final class ObjectDetectionManager : NsdkFeatureManager<NsdkObjectDetectionSession> {

    init(nsdk: NsdkSession) {
        super.init(session: nsdk.createObjectDetectionSession())
    }

    override func configuration() -> NsdkObjectDetectionSession.Configuration {
        // The default configuration sets the frequency of inference to 10 fps
        return NsdkObjectDetectionSession.Configuration()
    }

    /// Computes a 3×3 homography that reprojects bounding boxes from an object detection buffer
    /// so they align with the current camera pose provided by an `ARFrame`.
    ///
    /// - Parameters:
    ///   - buffer: The source `ObjectDetectionBuffer` containing camera intrinsics and pose.
    ///   - frame: The target `ARFrame` providing the destination camera transform.
    ///   - viewportOrientation: The orientation of the viewport.
    /// - Returns: A 3×3 homography matrix that maps detected object bounding boxes into the
    ///            coordinate space of the current AR camera. Returns the identity matrix if inputs are missing.
    private func calculateReprojection(for buffer: ObjectDetectionResult, to frame: ARFrame?, viewportOrientation: UIInterfaceOrientation) -> matrix_float3x3 {
        guard let frame = frame else { return matrix_identity_float3x3 }

        // Calculate a rotation that transforms the view
        // matrices to align with the model coordinate frame
        // 1. Determine the rotation angle in radians
        var angle: Float
        switch viewportOrientation {
        case .portrait:
            angle = -.pi / 2
        case .landscapeRight:
            angle = -.pi
        case .portraitUpsideDown:
            angle = -.pi * 1.5
        default:
            angle = 0
        }

        // 2. Create the rotation matrix
        let rotation = float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 0, 1)))

        // 3. Apply the rotation to the view matrices
        let reference = rotation * buffer.pose.inverse
        let target = rotation * frame.camera.transform.inverse

        // Projection params
        let outputSize = CGSize(width: CGFloat(buffer.imageParams.modelFrameWidth), height: CGFloat(buffer.imageParams.modelFrameHeight))
        let aspect = Float(outputSize.width) / Float(outputSize.height)
        let focalLengthY = buffer.intrinsics.columns.1.y
        let fovRadians = 2.0 * atan(Float(outputSize.height) / (2.0 * focalLengthY))

        return ImageMath.reprojection(
            aspect: aspect,
            fovRadians: fovRadians,
            zNear: 0.2,
            zFar: 100.0,
            referenceView: reference,
            targetView: target
        )
    }

    /// Returns the latest detected objects from the object detection model,
    /// with their bounding rectangles mapped to the specified viewport size and orientation.
    /// If an `ARFrame` is provided, the bounding boxes are additionally reprojected to align
    /// with the current camera pose of that frame.
    ///
    /// - Parameters:
    ///   - viewportSize: The size of the viewport to which detection rectangles should be mapped.
    ///   - viewportOrientation: The orientation of the viewport used for coordinate transformation.
    ///   - frame: An optional `ARFrame`. When provided, detection bounding boxes are reprojected
    ///            to match the camera pose of the frame.
    /// - Returns: An array of `DetectedObject` instances with rectangles transformed to the viewport,
    ///            or `nil` if no detections are available.
    func latestDetections(for viewportSize: CGSize, viewportOrientation: UIInterfaceOrientation, threshold: Float, frame: ARFrame? = nil) -> [DetectedObject]? {
            // Pull the latest object detection results
            let resultState = session.latestDetections()
            switch resultState {
            case .inProgress(_):
                return nil;
            case .notReady:
                return nil
            case .failure(let error):
                print("NSDK object detection error: \(error)")
                return nil
            case .success(let result):
                if (result.numDetections == 0) {
                    return []
                }

                // Model output to source image
                guard let modelToSourceImage = session.modelToImageTransform(forPhysicalOrientation: viewportOrientation) else {
                    print("Could not map object detection results to the source image.")
                    return nil
                }

                // Optional: reproject result to match the current camera pose
                let reprojection = calculateReprojection(for: result, to: frame, viewportOrientation: viewportOrientation)

                // Source image to viewport
                let sourceToView = ImageMath.displayTransform(
                    for: viewportOrientation, viewportSize: viewportSize, imageSize: CGSize(width: CGFloat(result.imageParams.sourceFrameWidth), height: CGFloat(result.imageParams.sourceFrameHeight)))

                // Model output to viewport
                let display = modelToSourceImage.concatenating(sourceToView)

                // Inspect the buffer
                let numClasses = Int(result.numClasses)
                let probabilities = result.probabilities!
                let boundingBoxes = result.boundingBoxLocations!
                let trackingIds = result.trackingIds
                let classNames = session.classNames?.names

                // Allocate the resulting array
                var results: [DetectedObject] = []

                for i in 0..<Int(result.numDetections) {
                    // Find the class with the highest probability
                    let probOffset = i * numClasses
                    var bestIndex = -1
                    var bestConfidence: Float = 0
                    for c in 0..<numClasses {
                        let value = probabilities[probOffset + c]
                        if value > bestConfidence {
                            bestConfidence = value
                            bestIndex = c
                        }
                    }

                    // Confidence filter
                    guard bestConfidence > threshold else { continue }

                    // Get the classification for this object
                    let className = (bestIndex >= 0 && bestIndex < (classNames?.count ?? 0))
                    ? classNames?[bestIndex] ?? "unknown"
                    : "unknown"

                    // Get the tracking id for this object
                    let trackingId = (trackingIds != nil && trackingIds!.count > 0) ? trackingIds![i] : nil

                    // Get the corner points of the bounding box
                    let vertexIndex = i * 4
                    let left = Int(boundingBoxes[vertexIndex])
                    let top = Int(boundingBoxes[vertexIndex + 1])
                    let right = Int(boundingBoxes[vertexIndex + 2])
                    let bottom = Int(boundingBoxes[vertexIndex + 3])

                    // Construct the bounding box fitting the viewport
                    let outputSize = CGSize(width: CGFloat(result.imageParams.modelFrameWidth), height: CGFloat(result.imageParams.modelFrameHeight))
                    let rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                        .applyingReprojection(containerSize: outputSize, transform: reprojection)
                        .applyingAffineTransform(containerSize: outputSize, viewSize: viewportSize, transform: display)

                    results.append(DetectedObject(rect: rect, trackingId: trackingId, className: className, confidence: bestConfidence))
                }

                return results
            }
    }
}
