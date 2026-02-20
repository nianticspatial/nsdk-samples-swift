//
//  NianticSpatialAccessManager.swift
//  NsdkSamples
//
// Manages access to Niantic Spatial Auth at a high level.
// Starts either the sample backend service (AuthAccessManager) or relies on the
// runtime refresh path (NsdkSession with runtime refresh token), depending on
// the UseSampleBackend setting. When the sample backend is used, it keeps the
// current Niantic Spatial access token valid.
//

import Foundation

/// Notification posted when the user session is set (e.g. after login).
let nianticSpatialAccessUserSessionDidSetNotification = Notification.Name("NianticSpatialAccessUserSessionDidSet")

/// Notification posted when the user session is stopped (logout).
let nianticSpatialAccessUserSessionDidStopNotification = Notification.Name("NianticSpatialAccessUserSessionDidStop")

/// Manages access to Niantic Spatial Auth at a high level.
enum NianticSpatialAccessManager {
    private static let useSampleBackendKey = "NianticSpatialAccessManager.useSampleBackend"

    private static var didSetupObservers = false

    /// Call once at app startup (e.g. from the main auth/home screen) to register for login/logout and run initial setup.
    static func start() {
        setupObserversIfNeeded()
        setupAccess()
    }

    /// When true, the sample backend is used to refresh the NSDK access token.
    /// When false, the runtime refresh path is used (NsdkSession is given a runtime refresh token and manages refresh internally).
    static var useSampleBackend: Bool {
        get {
            if UserDefaults.standard.object(forKey: useSampleBackendKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: useSampleBackendKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: useSampleBackendKey)
            stopAccess()
            setupAccess()
        }
    }

    private static func setupObserversIfNeeded() {
        guard !didSetupObservers else { return }
        didSetupObservers = true

        NotificationCenter.default.addObserver(
            forName: nianticSpatialAccessUserSessionDidSetNotification,
            object: nil,
            queue: .main
        ) { _ in
            setupAccess()
        }

        NotificationCenter.default.addObserver(
            forName: nianticSpatialAccessUserSessionDidStopNotification,
            object: nil,
            queue: .main
        ) { _ in
            stopAccess()
        }
    }

    private static func stopAccess() {
        AuthAccessManager.stopAuthAccess()
    }

    private static func setupAccess() {
        guard UserSessionManager.isSessionInProgress else {
            return
        }

        if useSampleBackend, let accessToken = UserSessionManager.accessToken, !accessToken.isEmpty {
            AuthAccessManager.startAuthAccess(userSessionAccessToken: accessToken)
        }
        // When !useSampleBackend, the runtime refresh path is handled by BaseARViewController
        // (requestAndSetRuntimeRefreshToken and NsdkSession internal refresh).
    }
}
