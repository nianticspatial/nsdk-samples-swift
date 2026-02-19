import Foundation
import ARKit
import CoreGraphics
import CoreImage
import CoreVideo

// MARK: - FrameMetadata to NsdkFrameData Conversion

extension PlaybackDataset.FrameMetadata {
    
    /// Converts the tracking state integer to ARCamera.TrackingState.
    ///
    /// Mapping: 0 = notAvailable, 1 = normal, 2+ = limited
    public var trackingState: ARCamera.TrackingState {
        switch tracking {
        case 0:
            return .notAvailable
        case 1:
            return .normal
        default:
            return .limited(.insufficientFeatures)
        }
    }
    
    /// Converts the pose4x4 array (16 elements) to simd_float4x4.
    public var cameraTransform: simd_float4x4 {
        guard pose4x4.count == 16 else {
            return simd_float4x4(0)
        }
        
        return simd_float4x4(
            SIMD4<Float>(Float(pose4x4[0]), Float(pose4x4[1]), Float(pose4x4[2]), Float(pose4x4[3])),
            SIMD4<Float>(Float(pose4x4[4]), Float(pose4x4[5]), Float(pose4x4[6]), Float(pose4x4[7])),
            SIMD4<Float>(Float(pose4x4[8]), Float(pose4x4[9]), Float(pose4x4[10]), Float(pose4x4[11])),
            SIMD4<Float>(Float(pose4x4[12]), Float(pose4x4[13]), Float(pose4x4[14]), Float(pose4x4[15]))
        )
    }
    
    /// Converts the intrinsics array (5 elements: fx, fy, cx, cy, k1) to simd_float3x3.
    public var cameraIntrinsics: simd_float3x3 {
        guard intrinsics.count >= 5 else {
            return simd_float3x3(0)
        }
        
        let fx = Float(intrinsics[0])
        let fy = Float(intrinsics[1])
        let cx = Float(intrinsics[2])
        let cy = Float(intrinsics[3])
        // k1 is distortion parameter, not used in the 3x3 matrix
        
        return simd_float3x3(
            SIMD3<Float>(fx, 0, 0),
            SIMD3<Float>(0, fy, 0),
            SIMD3<Float>(cx, cy, 1)
        )
    }
    
    /// Converts the screen orientation string to UIInterfaceOrientation.
    ///
    /// Returns nil if no screen orientation is available in the metadata.
    public var orientation: UIInterfaceOrientation? {
        guard let orientationString = screenOrientation else {
            return nil
        }
        
        switch orientationString.lowercased() {
        case "portrait":
            return .portrait
        case "portraitupsidedown":
            return .portraitUpsideDown
        case "landscapeleft":
            return .landscapeLeft
        case "landscaperight":
            return .landscapeRight
        default:
            return .unknown
        }
    }
    
    /// Creates CompassData from the frame's location metadata.
    public var compassData: NsdkFrameData.CompassData {
        NsdkFrameData.CompassData(
            timestampMs: UInt64(location.headingTimestamp * 1000),
            headingAccuracy: Float(location.headingAccuracy),
            trueHeading: Float(location.heading)
        )
    }
    
    /// Creates GpsData from the frame's location metadata.
    public var gpsData: NsdkFrameData.GpsData {
        NsdkFrameData.GpsData(
            timestampMs: UInt64(location.positionTimestamp * 1000),
            latitude: location.latitude,
            longitude: location.longitude,
            altitude: location.altitude,
            verticalAccuracy: Float(location.altitudeAccuracy),
            horizontalAccuracy: Float(location.positionAccuracy)
        )
    }
    
    /// Camera timestamp in milliseconds.
    public var cameraTimestampMs: UInt64 {
        UInt64(timestamp * 1000)
    }
    
    /// Camera image width from resolution.
    public var cameraImageWidth: UInt32 {
        UInt32(resolution[0])
    }
    
    /// Camera image height from resolution.
    public var cameraImageHeight: UInt32 {
        UInt32(resolution[1])
    }
    
    /// Creates CameraIntrinsics from the frame metadata.
    public var nsdkCameraIntrinsics: NsdkFrameData.CameraIntrinsics {
        NsdkFrameData.CameraIntrinsics(
            intrinsics: cameraIntrinsics,
            width: cameraImageWidth,
            height: cameraImageHeight
        )
    }
}

// MARK: - CGImage Extension for CVPixelBuffer Conversion

extension CGImage {
    
    /// Converts the CGImage to a CVPixelBuffer in YUV420NV12 format.
    ///
    /// - Parameters:
    ///   - width: Target width for the pixel buffer
    ///   - height: Target height for the pixel buffer
    /// - Returns: A CVPixelBuffer in YUV420NV12 format, or nil if conversion fails
    public func toYUV420PixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: kCFBooleanTrue!,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, // YUV420NV12 format
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            print("Failed to create CVPixelBuffer: \(status)")
            return nil
        }
        
        let ciContext = CIContext()
        let ciImage = CIImage(cgImage: self)
        ciContext.render(ciImage, to: buffer)
        
        return buffer
    }
}

// MARK: - CVPixelBuffer Extension for Plane Extraction

extension CVPixelBuffer {
    
    /// Extracts the Y (luminance) plane from a YUV pixel buffer.
    ///
    /// The pixel buffer must be locked before calling this method.
    ///
    /// - Returns: The Y plane as a CameraPlane struct
    public func extractYPlane() -> NsdkFrameData.CameraPlane {
        let ptr = CVPixelBufferGetBaseAddressOfPlane(self, 0)
        let width = CVPixelBufferGetWidthOfPlane(self, 0)
        let height = CVPixelBufferGetHeightOfPlane(self, 0)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(self, 0)
        let pixelStride = rowStride / width
        
        return NsdkFrameData.CameraPlane(
            dataPtr: UnsafePointer<UInt8>(ptr!.assumingMemoryBound(to: UInt8.self)),
            dataSize: UInt32(width * height * pixelStride),
            pixelStride: UInt32(pixelStride),
            rowStride: UInt32(rowStride)
        )
    }
    
    /// Extracts the CbCr (chrominance) plane from a YUV pixel buffer.
    ///
    /// The pixel buffer must be locked before calling this method.
    ///
    /// - Returns: The CbCr plane as a CameraPlane struct
    public func extractCbCrPlane() -> NsdkFrameData.CameraPlane {
        let ptr = CVPixelBufferGetBaseAddressOfPlane(self, 1)
        let width = CVPixelBufferGetWidthOfPlane(self, 1)
        let height = CVPixelBufferGetHeightOfPlane(self, 1)
        let rowStride = CVPixelBufferGetBytesPerRowOfPlane(self, 1)
        let pixelStride = rowStride / width
        
        return NsdkFrameData.CameraPlane(
            dataPtr: UnsafePointer<UInt8>(ptr!.assumingMemoryBound(to: UInt8.self)),
            dataSize: UInt32(width * height * pixelStride),
            pixelStride: UInt32(pixelStride),
            rowStride: UInt32(rowStride)
        )
    }
}

