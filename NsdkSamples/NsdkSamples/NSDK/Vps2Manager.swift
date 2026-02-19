import Foundation
import SwiftyNsdk
import simd

protocol Vps2ManagerDelegate: AnyObject {

    /// Notifies the delegate when VPS2 localization availability changes.
    ///
    /// This callback is invoked when the manager detects a transition between
    /// “not localized” and “localized” states (and vice versa). It is intended for
    /// updating UI or enabling/disabling features that require localization.
    ///
    /// - Parameters:
    ///   - manager: The VPS2 manager instance reporting the change.
    ///   - localized: `true` when VPS2 is considered localized; `false` otherwise.
    func vps2Manager(_ manager: Vps2Manager, didChangeLocalizationStatus localized: Bool)

    /// Notifies the delegate that an anchor was successfully created and its payload is available.
    ///
    /// This callback is invoked once the manager has finished generating or retrieving
    /// the payload for a newly created anchor.
    ///
    /// - Parameters:
    ///   - manager: The VPS2 manager instance reporting the event.
    ///   - id: The unique identifier of the anchor.
    ///   - payload: A Base64-encoded payload containing all data required to localize the anchor.
    func vps2Manager(_ manager: Vps2Manager, didCreateAnchor id: NsdkVpsAnchorId, payload: String)

    /// Notifies the delegate that a tracked anchor has updated its state.
    ///
    /// This callback is invoked periodically while an anchor is being tracked and localized.
    ///
    /// - Parameters:
    ///   - manager: The VPS2 manager instance reporting the update.
    ///   - id: The unique identifier of the anchor being updated.
    ///   - args: Contains the latest tracking information for a VPS anchor.
    func vps2Manager(_ manager: Vps2Manager,
                     didUpdateAnchor id: NsdkVpsAnchorId,
                     args: VpsAnchorUpdate)

    /// Notifies the delegate of VPS2 network request state changes.
    /// - Parameters:
    ///   - manager: The VPS2 manager instance reporting the update.
    ///   - records: The list of network requests that have occured since the last update.
    func vps2Manager(_ manager: Vps2Manager,
                     didReceiveNetworkRequestRecords records: [Vps2NetworkRequestRecord])
}

/// Optional delegate callbacks
extension Vps2ManagerDelegate {
    func vps2Manager(_ manager: Vps2Manager, didCreateAnchor id: NsdkVpsAnchorId, payload: String) { }
    func vps2Manager(_ manager: Vps2Manager, didReceiveNetworkRequestRecords records: [Vps2NetworkRequestRecord]) { }
}

final class Vps2Manager: NsdkFeatureManager<NsdkVps2Session>{
    // The event delegate for the VPS2 Manager
    weak var delegate: Vps2ManagerDelegate?

    // Contains the list of currently tracked VPS anchors
    private var anchorsBeingUpdated: Set<NsdkVpsAnchorId> = []

    // Contains the the list of manually created VPS anchors
    private var anchorsWaitingForPayload: Set<NsdkVpsAnchorId> = []

    // State and resources
    private let updateInterval: TimeInterval
    private var updateTimer: Timer? = nil
    private var isRunning: Bool = false
    private var hasLocalization: Bool = false

    init(nsdk: NsdkSession, updateInterval: TimeInterval = 0.1) {
        self.updateInterval = updateInterval
        super.init(session: nsdk.createVps2Session())
    }

    deinit {
        assert(!isRunning, "Vps2Manager must be stopped before deallocation.")
    }

    override func configuration() -> NsdkVps2Session.Configuration {
        // Set vps requests per second fields higher than default
        return NsdkVps2Session.Configuration(
            initialVpsRequestsPerSecond: 4,
            continuousVpsRequestsPerSecond: 1
        )
    }

    /// Starts the VPS2 session.
    override func start() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isRunning else { return }

        // Start the vps2 session
        super.start()

        // Start internal update loop
        let timer = Timer(timeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateAllAnchors()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        isRunning = true
    }

    /// Stops the VPS2 session.
    ///
    /// Any previously tracked anchors will be discarded.
    override func stop() {
        dispatchPrecondition(condition: .onQueue(.main))

        guard isRunning else { return }

        // Stop timer
        updateTimer?.invalidate()
        updateTimer = nil

        // Discard anchors
        anchorsBeingUpdated.removeAll()
        anchorsWaitingForPayload.removeAll()

        // Reset
        isRunning = false
        if hasLocalization {
            hasLocalization = false
            delegate?.vps2Manager(self, didChangeLocalizationStatus: false)
        }

        // Stop the vps2 session
        super.stop()
    }

    /// Requests to create and track an anchor at the specified pose. This will create an anchor relative
    /// to the currently tracked location that can be used to localize in future sessions.
    ///
    /// - Note:
    ///   - Callers should wait for `vps2Manager(_:didChangeLocalizationStatus:) (with localized == true)`
    ///     before attempting to create a new anchor.
    ///   - Use `vps2Manager(_:didCreateAnchor:payload:)` to be notified when the anchor has been
    ///     created and its payload is available.
    /// - Parameter pose: The 4x4 transformation matrix representing the anchor's position and
    ///     orientation
    /// - Returns: A unique identifier for the created anchor
    /// - Throws: An error if anchor creation fails.
    func createAnchor(transform: simd_float4x4) throws -> NsdkVpsAnchorId {
        dispatchPrecondition(condition: .onQueue(.main))

        let anchorId = try session.createAnchor(at: transform)
        anchorsWaitingForPayload.insert(anchorId)
        return anchorId
    }

