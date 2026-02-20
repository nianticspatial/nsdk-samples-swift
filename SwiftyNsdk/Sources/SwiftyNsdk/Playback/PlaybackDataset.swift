import Foundation
import UIKit
import CoreGraphics
import CoreVideo

/// A dataset loaded from a capture JSON file containing frame metadata.
/// 
/// This class uses on-demand loading for frame images and depth data.
/// Only the currently requested frame is loaded into memory, reducing memory pressure
/// for large datasets.
public class PlaybackDataset {
    private let frameMetadata: [FrameMetadata]
    internal let frameInterval: TimeInterval
    internal let frameCount: Int
    private let depthSource: String?
    
    /// Reference to the loader for on-demand frame loading
    private let loader: PlaybackDatasetSource
    
    /// Cache for the most recently loaded frame (1-frame cache like Unity)
    private var cachedFrameIndex: Int = -1
    private var cachedImage: CGImage?
    private var cachedDepthBuffer: CVPixelBuffer?
    private var cachedConfidenceBuffer: CVPixelBuffer?
    
    /// Metadata structure for capture information
    public struct CaptureMetadata: Codable {
        public let appId: String
        public let appVersion: String
        public let captureName: String
        public let generatedBy: String
        public let unityVersion: String
    }
    
    /// Root structure for the capture JSON file
    public struct CaptureRoot: Codable {
        public let app: String
        public let autofocus: Int
        public let coordinates: String
        public let duration: Double
        public let formatVersion: String
        public let frameCount: Int
        public let framerate: Double
        public let frames: [FrameMetadata]
        public let imageFormat: String
        public let imageQuality: Int
        public let manufacturer: String
        public let metadata: CaptureMetadata?
        public let model: String
        public let recorder: String
        public let resolution: [Int]  // 2 elements: width, height
        public let timestamp: Double
        public let timezone: Int
        public let uuid: String
        public let depthFormat: String?  // Optional depth format (e.g., "floatbinary")
        public let depthSource: String?  // Optional depth source (e.g., "lidar")
    }
    
    /// Location metadata structure
    public struct LocationMetadata: Codable {
        public let altitude: Double
        public let altitudeAccuracy: Double
        public let heading: Double
        public let headingAccuracy: Double
        public let headingTimestamp: Double
        public let latitude: Double
        public let longitude: Double
        public let positionAccuracy: Double
        public let positionTimestamp: Double
    }
    
    /// Frame metadata structure matching the JSON format
    public struct FrameMetadata: Codable {
        public let image: String
        public let intrinsics: [Double]  // 5 elements: fx, fy, cx, cy, k1
        public let location: LocationMetadata
        public let screenOrientation: String?  // Optional as some frames may not have this
        public let pose: [Double]  // 7 elements: x, y, z, qx, qy, qz, qw
        public let pose4x4: [Double]  // 16 elements: 4x4 transformation matrix
        public let projection: [Double]?  // 16 elements: 4x4 projection matrix (optional as some datasets may not have this)
        public let resolution: [Int]  // 2 elements: width, height
        public let saveDuration: Double?
        public let sequence: Int
        public let timestamp: Double
        public let tracking: Int
        public let trackingReason: Int
        public let depth: String?  // Optional depth image filename
        public let depthConfidence: String?  // Optional depth confidence image filename
        public let depthResolution: [Int]?  // Optional depth resolution [width, height] for this frame
        public let depthTimestamp: Double?  // Optional depth timestamp
    }
    
    /// Initializes a dataset using the specified capture root and loader for on-demand frame loading.
    /// 
    /// - Parameters:
    ///   - captureRoot: The capture root containing frame metadata
    ///   - loader: The loader to use for on-demand frame loading
    internal init(captureRoot: CaptureRoot, loader: PlaybackDatasetSource) {
        self.frameMetadata = captureRoot.frames
        self.frameCount = captureRoot.frameCount
        // Calculate frame interval from framerate (frameInterval = 1.0 / framerate)
        // Fallback to 30fps if framerate is invalid (0 or negative)
        self.frameInterval = captureRoot.framerate > 0 ? 1.0 / captureRoot.framerate : 1.0 / 30.0
        self.depthSource = captureRoot.depthSource
        self.loader = loader
    }
    
