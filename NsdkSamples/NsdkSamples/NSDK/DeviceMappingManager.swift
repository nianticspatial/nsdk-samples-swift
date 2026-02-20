import Foundation
import SwiftyNsdk

/// Manages NSDK mapping session lifecycle and map storage operations
class DeviceMappingManager: NsdkFeatureManager<NsdkDeviceMappingSession> {

    /// Map storage instance for managing map data
    private let mapStorage: NsdkMapStorage

    /// Timer for periodically checking map updates
    private var mappingUpdateTimer: Timer?

    /// Interval for checking map updates
    private let updateInterval: TimeInterval

    /// Indicates whether mapping is currently active
    private(set) var isMapping = false

    /// Callback invoked when a map update is available
    var onMapUpdate: ((NsdkBuffer) -> Void)?

    /// Initializes the manager with an NSDK session
    /// - Parameters:
    ///   - nsdk: The NSDK session to create mapping and storage from
    ///   - updateInterval: How often to check for map updates (default: 1.0 second)
    init(nsdk: NsdkSession, updateInterval: TimeInterval = 1.0) {
        self.mapStorage = nsdk.createMapStorage()
        self.updateInterval = updateInterval
        super.init(session: nsdk.createDeviceMappingSession())
    }

    override func configuration() -> NsdkDeviceMappingSession.Configuration {
        // Return default configuration
        return NsdkDeviceMappingSession.Configuration()
    }

    override func start() {
        super.start()

        guard !isMapping else { return }

        session.startMapping()
        isMapping = true

        // Start timer to check for map updates
        mappingUpdateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.checkForMapUpdates()
        }

        print("DeviceMappingManager: Started mapping")
    }

    override func stop() {
        guard isMapping else {
            super.stop()
            return
        }

        session.stopMapping()
        isMapping = false

        mappingUpdateTimer?.invalidate()
        mappingUpdateTimer = nil

        print("DeviceMappingManager: Stopped mapping")

        super.stop()
    }

    /// Retrieves the complete map data from storage
    /// - Returns: The serialized map data buffer if available, `nil` if no map data exists.
    func getMapData() -> NsdkBuffer? {
        return mapStorage.mapData()
    }

    /// Adds a map to the storage
    /// - Parameter dataBuffer: The map data buffer to add
    func addMap(dataBuffer: NsdkBuffer) throws {
        return try mapStorage.addMap(map: dataBuffer)
    }

    /// Retrieves the root anchor for the current map
    /// - Returns: The payload of the root anchor, encoded as a base64 string if available, `nil` if otherwise.
    func createRootAnchor() -> String? {
        return mapStorage.createRootAnchor()
    }

    /// Extracts metadata from a map buffer using the specified anchor
    /// - Parameters:
    ///   - anchorPayloadBase64: The base64-encoded anchor payload
    ///   - mapBuffer: The map data buffer
    /// - Returns: The extracted map metadata if it exists, `nil` if otherwise.
    func extractMapMetadata(anchorPayloadBase64: String, map mapBuffer: NsdkBuffer) throws -> MapMetadata? {
        return try mapStorage.extractMapMetadata(anchorPayload: anchorPayloadBase64, map: mapBuffer)
    }

    // MARK: - Private Methods

    /// Checks for new map updates and invokes callback if available
    private func checkForMapUpdates() {
        guard let updateBuffer = mapStorage.mapUpdate() else {
            // No update available yet, which is normal during mapping
            return
        }

        print("DeviceMappingManager: Received map update with \(updateBuffer.dataSize) bytes")

        // Notify via callback
        onMapUpdate?(updateBuffer)
    }
}
