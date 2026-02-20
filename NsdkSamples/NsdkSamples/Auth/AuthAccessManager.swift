//
//  AuthAccessManager.swift
//  NsdkSamples
//
// Maintains auth access to the NS API, refreshing it periodically.
// Access is requested using the sample user session access token.
//

import Foundation
import Combine

/// A manager that maintains auth access to the NS API, refreshing it periodically.
enum AuthAccessManager {
    private static let updateInterval: TimeInterval = 10 // seconds
    private static let minUnexpiredTimeLeft: TimeInterval = 60 // seconds

    private static var refreshTask: Task<Void, Never>?
    private static var userSessionAccessToken: String?
    private static var authAccessToken: String?

    static var accessToken: String? { authAccessToken }

    static let accessTokenUpdated = PassthroughSubject<String, Never>()

    /// Starts the auth access refresh loop with the given user session access token.
    /// - Parameter userSessionAccessToken: The user session access token used to authenticate requests.
    static func startAuthAccess(userSessionAccessToken: String) {
        // Don't interrupt the current auth access loop if we already have a good user session access token
        if !AuthUtils.isTokenEmptyOrExpiring(AuthAccessManager.userSessionAccessToken, minUnexpiredTimeLeft: 0) {
            return
        }

        // Don't start the auth access loop if we don't have an access token
        guard !userSessionAccessToken.isEmpty else {
            return
        }

        refreshTask?.cancel()
        AuthAccessManager.userSessionAccessToken = userSessionAccessToken

        refreshTask = Task {
            await startAuthAccessAsync()
        }
    }

    /// Stops the auth access refresh loop.
    static func stopAuthAccess() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Sets the user session access token.
    static func setUserSessionAccessToken(_ token: String?) {
        userSessionAccessToken = token
    }

    /// Checks if the current access token is expired or about to expire.
    private static func accessIsExpiredOrAboutToExpire() -> Bool {
        return AuthUtils.isTokenEmptyOrExpiring(authAccessToken, minUnexpiredTimeLeft: minUnexpiredTimeLeft)
    }

    /// The main async loop that periodically refreshes the access token.
    private static func startAuthAccessAsync() async {
        // Loop that runs forever during runtime, periodically refreshing the access token
        // (if we have a valid user session access token)
        do {
            while true {
                try Task.checkCancellation()

                if accessIsExpiredOrAboutToExpire() {
                    guard let token = userSessionAccessToken, !token.isEmpty else {
                        print("Error: Failed to request NS access token - no user session access token available.")
                        break
                    }

                    do {
                        let accessToken = try await RequestAuthAccess.execute(userSessionAccessToken: token)
                        if let accessToken = accessToken, !accessToken.isEmpty {
                            authAccessToken = accessToken
                            accessTokenUpdated.send(accessToken)
                        } else {
                            print("Error: Failed to request NS access token - empty response.")
                            break
                        }
                    } catch {
                        print("Error: Failed to request NS access token: \(error)")
                        break
                    }
                }

                try await Task.sleep(nanoseconds: UInt64(updateInterval * 1_000_000_000))
            }
        } catch is CancellationError {
            // Exiting the application, so we don't need to do anything here.
        } catch {
            print("Error in auth access refresh loop: \(error)")
        }

        print("Auth Access Refresh loop stopped.")
    }
}
