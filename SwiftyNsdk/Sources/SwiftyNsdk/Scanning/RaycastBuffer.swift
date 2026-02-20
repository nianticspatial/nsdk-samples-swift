import CArdk

/// A read-only container for the raycast buffer information generated during scanning.
public class RaycastBuffer {
    /// The RGBA image of the raycast buffer.
    public var rgba: RawImage
    /// The normals image of the raycast buffer.
    public var normals: RawImage
    /// The position and confidence image of the raycast buffer.
    public var positionAndConfidence: RawImage

    private var resourceOwner: ResourceOwner?

    init(fromC cBuffer: ARDK_Scanning_RaycastBuffer, owner: ResourceOwner? = nil) {
        resourceOwner = owner

        rgba = RawImage(
            ptr: cBuffer.rgba_image.data,
            width: UInt(cBuffer.rgba_image.width),
            height: UInt(cBuffer.rgba_image.height),
            type: .RGBX
        )

        normals = RawImage(
            ptr: cBuffer.normal_image.data,
            width: UInt(cBuffer.normal_image.width),
            height: UInt(cBuffer.normal_image.height),
            type: .raycastNormals
        )

        positionAndConfidence = RawImage(
            ptr: cBuffer.position_and_confidence_image.data,
            width: UInt(cBuffer.position_and_confidence_image.width),
            height: UInt(cBuffer.position_and_confidence_image.height),
            type: .raycastPositionAndConfidence
        )
    }
}
