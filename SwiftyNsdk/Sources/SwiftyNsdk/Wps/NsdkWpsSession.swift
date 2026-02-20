import CArdk
import Foundation
import simd
import ARKit

extension NsdkSession {
    /// Creates a new World Positioning System (WPS) session.
    ///
    /// - Returns: A new WPS session attached to this NSDK session
    public func createWpsSession() -> NsdkWpsSession {
        let key = ObjectIdentifier(NsdkWpsSession.self)
        if let existing = disposables[key] as? NsdkWpsSession {
            return existing
        }
        let session = NsdkWpsSession(nsdkHandle: nativeHandle, api: CWpsApi())
        disposables[key] = session
        return session
    }
}

/// A session for World Positioning System (WPS) functionality.
///
/// WPS provides the 3D position and orientation of the device in geographic coordinates
/// as an alternative to using device GPS and compass heading data. WPS provides greater
/// accuracy and frame-to-frame stability than standard GPS positioning, making it more
/// suitable for AR applications. As the user moves around, WPS maintains the device's position,
/// making it suitable for continuous use over long periods of time and long distances. WPS will
/// work in any location where the phone has a GPS signal, but the accuracy will vary depending
/// on GPS accuracy.
public final class NsdkWpsSession: NsdkSession.IDisposable {
    private let api: WpsApi
    private let nsdkHandle: NsdkHandle

    /// Reports errors that have occurred within processes running inside this feature.
    ///
    /// Check this periodically to see if any errors have occurred with processes running
    /// inside this feature. Once an error has been flagged, it will remain flagged until the
    /// culprit process has been run again and completed successfully.
    ///
    /// - Returns: Feature status flags for any issues that have occurred
    ///
    /// ## Example
    ///
    /// ```swift
    /// let status = wpsSession.getFeatureStatus()
    /// if !status.isOk() {
    ///     print("WPS has encountered an error")
    /// }
    /// ```
    public func featureStatus() -> NsdkFeatureStatus {
        let flags = api.getFeatureStatus(nsdkHandle: nsdkHandle)
        return NsdkFeatureStatus(rawValue: flags.rawValue)
    }

    /// Configures the session with the specified settings.
    ///
    /// - Attention: This method must be called while the session is stopped,
    ///   or else configuration will fail. In that case, while this function returns without
    ///   throwing, configuration will still fail asynchronously. Use ``featureStatus()``
    ///   to check that configuration has not failed.
    /// - Parameter config: An object that defines this session's behavior.
    ///   Only settings that differ from the defaults will be applied.
    /// - Throws: ``NsdkError.invalidArgument`` if the configuration is invalid.
    ///   Check NSDK's C logs for more information.
    public func configure(with config: Configuration) throws {
        var cConfig = config.convertToC()  // Must be a mutable var
        let cStatus = withUnsafeMutablePointer(to: &cConfig) { ptr in
            api.configure(nsdkHandle: nsdkHandle, config: ptr)
        }

        if cStatus.isError {
            if cStatus.isInvalidArgument {
                throw NsdkError.invalidArgument
            } else {
                unexpectedNsdkStatus(cStatus)
            }
        }
    }

    /// Starts the WPS system.
    ///
    /// This begings the process of collecting some local device sensor data that is needed for
    /// localization.
    public func start() {
        let cStatus = api.start(nsdkHandle: nsdkHandle)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }

    /// Stops the WPS system.
    ///
    /// This halts all WPS processing. The session can be reconfigured and restarted after
    /// stopping.
    public func stop() {
        let cStatus = api.stop(nsdkHandle: nsdkHandle)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }

    /// Gets the transform of the latest geolocation estimate.
    ///
    /// This exposes the low level data that can be used to pin geolocated content into the AR
    /// coordinate system. To retrieve simplified device specific coordinates and heading, see
    /// ``devicePoseAsGeolocation(_:)``.
    ///
    /// - Note: An ``NsdkError.invalidOperation`` if the session is not started.
    /// - Returns: The location transform, if available, or an error code otherwise.
    public func latestLocation() -> Result<WpsLocation, WpsError> {
        var location = ARDK_WPS_Location();
        let cStatus = api.getLatestLocation(nsdkHandle: nsdkHandle, location: &location)

        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }

        if (location.status != ARDK_WPS_Status_Available) {
            return .failure(WpsError(fromC: location.status))
        }

        return .success(WpsLocation(fromC: location))
    }

    /// Use WPS to get an estimated geolocation for a pose in AR space.
    ///
    /// - Parameter pose: A pose in the device's AR space.
    /// - Returns: The estimated geolocation, if available, or an error code otherwise.
    public func devicePoseAsGeolocation(pose: simd_float4x4) -> Result<GeolocationData, WpsError> {
        let cPose = pose.fromARKitToNsdkTransform()
        var geolocationOut = ARDK_WPS_GeolocationData()

        let cStatus = api.getDevicePoseAsGeolocation(
            nsdkHandle: nsdkHandle,
            cameraPose: cPose,
            geolocationOut: &geolocationOut)

        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }

        if geolocationOut.wps_status != ARDK_WPS_Status_Available {
            return .failure(WpsError(fromC: geolocationOut.wps_status))
        }

        return .success(GeolocationData(fromC: geolocationOut.geolocation_data))
    }

    init(nsdkHandle: NsdkHandle, api: WpsApi) {
        self.nsdkHandle = nsdkHandle
        self.api = api
        let cStatus = api.create(nsdkHandle: nsdkHandle)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }

    internal func destroy() {
        let cStatus = api.destroy(nsdkHandle: nsdkHandle)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }
}