    /// Requests to start tracking an anchor specified by a payload.
    ///
    /// A VPS payload contains all the data needed to localize at a VPS-activated location.
    /// A default payload for a VPS-activated location can be obtained from the "blob" field
    /// in the details view of an entry in the Geospatial Browser, or via `anchorPayload(anchorId:)`
    /// for user-generated anchors.
    ///
    /// - Parameter payload: Base64-encoded anchor payload
    /// - Returns: The unique identifier of the anchor encoded in the payload
    /// - Throws: ``NsdkError.invalidArgument`` if the payload is not valid.
    func trackAnchor(anchorPayload: String) throws -> NsdkVpsAnchorId {
        dispatchPrecondition(condition: .onQueue(.main))

        let anchorId = try session.trackAnchor(payload: anchorPayload)
        anchorsBeingUpdated.insert(anchorId)
        return anchorId
    }

    /// Request to stop tracking an anchor.
    ///
    /// Once removed, the anchor will no longer receive updates or consume processing resources.
    /// - Precondition: `anchorId` must be exactly 32 characters long.
    /// - Parameter anchorId: The unique identifier of the anchor to remove
    /// - Returns: True if the anchor was removed, false if otherwise
    @discardableResult
    func removeAnchor(anchorId: NsdkVpsAnchorId) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        // Try to remove from the pending anchors first
        if anchorsWaitingForPayload.remove(anchorId) != nil { return true }

        // Try to remove from the actively tracked anchors
        guard anchorsBeingUpdated.contains(anchorId) else { return false }
        guard session.removeAnchor(withId: anchorId) else { return false }
        anchorsBeingUpdated.remove(anchorId)

        return true
    }

    /// The localized transformer contains all data required to convert between
    /// AR space and geolocation based on the most recent VPS2 localization.
    ///
    /// - Returns: The latest localized VPS2 transformer, or `nil` if VPS2 is not currently localized.
    func latestLocalizedTransformer() -> Vps2Transformer? {
        let transformer = session.getLatestTransformer()
        guard transformer.trackingState != .unavailable else { return nil }
        return transformer
    }

    /// Computes geolocation for a pose using the provided transformer.
    ///
    /// - Parameters:
    ///   - transformer: The transformer to use for the geolocation calculation.
    ///   - pose: The pose in the device's AR coordinate space.
    /// - Returns: Geolocation data corresponding to the given pose, or `nil` if VPS2 is not currently localized.
    func geolocation(transformer: Vps2Transformer, pose: simd_float4x4) -> Vps2GeolocationData? {
        guard transformer.trackingState != .unavailable else { return nil }
        return session.getGeolocation(transformer: transformer, pose: pose)
    }

    /// Computes an AR pose for the provided geolocation using the provided transformer.
    ///
    /// - Parameters:
    ///   - transformer: The transformer to use for the pose calculation.
    ///   - location: The geolocation to convert into an AR pose.
    /// - Returns: The pose in the device's AR coordinate space, or `nil` if VPS2 is not currently localized.
    func pose(transformer: Vps2Transformer, location: GeolocationData) -> Vps2Pose? {
        guard transformer.trackingState != .unavailable else { return nil }
        return session.getPose(transformer: transformer, location: location)
    }

    // Internal method to update all tracked anchors
    private func updateAllAnchors() {
        // Anchors created manually (with transform) waiting for payload
        if !anchorsWaitingForPayload.isEmpty {
            var anchorsDidReceivePayload: [(id: NsdkVpsAnchorId, payload: String)] = []

            for anchorId in anchorsWaitingForPayload {
                guard let payloadResult = session.anchorPayload(anchorId: anchorId) else {
                    continue
                }

                switch payloadResult {
                case .inProgress:
                    continue
                case .success(let payload):
                    anchorsDidReceivePayload.append((anchorId, payload))
                default:
                    print("Unexpected state in anchor payload retrieval: \(payloadResult)")
                    break
                }
            }

            // Register anchors to receive updates
            let ids = anchorsDidReceivePayload.map(\.id)
            anchorsWaitingForPayload.subtract(ids)
            anchorsBeingUpdated.formUnion(ids)

            // Deferred delegate callbacks to avoid mutating inside the iteration
            for (anchorId, payload) in anchorsDidReceivePayload {
                delegate?.vps2Manager(self, didCreateAnchor: anchorId, payload: payload)
            }
        }

        // Update transforms
        var hasTrackedAnchor = false
        if !anchorsBeingUpdated.isEmpty {
            var anchorsUpdated: [(id: NsdkVpsAnchorId, updateArgs: VpsAnchorUpdate)] = []

            for anchorId in anchorsBeingUpdated {
                guard let update = session.anchorUpdate(anchorId: anchorId) else {
                    continue
                }

                hasTrackedAnchor = hasTrackedAnchor || update.trackingState == .tracked
                anchorsUpdated.append((anchorId, update))
            }

            // Deferred delegate callbacks to avoid mutating inside the iteration
            for (anchorId, args) in anchorsUpdated {
                delegate?.vps2Manager(self, didUpdateAnchor: anchorId, args: args)
            }
        }

        // Localization status changed
        if self.hasLocalization != hasTrackedAnchor {
            self.hasLocalization = hasTrackedAnchor
            delegate?.vps2Manager(self, didChangeLocalizationStatus: self.hasLocalization)
        }

        // Poll for network request records
        let records = session.getLatestNetworkRequestRecords()
        if !records.isEmpty {
            delegate?.vps2Manager(self, didReceiveNetworkRequestRecords: records)
        }
    }
}
