//
//  UserSessionManager.swift
//  NsdkSamples
//
// Maintains a user session with the sample backend and refreshes the access
// token while the app is running. Refresh and access tokens are persisted in
// `UserDefaults` so the session can survive app restarts.
//

import Foundation
import Combine

enum UserSessionManager {
    private static let updateInterval: TimeInterval = 10 // seconds
    private static let minUnexpiredTimeLeft: TimeInterval = 60 // seconds

    private static let refreshTokenKey = "UserSessionRefreshToken"
    private static let accessTokenKey = "UserSessionAccessToken"

    private static var refreshTask: Task<Void, Never>?
    private static var userSessionRefreshToken: String?
    private static var userSessionAccessToken: String?

    static var refreshToken: String? { userSessionRefreshToken }
    static var accessToken: String? { userSessionAccessToken }

    /// Publisher that emits when a valid user session refresh token becomes available.
    /// Use this to wait for a token when it doesn't exist yet (e.g., during initial login flow).
    static let refreshTokenAvailable = PassthroughSubject<String, Never>()

    static var isSessionInProgress: Bool {
        !AuthUtils.isTokenEmptyOrExpiring(userSessionRefreshToken, minUnexpiredTimeLeft: 0)
    }

    static func start() {
        if userSessionRefreshToken != nil {
            return
        }

        loadUserSessionData()

        guard !AuthUtils.isTokenEmptyOrExpiring(userSessionRefreshToken, minUnexpiredTimeLeft: 0) else {
            clearSession()
            saveUserSessionData()
            return
        }

        // Emit the refresh token if it's valid (loaded from storage)
        if let token = userSessionRefreshToken {
            refreshTokenAvailable.send(token)
        }

        updateUserSession()
    }

    static func setUserSession(refreshToken: String?, accessToken: String?) {
        let wasTokenValid = !AuthUtils.isTokenEmptyOrExpiring(userSessionRefreshToken, minUnexpiredTimeLeft: 0)

        userSessionRefreshToken = refreshToken
        userSessionAccessToken = accessToken
        saveUserSessionData()

        // Emit the refresh token if it's valid and we didn't have a valid token before
        if let token = refreshToken,
           !AuthUtils.isTokenEmptyOrExpiring(token, minUnexpiredTimeLeft: 0),
           !wasTokenValid {
            refreshTokenAvailable.send(token)
        }

        updateUserSession()
        NotificationCenter.default.post(name: nianticSpatialAccessUserSessionDidSetNotification, object: nil)
    }

    static func stopUserSession() {
        refreshTask?.cancel()
        refreshTask = nil
        clearSession()
        saveUserSessionData()
        NotificationCenter.default.post(name: nianticSpatialAccessUserSessionDidStopNotification, object: nil)
    }

    private static func clearSession() {
        userSessionRefreshToken = nil
        userSessionAccessToken = nil
    }

    private static func saveUserSessionData() {
        let defaults = UserDefaults.standard

        if let refresh = userSessionRefreshToken {
            defaults.set(refresh, forKey: refreshTokenKey)
        } else {
            defaults.removeObject(forKey: refreshTokenKey)
        }

        if let access = userSessionAccessToken {
            defaults.set(access, forKey: accessTokenKey)
        } else {
            defaults.removeObject(forKey: accessTokenKey)
        }
    }

    private static func loadUserSessionData() {
        let defaults = UserDefaults.standard
        userSessionRefreshToken = defaults.string(forKey: refreshTokenKey)
        userSessionAccessToken = defaults.string(forKey: accessTokenKey)
    }

    private static func updateUserSession() {
        refreshTask?.cancel()

        guard let refreshToken = userSessionRefreshToken,
              !AuthUtils.isTokenEmptyOrExpiring(refreshToken, minUnexpiredTimeLeft: 0) else {
            return
        }

        refreshTask = Task.detached(priority: .background) {
            await runUserSessionLoop()
        }
    }

    private static func executeSessionRefresh() async -> Bool {
        guard let refreshToken = userSessionRefreshToken,
              !AuthUtils.isTokenEmptyOrExpiring(refreshToken, minUnexpiredTimeLeft: 0) else {
            print("User Session Refresh token has expired")
            return false
        }

        do {
            let result = try await RequestUserSessionAccess.execute(refreshToken: refreshToken)

            userSessionRefreshToken = result.refreshToken
            userSessionAccessToken = result.accessToken
            saveUserSessionData()

            AuthAccessManager.setUserSessionAccessToken(userSessionAccessToken)
        } catch {
            print("UserSessionManager: failed to refresh user session: \(error)")
            return false
        }

        return true
    }

    private static func runUserSessionLoop() async {
        defer { refreshTask = nil }

        do {
            while !Task.isCancelled {
                if AuthUtils.isTokenEmptyOrExpiring(userSessionAccessToken, minUnexpiredTimeLeft: minUnexpiredTimeLeft) {
                    guard await executeSessionRefresh() else { break }
                    print("Successfully refreshed User Session")
                }

                let delay = UInt64(updateInterval * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        } catch is CancellationError {
            // Nothing to do.
        } catch {
            print("UserSessionManager: refresh loop error: \(error)")
        }

        print("UserSessionManager: refresh loop stopped.")
    }
}
