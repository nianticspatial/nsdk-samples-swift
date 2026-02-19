import CArdk
import Foundation

extension NsdkSession {
    /// Creates a new Meshing session.
    ///
    /// - Returns: A new Meshing session attached to this NSDK session
    public func createMeshingSession() -> NsdkMeshingSession {
        let key = ObjectIdentifier(NsdkMeshingSession.self)
        if let existing = disposables[key] as? NsdkMeshingSession {
            return existing
        }
        let session = NsdkMeshingSession(nsdkHandle: nativeHandle, meshingApi: CMeshingApi())
        disposables[key] = session
        return session
    }
}

/// A session for real-time 3D mesh generation from AR camera frames.
///
/// The meshing feature provides capabilities for processing AR session data and generating
/// a triangle mesh representation of the physical environment in real-time. The mesh is
/// divided into chunks that can be individually queried and updated as the environment
/// is scanned.
public final class NsdkMeshingSession: NsdkSession.IDisposable, NsdkFeatureSession {
    internal let nsdkHandle: NsdkHandle
    private let meshingApi: MeshingApi
    private var destroyed: Bool = false

    // The meshing session must be constructed on the same thread that the NSDK object was created on.
    init(nsdkHandle: NsdkHandle, meshingApi: MeshingApi) {
        self.nsdkHandle = nsdkHandle
        self.meshingApi = meshingApi
        let cStatus = meshingApi.create(nsdkHandle: nsdkHandle)

        if cStatus.isError { fatalError("Unexpected non-ok ARDK_Status: \(cStatus)") }
    }

    /// Reports errors that have occurred within processes running inside this feature.
    ///
    /// Check this periodically to see if any errors have occurred with processes running
    /// inside this feature. Once an error has been flagged, it will remain flagged until the
    /// culprit process has been run again and completed successfully.
    ///
    /// - Returns: Feature status flags for any issues that have occurred
    public func featureStatus() -> NsdkFeatureStatus {
        let flags = meshingApi.getFeatureStatus(nsdkHandle: nsdkHandle)
        return NsdkFeatureStatus(rawValue: flags.rawValue)
    }

    /// Configures the meshing feature with the specified settings.
    ///
    /// - Attention: If this method is called while meshing is running, the meshing feature will
    ///   restart with the new configuration, and any mesh data that has been produced will
    ///   be lost.
    ///
    /// - Parameter config: An object that defines the meshing behavior.
    /// - Throws: ``NsdkError.invalidArgument`` if the configuration is invalid.
    ///   Check NSDK's C logs for more information.
    public func configure(with config: Configuration) throws {
        // Need this because underlying C field is a UInt32
        if config.frameRate < 0 {
            print("MeshingConfiguration.framerate value must be non-negative.")
            throw NsdkError.invalidArgument
        }

        let cStruct = config.convertToC()
        let cStatus = withUnsafePointer(to: cStruct) { ptr in
            meshingApi.configure(nsdkHandle: nsdkHandle, config: ptr)
        }

        if cStatus.isError {
            throw NsdkError(fromC: cStatus)
        }
    }

    /// Starts the meshing feature.
    ///
    /// The feature will begin processing AR frame data and building a mesh according to the
    /// currently applied configuration.
    public func start() {
        let cStatus = meshingApi.start(nsdkHandle: nsdkHandle)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }

    /// Stops the meshing feature.
    ///
    /// - Note: This will clear previously generated mesh data.
    public func stop() {
        let cStatus = meshingApi.stop(nsdkHandle: nsdkHandle)
        if cStatus.isError { fatalError("Unexpected non-ok ARDK_Status: \(cStatus)") }
    }

    internal func destroy() {
        if destroyed {
            return
        }
        destroyed = true

        let cStatus = meshingApi.destroy(nsdkHandle: nsdkHandle)
        if cStatus.isError { fatalError("Unexpected non-ok ARDK_Status: \(cStatus)") }
    }

    /// Gets the ids of all chunks in the current mesh and their update status.
    ///
    /// The returned information contains the ids and update status for all chunks currently
    /// in the mesh. If a chunk's updated flag is true, the mesh chunk has been updated since
    /// the last time its data was read with ``meshDataById(id:)``.
    ///
    /// To retrieve the data for a specific chunk, call ``meshDataById(id:)``.
    ///
    /// - Returns: A buffer containing updated mesh chunk ids, nil if there are no chunks.
    public func updatedMeshInfos() -> MeshUpdateInfo? {
        var cInfo = ARDK_Meshing_UpdateInfo()

        let cStatus = meshingApi.getUpdatedMeshInfos(nsdkHandle: nsdkHandle, infoOut: &cInfo)
        if cStatus.isError { unexpectedNsdkStatus(cStatus) }

        if cInfo.numIds == 0 {
            return nil
        }

        let owner = meshingApi.createResourceOwner(handle: cInfo.handle!)
        let meshInfos = MeshUpdateInfo(fromC: cInfo, owner: owner)
        return meshInfos
    }

    /// Retrieves the mesh data for a specified chunk.
    ///
    /// - Note: This method resets the updated flag for the specified chunk. Subsequent calls to
    /// ``updatedMeshInfos()`` will only mark the chunk as updated if its mesh data has
    /// changed since the mesh chunk's data was last retrieved.
    ///
    /// - Parameter id: The ID of the mesh chunk to retrieve, obtained from ``updatedMeshInfos()``.
    /// - Returns: The mesh data for the specified chunk, or `nil` if no chunk with the given ID exists.
    public func meshDataById(id: Int64) -> MeshData? {
        var cChunk = ARDK_Meshing_ChunkData()

        let cStatus = meshingApi.getMeshDataById(nsdkHandle: nsdkHandle, id: id, meshChunkOut: &cChunk)
        if cStatus == ARDK_Status_OK {
            let owner = meshingApi.createResourceOwner(handle: cChunk.handle!)
            return MeshData(fromC: cChunk, owner: owner)
        }

        if cStatus == ARDK_Status_InvalidArgument {
            return nil
        }

        unexpectedNsdkStatus(cStatus)
    }

    /// Gets the timestamp of the latest mesh update.
    ///
    /// - Returns: The timestamp in milliseconds, or nil if no mesh data has been produced yet.
    public func lastMeshUpdateTime() -> UInt64? {
        var timestampMs: UInt64 = 0
        let cStatus = meshingApi.getLastMeshUpdateTime(nsdkHandle: nsdkHandle, timestampMsOut: &timestampMs)
        if cStatus.isError { unexpectedNsdkStatus(cStatus) }

        return timestampMs == 0 ? nil : timestampMs
    }
}
