import Foundation
import SwiftyNsdk
import ARKit

// Callback that receives pose updates for tracked anchors
// Parameters: anchorId, transform
typealias PoseCallback = (String, simd_float4x4) -> Void

class VpsManager : NsdkFeatureManager<NsdkVpsSession> {
    // Track anchors with their callbacks
    private var trackedAnchors: Dictionary<NsdkVpsAnchorId, PoseCallback> = [:]
    private var createdAnchors: Dictionary<NsdkVpsAnchorId, (payload: String?, callback: PoseCallback)> = [:]

    // Internal timer for automatic updates
    private var updateTimer: Timer?
    private weak var arSession: ARSession?
    private let updateInterval: TimeInterval
    private let deviceMapEnabled: Bool
    private var vpsSessionStarted: Bool

    init(nsdk: NsdkSession, arSession: ARSession, updateInterval: TimeInterval = 0.1, deviceMapEnabled: Bool = false) {
        self.arSession = arSession
        self.updateInterval = updateInterval
        self.deviceMapEnabled = deviceMapEnabled
        self.vpsSessionStarted = false
        super.init(session: nsdk.createVpsSession())
    }

    override func configuration() -> NsdkVpsSession.Configuration {
        return NsdkVpsSession.Configuration(
            continuousLocalizationEnabled: true,
            temporalFusionEnabled: true,
            deviceMapLocalizationEnabled: deviceMapEnabled
        )
    }

    override func start() {
        // Only start if the feature is not started yet. Otherwise, starting multiple times will cause assert
        if (self.vpsSessionStarted) {
            return
        }

        super.start()
        // Start internal update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateAllAnchors()
        }
        self.vpsSessionStarted = true
    }

    override func stop() {
        // Stop timer
        updateTimer?.invalidate()
        updateTimer = nil

        // Clear all anchor tracking
        trackedAnchors.removeAll()

        print("Created \(createdAnchors.count) anchors")
        var payloadsCount = 0
        for kvp in createdAnchors {
            if let payload = kvp.value.payload {
                print(payload)
                payloadsCount += 1
            }
        }
        print("Got \(payloadsCount) payloads")

        createdAnchors.removeAll()

        super.stop()
        self.vpsSessionStarted = false
    }

    // Track an anchor from a payload string
    // Returns true if tracking started successfully
    func trackAnchor(anchorPayload: String, callback: @escaping PoseCallback) -> Bool {
        do {
            let anchorId = try session.trackAnchor(payload: anchorPayload)
            print("Started tracking anchor: \(anchorId)")
            trackedAnchors[anchorId] = callback
            return true
        } catch {
            print("Error calling trackAnchor for payload (\(anchorPayload.prefix(8))...): \(error)")
            return false
        }
    }

    // Stop tracking a specific anchor by payload
    func stopTracking(anchorPayload: String) {
        // Find the anchor ID that matches this payload
        for (anchorId, data) in createdAnchors {
            if data.payload == anchorPayload {
                let removed = session.removeAnchor(withId: anchorId)
                if removed {
                    trackedAnchors.removeValue(forKey: anchorId)
                    createdAnchors.removeValue(forKey: anchorId)
                    print("Stopped tracking anchor: \(anchorId)")
                } else {
                    print("Failed to remove anchor: \(anchorId)")
                }
                return
            }
        }
    }

    // Get GPS coordinates using VPS localization
    // Returns nil if geolocation is not available
    func getVpsLocationGps() -> GeolocationData? {
        guard let frame = arSession?.currentFrame else {
            print("getVpsLocationGps: can't get frame")
            return nil
        }

        let locationState = session.devicePoseAsGeolocation(pose: frame.camera.transform)
        switch locationState {
        case .success(let geolocation):
            print(String(format: "VPS Localized GPS acquired: Lat: %.2f, Lon: %.2f, Heading: %.2f, Alt: %.2f",
                         geolocation.latitude, geolocation.longitude, geolocation.heading, geolocation.altitude))
            return geolocation
        case .failure(let error):
            print("Geolocation Error: \(error)")
            return nil
        }
    }

    // Create an anchor at a specific transform
    // Returns the anchor ID string (payload will be available later via callback)
    func createAnchor(transform: simd_float4x4, callback: @escaping PoseCallback) -> String? {
        print("Creating anchor at transform: \(transform)")
        do {
            let anchorId = try session.createAnchor(at: transform)
            createdAnchors[anchorId] = (payload: nil, callback: callback)
            trackedAnchors[anchorId] = callback
            return anchorId
        } catch {
            print("Error creating anchor: \(error)")
            return nil
        }
    }

    // Internal method to update all tracked anchors
    private func updateAllAnchors() {
        // Update all tracked anchors
        for (anchorId, callback) in trackedAnchors {
            guard let update = session.anchorUpdate(anchorId: anchorId) else {
                continue
            }

            if update.trackingState != .notTracked, let transform = update.anchorToLocalTransform {
                callback(anchorId, transform)
            }
        }

        // Check for anchor payloads that have become ready
        for (anchorId, data) in createdAnchors {
            if data.payload != nil { continue }

            guard let payloadResult = session.anchorPayload(anchorId: anchorId) else {
                continue
            }

            switch payloadResult {
            case .inProgress(nil):
                continue
            case .success(let payload):
                createdAnchors[anchorId] = (payload: payload, callback: data.callback)
                print("Got payload for anchor (\(anchorId)): \(payload.prefix(16))...")
            default:
                print("Unexpected state in anchor payload retrieval: \(payloadResult)")
                break
            }
        }
    }
}
