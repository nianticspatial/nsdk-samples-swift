//
//  CaptureManager.swift
//

import Foundation
import SwiftyNsdk
import Metal

class CaptureManager : NsdkFeatureManager<NsdkScanningSession> {
    var recordingExporter: NsdkRecordingExporter

    // Store scan information from successful save operations
    private var savedScanId: String?
    private var savedScanPath: String?

    // Metal resources for texture visualization
    private var device: MTLDevice?

    // Raycast visualization textures (raw inputs)
    private(set) var rgbaTexture: MTLTexture?
    private(set) var normalsTexture: MTLTexture?
    private(set) var positionAndConfidenceTexture: MTLTexture?

    // Cached texture dimensions to avoid unnecessary recreation
    private var cachedRgbaWidth: Int = 0
    private var cachedRgbaHeight: Int = 0
    private var cachedNormalsWidth: Int = 0
    private var cachedNormalsHeight: Int = 0
    private var cachedPositionWidth: Int = 0
    private var cachedPositionHeight: Int = 0

    private let enableRaycastVisualization: Bool
    private let enableVoxelVisualization: Bool

    init(nsdk: NsdkSession,
         enableRaycastVisualization: Bool,
         enableVoxelVisualization: Bool) {
        self.enableRaycastVisualization = enableRaycastVisualization
        self.enableVoxelVisualization = enableVoxelVisualization
        recordingExporter = nsdk.createRecordingExporter()
        super.init(session: nsdk.createScanningSession())

        // Create Metal device only if raycast visualization is enabled
        if enableRaycastVisualization {
            device = MTLCreateSystemDefaultDevice()
            if device == nil {
                print("Warning: Failed to create Metal device for raycast visualization")
            }
        }
    }

    override func configuration() -> NsdkScanningSession.Configuration {
        var config = NsdkScanningSession.Configuration()
        config.enableRaycastVisualization = enableRaycastVisualization
        config.enableVoxelVisualization = enableVoxelVisualization
        config.generateDepthsIfLidarUnavailable = true
        return config
    }

    override func start() {
        // Clear any previous scan data when starting a new scan
        savedScanId = nil
        savedScanPath = nil

        super.start()
    }

    func save(withTimeoutSeconds: Double) async -> Bool? {
        print("Saving scan...")
        do {
            let saveInfo = try await session.saveCurrentScan(
                timeout: withTimeoutSeconds,
                pollingInterval: 0.01
            )
            // Store scan information for later use in archiveRecentSave()
            savedScanId = saveInfo.scanId
            savedScanPath = saveInfo.path
            print("Saved scan to \(saveInfo.path) with ID: \(saveInfo.scanId)")
            return true
        } catch is TimeoutError {
            print("Error: save timed out")
            return nil
        } catch {
            print("Scan save failed with error: \(error)")
            return nil
        }
    }

    func archiveRecentSave(withTimeoutSeconds: Double = 50.0, progressCallback: ((Float) -> Void)? = nil) async -> (success: Bool, archivePath: String?) {
        // Ensure save() was called successfully first
        guard let scanId = savedScanId, let scanPath = savedScanPath else {
            print("Error: No scan has been saved. Call save() first before attempting to archive.")
            return (false, nil)
        }

        print("Archiving scan with ID: \(scanId)")

        // Capture values needed for the detached task
        let exporter = recordingExporter
        
        return await Task.detached(priority: .userInitiated) {
            do {
                var lastProgress: Float = 0.0
                let path = try await exporter.export(
                    scanDirPath: scanPath,
                    scanId: scanId,
                    pollingInterval: TimeInterval(0.1),
                    timeout: withTimeoutSeconds,
                    progressCallback: { currentProgress in
                        // Only report progress updates when there's a meaningful change
                        if abs(currentProgress - lastProgress) > 0.01 {
                            lastProgress = currentProgress
                            // Dispatch progress callback asynchronously to avoid blocking
                            if let callback = progressCallback {
                                Task { @MainActor in
                                    callback(currentProgress)
                                }
                            }
                        }
                    }
                )
            
                print("Export completed: \(path)")
                return (true, path)
            } catch {
                print("Error: Failed to get exported path: \(error)")
                return (false, nil)
            }
        }.value
    }

