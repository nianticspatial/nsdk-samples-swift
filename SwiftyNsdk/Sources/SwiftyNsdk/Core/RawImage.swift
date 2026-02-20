import CArdk

/// A raw image containing pixel data for NSDK operations.
///
/// `RawImage` provides access to image data in various formats (RGB, grayscale,
/// depth, etc.) used by NSDK features like depth processing, semantic segmentation,
/// and image analysis.
///
/// ## Overview
///
/// Raw images are used throughout NSDK for:
/// - Camera frame processing
/// - Depth map representation
/// - Semantic segmentation results
/// - Image format conversions
/// - Computer vision operations
///
/// ## Example Usage
///
/// ```swift
/// let (status, depthResult) = depthSession.getDepth()
/// if status.isOk() {
///     let image = depthResult.image
///     print("Image size: \(image.width) x \(image.height)")
///     print("Image type: \(image.type)")
///     
///     // Access pixel data
///     let pixelData = image.data
///     // Process pixel data based on image type
/// }
/// ```
///
/// ## Memory Management
///
/// This object's pointers are only valid when the NSDK objects that holds it are still in scope.
public struct RawImage {
    /// Width of the image in pixels.
    ///
    /// This represents the number of pixels in each row of the image.
    public let width: UInt
    
    /// Height of the image in pixels.
    ///
    /// This represents the number of rows in the image.
    public let height: UInt
    
    /// Pointer to the raw pixel data.
    ///
    /// This provides direct access to the image's pixel data. The format and
    /// interpretation of the data depends on the `type` property.
    public let data: UnsafeMutableRawPointer
    
    /// Format and type of the image data.
    ///
    /// This indicates how the pixel data should be interpreted, including
    /// the number of channels, data type, and color space.
    public let type: ImageType
    
    public init(ptr: UnsafeMutableRawPointer, width: UInt, height: UInt, type: ImageType) {
        self.data = ptr
        self.width = width
        self.height = height
        self.type = type
    }
    
    init(fromC cImage: ARDK_Image) {
        self.init(
            ptr: cImage.data,
            width: UInt(cImage.width),
            height: UInt(cImage.height),
            type: ImageType(fromC: cImage.type)
        )
    }
    
    init(fromC cImage: ARDK_FloatImage) {
        self.init(
            ptr: cImage.data,
            width: UInt(cImage.width),
            height: UInt(cImage.height),
            type: ImageType(fromC: cImage.type)
        )
    }
    
    init(fromC cImage: ARDK_IntImage) {
        self.init(
            ptr: cImage.data,
            width: UInt(cImage.width),
            height: UInt(cImage.height),
            type: ImageType(fromC: cImage.type)
        )
    }
}
