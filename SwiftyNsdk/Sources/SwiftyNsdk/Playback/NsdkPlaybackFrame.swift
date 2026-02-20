import Foundation
import CoreGraphics
import CoreVideo

/// A frame of data from a playback session, bundling together frame metadata and associated buffers.
public struct NsdkPlaybackFrame: @unchecked Sendable{
    /// The metadata for this frame (pose, intrinsics, timestamps, etc.)
    public let metadata: PlaybackDataset.FrameMetadata
    
    /// The camera image for this frame, or nil if unavailable
    public let image: CGImage?
    
    /// The depth data buffer (Float32 format) for this frame, or nil if unavailable
    public let depthData: CVPixelBuffer?
    
    /// The depth confidence buffer (UInt8 format) for this frame, or nil if unavailable
    public let depthConfidence: CVPixelBuffer?
    
    public init(
        metadata: PlaybackDataset.FrameMetadata,
        image: CGImage?,
        depthData: CVPixelBuffer? = nil,
        depthConfidence: CVPixelBuffer? = nil
    ) {
        self.metadata = metadata
        self.image = image
        self.depthData = depthData
        self.depthConfidence = depthConfidence
    }
}