    func computeVoxels() {
        session.computeVoxels()
    }

    func checkVisualizations() -> Bool {
        guard let raycastBuffer = session.raycastBuffer() else { return false }
        print("Raycast visualization buffer (H: \(raycastBuffer.rgba.height), W: \(raycastBuffer.rgba.width))")

        guard let voxelBuffer = session.voxelBuffer() else { return false }
        print("Voxel buffer (positions: \(voxelBuffer.positions.count)")

        return true
    }

    /// Updates all raycast textures from the current capture session.
    /// - Returns: `true` if textures were successfully updated, `false` otherwise
    func updateRaycastTextures() -> Bool {
        guard let device = device else {
            print("Cannot update raycast textures: Metal device not available")
            return false
        }

        guard let raycastBuffer = session.raycastBuffer() else {
            return false
        }

        rgbaTexture = createOrUpdateTexture(
            from: raycastBuffer.rgba,
            existing: rgbaTexture,
            cachedWidth: &cachedRgbaWidth,
            cachedHeight: &cachedRgbaHeight,
            pixelFormat: .rgba8Unorm,
            device: device
        )

        normalsTexture = createOrUpdateTexture(
            from: raycastBuffer.normals,
            existing: normalsTexture,
            cachedWidth: &cachedNormalsWidth,
            cachedHeight: &cachedNormalsHeight,
            pixelFormat: .rgba8Unorm,
            device: device
        )

        positionAndConfidenceTexture = createOrUpdateTexture(
            from: raycastBuffer.positionAndConfidence,
            existing: positionAndConfidenceTexture,
            cachedWidth: &cachedPositionWidth,
            cachedHeight: &cachedPositionHeight,
            pixelFormat: .rgba16Float,
            device: device
        )

        return rgbaTexture != nil && normalsTexture != nil && positionAndConfidenceTexture != nil
    }

    /// Creates or updates a Metal texture from a RawImage.
    /// - Parameters:
    ///   - image: The source RawImage
    ///   - existing: The existing texture to reuse if dimensions match
    ///   - cachedWidth: Cached width of the existing texture
    ///   - cachedHeight: Cached height of the existing texture
    ///   - pixelFormat: The Metal pixel format to use
    ///   - device: The Metal device to use for texture creation
    /// - Returns: The updated texture, or `nil` if creation/upload fails
    private func createOrUpdateTexture(
        from image: RawImage,
        existing: MTLTexture?,
        cachedWidth: inout Int,
        cachedHeight: inout Int,
        pixelFormat: MTLPixelFormat,
        device: MTLDevice
    ) -> MTLTexture? {
        let width = Int(image.width)
        let height = Int(image.height)

        // Only recreate texture if size changed or doesn't exist
        var texture = existing
        if texture == nil || cachedWidth != width || cachedHeight != height {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            textureDescriptor.usage = [.shaderRead]
            textureDescriptor.storageMode = .shared

            guard let newTexture = device.makeTexture(descriptor: textureDescriptor) else {
                print("Failed to create Metal texture")
                return nil
            }

            texture = newTexture
            cachedWidth = width
            cachedHeight = height
        }

        guard let validTexture = texture else {
            print("No texture available")
            return nil
        }

        // Calculate bytes per row based on pixel format
        let bytesPerRow: Int
        switch pixelFormat {
        case .rgba8Unorm:
            bytesPerRow = width * 4  // 4 bytes per pixel (RGBA8)
        case .rgba16Float:
            bytesPerRow = width * 8  // 8 bytes per pixel (RGBA Half)
        default:
            print("Unsupported pixel format")
            return nil
        }

        // Upload data to GPU
        let region = MTLRegionMake2D(0, 0, width, height)
        validTexture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: image.data,
            bytesPerRow: bytesPerRow
        )

        return validTexture
    }
}