    /// Retrieves frame metadata at the specified index.
    /// 
    /// - Parameter index: Zero-based frame index
    /// - Returns: The frame metadata
    /// - Throws: `PlaybackDatasetError.indexOutOfBounds` if the index is invalid
    internal func getFrameDataAtIndex(index: Int) throws -> FrameMetadata {
        guard index >= 0 && index < frameMetadata.count else {
            throw PlaybackDatasetError.indexOutOfBounds(index: index, count: frameCount)
        }
        return frameMetadata[index]
    }
    
    /// Retrieves frame image at the specified index using on-demand loading.
    /// 
    /// The image is loaded from disk when requested and cached. If the same frame
    /// is requested again, the cached image is returned.
    /// 
    /// - Parameter index: Zero-based frame index
    /// - Returns: The frame image as a CGImage
    /// - Throws: `PlaybackDatasetError.indexOutOfBounds` if the index is invalid,
    ///           `PlaybackDatasetError.imageLoadFailed` if the image cannot be loaded
    internal func getFrameImageAtIndex(index: Int) throws -> CGImage {
        guard index >= 0 && index < frameCount else {
            throw PlaybackDatasetError.indexOutOfBounds(index: index, count: frameCount)
        }
        
        // Return cached image if same frame is requested
        if index == cachedFrameIndex, let cached = cachedImage {
            return cached
        }
        
        // Load on-demand
        let metadata = frameMetadata[index]
        guard let image = loader.loadImage(imageName: metadata.image) else {
            throw PlaybackDatasetError.imageLoadFailed(imageName: metadata.image)
        }
        
        // Update cache
        updateCache(forIndex: index, image: image, depthBuffer: nil, confidenceBuffer: nil)
        
        return image
    }
    
    /// Retrieves depth pixel buffer at the specified index using on-demand loading.
    /// 
    /// The depth data is loaded from disk when requested and cached.
    /// 
    /// - Parameter index: Zero-based frame index
    /// - Returns: The depth data as a `CVPixelBuffer` (Float32 format), or `nil` if depth data is not available for this frame
    /// - Throws: `PlaybackDatasetError.indexOutOfBounds` if the index is invalid
    internal func getDepthDataAtIndex(index: Int) throws -> CVPixelBuffer? {
        guard index >= 0 && index < frameCount else {
            throw PlaybackDatasetError.indexOutOfBounds(index: index, count: frameCount)
        }
        
        // Return cached depth if same frame is requested
        if index == cachedFrameIndex, let cached = cachedDepthBuffer {
            return cached
        }
        
        let metadata = frameMetadata[index]
        
        // Check if this frame has depth data
        guard let depthFileName = metadata.depth,
              let depthResolution = metadata.depthResolution else {
            return nil
        }
        
        // Load depth data on-demand
        guard let depthData = loader.loadDepthData(depthFileName: depthFileName) else {
            return nil
        }
        
        // Convert to CVPixelBuffer
        guard let depthBuffer = createDepthPixelBuffer(from: depthData, width: depthResolution[0], height: depthResolution[1]) else {
            return nil
        }
        
        // Update cache
        cachedDepthBuffer = depthBuffer
        
        return depthBuffer
    }
    
    /// Retrieves depth confidence pixel buffer at the specified index using on-demand loading.
    /// 
    /// The confidence data is loaded from disk when requested and cached.
    /// 
    /// - Parameter index: Zero-based frame index
    /// - Returns: The depth confidence data as a `CVPixelBuffer` (UInt8 format), or `nil` if confidence data is not available for this frame
    /// - Throws: `PlaybackDatasetError.indexOutOfBounds` if the index is invalid
    internal func getDepthConfidenceAtIndex(index: Int) throws -> CVPixelBuffer? {
        guard index >= 0 && index < frameCount else {
            throw PlaybackDatasetError.indexOutOfBounds(index: index, count: frameCount)
        }
        
        // Return cached confidence if same frame is requested
        if index == cachedFrameIndex, let cached = cachedConfidenceBuffer {
            return cached
        }
        
        let metadata = frameMetadata[index]
        
        // Check if this frame has confidence data
        guard let confidenceFileName = metadata.depthConfidence,
              let depthResolution = metadata.depthResolution else {
            return nil
        }
        
        // Load confidence data on-demand
        guard let confidenceData = loader.loadDepthConfidence(confidenceFileName: confidenceFileName) else {
            return nil
        }
        
        // Convert to CVPixelBuffer
        guard let confidenceBuffer = createConfidencePixelBuffer(from: confidenceData, width: depthResolution[0], height: depthResolution[1]) else {
            return nil
        }
        
        // Update cache
        cachedConfidenceBuffer = confidenceBuffer
        
        return confidenceBuffer
    }
    
