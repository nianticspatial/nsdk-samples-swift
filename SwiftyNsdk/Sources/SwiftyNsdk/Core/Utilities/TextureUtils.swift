//
//  TextureUtils.swift
//
//  Provides safe creation and updating of Metal textures from RawImage buffers.
//

import Metal
import MetalKit
import SwiftyNsdk
import CArdk

public struct TextureUtils {

    // MARK: - Public API

    /// Creates or updates a Metal texture using a `RawImage`.
    ///
    /// - Parameters:
    ///   - image: The image buffer on cpu memory.
    ///   - texture: An existing Metal texture to update, or `nil` to create a new one.
    ///   - device: The Metal device used to allocate textures.
    /// - Returns: `true` if the texture was allocated or updated this call.
    @discardableResult
    public static func createOrUpdateTexture(
        from image: RawImage?,
        texture: inout MTLTexture?,
        device: MTLDevice
    ) -> Bool {
        guard let image = image else { return false }
        guard let pixelFormat = pixelFormatIfSupported(for: image.type) else {
            return false
        }

        let width  = Int(image.width)
        let height = Int(image.height)
        
        ensureTextureAllocated(
            &texture,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            device: device
        )

        guard let texture else { return false }
        
        let pixelCount  = width * height
        let bytesPerRow = width * MemoryLayout<Float>.stride
        let pointer     = image.data.bindMemory(to: Float.self, capacity: pixelCount)

        let region = MTLRegionMake2D(0, 0, width, height)

        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pointer,
            bytesPerRow: bytesPerRow
        )
        
        return true
    }
    
    // MARK: - Image Type Conversion

    /// Maps NSDK `ImageType` to Metal `MTLPixelFormat`.
    ///
    /// - Parameter imageType: The NSDK image type.
    /// - Returns: A matching Metal pixel format.
    private static func pixelFormatIfSupported(for type: ImageType) -> MTLPixelFormat? {
        switch type {
        case .depthRawFloat, .semanticsConfidence:
            return .r32Float
        default:
            return nil
        }
    }

    // MARK: - Allocation Helpers

    /// Ensures that the texture exists, has the correct dimensions, and uses the specified pixel format.
    ///
    /// - Parameters:
    ///   - texture: The texture to allocate or update.
    ///   - width: Required texture width.
    ///   - height: Required texture height.
    ///   - pixelFormat: Desired Metal pixel format.
    ///   - device: Metal device used for allocation.
    private static func ensureTextureAllocated(
        _ texture: inout MTLTexture?,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        device: MTLDevice
    ) {
        let needsRealloc =
            texture == nil ||
            texture!.width  != width ||
            texture!.height != height ||
            texture!.pixelFormat != pixelFormat

        guard needsRealloc else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )

        descriptor.usage       = [.shaderRead]
        descriptor.storageMode = .shared

        texture = device.makeTexture(descriptor: descriptor)

        if texture == nil {
            print("❌ [TextureUtils] Failed to allocate texture (\(width)x\(height), format: \(pixelFormat)).")
        }
    }
}
