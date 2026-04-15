// Copyright 2026 Niantic Spatial.

import Foundation
import Combine
import NSDK

/// Notification posted when the NS sample session is set (e.g. after login).
let nsSampleSessionDidSetNotification = Notification.Name("NSSampleSessionDidSet")

/// Notification posted when the NS sample session is stopped (logout).
let nsSampleSessionDidStopNotification = Notification.Name("NSSampleSessionDidStop")

enum NSSampleSessionManager {
    private static let updateInterval: TimeInterval = 10 // seconds
    private static let minUnexpiredTimeLeft: TimeInterval = 60 // seconds

    private static let sessionTokenKey = "NSSampleSessionToken"

    private static var refreshTask: Task<Void, Never>?
    private static var nsSampleSessionToken: String?

    static var sampleToken: String? { nsSampleSessionToken }

    /// Publisher that emits when a valid NS sample session token becomes available.
    /// Use this to wait for a token when it doesn't exist yet (e.g., during initial login flow).
    static let sampleTokenAvailable = PassthroughSubject<String, Never>()

    /// Sets up the NSDK session access by collecting the sample token flow and forwarding
    /// NSDK access tokens to the NSDK session.
    ///
    /// If a valid sample token is already available, the NSDK access token is requested
    /// immediately. Otherwise, a one-shot subscription waits for the next valid token.
    ///
    /// - Parameters:
    ///   - nsdkSession: The NSDK session to configure. Captured weakly
    /// - Returns: An `AnyCancellable` that the caller must retain for the duration of the
    ///   session. Cancelling or releasing it cancels any pending token subscription.
    @MainActor
    @discardableResult
    static func setupSessionAccess(for nsdkSession: NSDKSession) -> AnyCancellable? {
        if let token = sampleToken, !AuthUtils.isTokenEmptyOrExpiring(token, minUnexpiredTimeLeft: 0) {
            requestAndSetNsdkAccessToken(nsSampleSessionToken: token, session: nsdkSession)
            return nil
        } else {
            let cancellable = sampleTokenAvailable
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak nsdkSession] token in
                    MainActor.assumeIsolated {
                        guard let session = nsdkSession else { return }
                        requestAndSetNsdkAccessToken(nsSampleSessionToken: token, session: session)
                    }
                }
            return cancellable
        }
    }

    @MainActor
    private static func requestAndSetNsdkAccessToken(nsSampleSessionToken: String, session: NSDKSession) {
        Task { [weak session] in
            guard let session else { return }
            do {
                let nsdkRefreshToken = try await requestNsdkRefreshToken(sessionToken: nsSampleSessionToken)
                let nsdkAccessToken = try await requestNsdkAccessToken(nsdkRefreshToken: nsdkRefreshToken)
                await MainActor.run {
                    session.setAccessToken(nsdkAccessToken)
                }
            } catch {
                print("NSSampleSessionManager: failed to request NSDK access token: \(error)")
            }
        }
    }

    static var isSessionInProgress: Bool {
        !AuthUtils.isTokenEmptyOrExpiring(nsSampleSessionToken, minUnexpiredTimeLeft: 0)
    }

    static func start() {
        if nsSampleSessionToken != nil {
            return
        }

        loadSessionData()

        guard !AuthUtils.isTokenEmptyOrExpiring(nsSampleSessionToken, minUnexpiredTimeLeft: 0) else {
            clearSession()
            saveSessionData()
            return
        }

        // Emit the token if it's valid (loaded from storage)
        if let token = nsSampleSessionToken {
            sampleTokenAvailable.send(token)
        }

        updateSession()
    }

    static func setNSSampleSession(sessionToken: String?) {
        let wasTokenValid = !AuthUtils.isTokenEmptyOrExpiring(nsSampleSessionToken, minUnexpiredTimeLeft: 0)

        nsSampleSessionToken = sessionToken
        saveSessionData()

        // Emit the token if it's valid and we didn't have a valid token before
        if let token = sessionToken,
           !AuthUtils.isTokenEmptyOrExpiring(token, minUnexpiredTimeLeft: 0),
           !wasTokenValid {
            sampleTokenAvailable.send(token)
        }

        updateSession()
        NotificationCenter.default.post(name: nsSampleSessionDidSetNotification, object: nil)
    }

    static func stopNSSampleSession() {
        refreshTask?.cancel()
        refreshTask = nil
        clearSession()
        saveSessionData()
        NSDKSession.logout()
        NotificationCenter.default.post(name: nsSampleSessionDidStopNotification, object: nil)
    }

    private static func clearSession() {
        nsSampleSessionToken = nil
    }

    private static func saveSessionData() {
        let defaults = UserDefaults.standard

        if let token = nsSampleSessionToken {
            defaults.set(token, forKey: sessionTokenKey)
        } else {
            defaults.removeObject(forKey: sessionTokenKey)
        }
    }

    private static func loadSessionData() {
        nsSampleSessionToken = UserDefaults.standard.string(forKey: sessionTokenKey)
    }

    private static func updateSession() {
        refreshTask?.cancel()

        guard let token = nsSampleSessionToken,
              !AuthUtils.isTokenEmptyOrExpiring(token, minUnexpiredTimeLeft: 0) else {
            return
        }

        refreshTask = Task.detached(priority: .background) {
            await runSessionLoop()
        }
    }

    private static func executeSessionRefresh() async -> Bool {
        guard let token = nsSampleSessionToken,
              !AuthUtils.isTokenEmptyOrExpiring(token, minUnexpiredTimeLeft: 0) else {
            print("NSSampleSessionManager: session token has expired")
            return false
        }

        do {
            let newToken = try await requestSampleSessionAccess(sessionToken: token)
            nsSampleSessionToken = newToken
            saveSessionData()
        } catch {
            print("NSSampleSessionManager: failed to refresh session: \(error)")
            return false
        }

        return true
    }

    private static func runSessionLoop() async {
        defer { refreshTask = nil }

        do {
            while !Task.isCancelled {
                if AuthUtils.isTokenEmptyOrExpiring(nsSampleSessionToken, minUnexpiredTimeLeft: minUnexpiredTimeLeft) {
                    guard await executeSessionRefresh() else { break }
                    print("NSSampleSessionManager: successfully refreshed session")
                }

                let delay = UInt64(updateInterval * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        } catch is CancellationError {
            // Nothing to do.
        } catch {
            print("NSSampleSessionManager: refresh loop error: \(error)")
        }

        print("NSSampleSessionManager: refresh loop stopped.")
    }
}