    /// Updates the frame cache with new data.
    /// 
    /// - Parameters:
    ///   - index: The frame index being cached
    ///   - image: The image to cache (optional)
    ///   - depthBuffer: The depth buffer to cache (optional)
    ///   - confidenceBuffer: The confidence buffer to cache (optional)
    private func updateCache(forIndex index: Int, image: CGImage?, depthBuffer: CVPixelBuffer?, confidenceBuffer: CVPixelBuffer?) {
        // If switching to a new frame, clear the old cache
        if index != cachedFrameIndex {
            cachedFrameIndex = index
            cachedImage = nil
            cachedDepthBuffer = nil
            cachedConfidenceBuffer = nil
        }
        
        // Update with new values if provided
        if let image = image {
            cachedImage = image
        }
        if let depthBuffer = depthBuffer {
            cachedDepthBuffer = depthBuffer
        }
        if let confidenceBuffer = confidenceBuffer {
            cachedConfidenceBuffer = confidenceBuffer
        }
    }
    
    /// Checks if the dataset has depth data from a LiDAR source.
    /// 
    /// - Returns: `true` if `depthSource` exists and equals "lidar", `false` otherwise
    public func hasDepth() -> Bool {
        return depthSource?.lowercased() == "lidar"
    }
    
    // MARK: - Pixel Buffer Creation
    
    /// Creates a CVPixelBuffer containing Float32 depth data from raw binary data.
    /// 
    /// - Parameters:
    ///   - data: Raw binary data containing Float32 depth values
    ///   - width: Width of the depth image
    ///   - height: Height of the depth image
    /// - Returns: A CVPixelBuffer in kCVPixelFormatType_DepthFloat32 format, or nil if creation fails
    private func createDepthPixelBuffer(from data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        let expectedSize = width * height * MemoryLayout<Float32>.size
        guard data.count >= expectedSize else {
            print("PlaybackDataset: Depth data size mismatch. Expected \(expectedSize), got \(data.count)")
            return nil
        }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            nil,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("PlaybackDataset: Failed to create depth CVPixelBuffer, status: \(status)")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            print("PlaybackDataset: Failed to get base address of depth CVPixelBuffer")
            return nil
        }
        
        data.withUnsafeBytes { rawBufferPointer in
            memcpy(baseAddress, rawBufferPointer.baseAddress!, expectedSize)
        }
        
        return buffer
    }
    
    /// Creates a CVPixelBuffer containing UInt8 confidence data from raw binary data.
    /// 
    /// - Parameters:
    ///   - data: Raw binary data containing UInt8 confidence values
    ///   - width: Width of the confidence image
    ///   - height: Height of the confidence image
    /// - Returns: A CVPixelBuffer in kCVPixelFormatType_OneComponent8 format, or nil if creation fails
    private func createConfidencePixelBuffer(from data: Data, width: Int, height: Int) -> CVPixelBuffer? {
        let expectedSize = width * height * MemoryLayout<UInt8>.size
        guard data.count >= expectedSize else {
            print("PlaybackDataset: Confidence data size mismatch. Expected \(expectedSize), got \(data.count)")
            return nil
        }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("PlaybackDataset: Failed to create confidence CVPixelBuffer, status: \(status)")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            print("PlaybackDataset: Failed to get base address of confidence CVPixelBuffer")
            return nil
        }
        
        data.withUnsafeBytes { rawBufferPointer in
            memcpy(baseAddress, rawBufferPointer.baseAddress!, expectedSize)
        }
        
        return buffer
    }
    
    /// Errors that can occur when retrieving frame data
    public enum PlaybackDatasetError: Error {
        case indexOutOfBounds(index: Int, count: Int)
        case imageLoadFailed(imageName: String)
    }
}
