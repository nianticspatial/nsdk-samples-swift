// Copyright 2026 Niantic Spatial.

import Foundation
import NSDK

/// A helper class that provides automatic retry logic for NSDK operations that may fail.
///
/// Flow:
/// 1. Before running: if not authorized, wait for authorization.
/// 2. Run the operation.
/// 3. If the operation fails: wait 1 second, then retry once.
/// 4. If the retry fails, the error is thrown (no further retries).
///
/// Usage:
/// ```swift
/// let retryHelper = AuthRetryHelper(session: nsdkSession)
/// let result = try await retryHelper.withRetry {
///     try await sitesManager.requestSelfUserInfo()
/// }
/// ```
@MainActor
class AuthRetryHelper {
    private let session: NSDKSession
    private let initialAuthWaitSeconds: TimeInterval = 30.0
    private let retryDelaySeconds: TimeInterval = 1.0

    /// Creates a new retry helper.
    ///
    /// - Parameter session: The NSDK session to monitor for authorization status
    init(session: NSDKSession) {
        self.session = session
    }

    /// Executes an async operation with automatic retry.
    /// Pre-flight: waits for authorization if not already authorized. Then runs the operation; on failure waits 1s and retries once. If the retry fails, the error is thrown.
    ///
    /// - Parameter operation: The async operation to execute
    /// - Returns: The result of the operation
    /// - Throws: The error from the operation if both attempt and retry fail, or timeout if initial auth wait times out
    func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        try await waitForAuthorizationIfNeeded(timeout: initialAuthWaitSeconds)
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            print("[AuthRetryHelper] Operation failed: \(error), waiting 1 second before retry...")
            try await Task.sleep(nanoseconds: UInt64(retryDelaySeconds * 1_000_000_000))
            return try await operation()
        }
    }

    /// If not authorized, waits for the session to become authorized (pre-flight before running the operation).
    ///
    /// - Parameter timeout: Maximum time to wait in seconds
    /// - Throws: Timeout error if not authorized within `timeout` seconds
    private func waitForAuthorizationIfNeeded(timeout: TimeInterval) async throws {
        guard !session.isAuthorized else { return }
        let startTime = Date()
        while !session.isAuthorized {
            try Task.checkCancellation()
            if Date().timeIntervalSince(startTime) > timeout {
                throw AuthRetryError.authorizationTimeout
            }
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }
}

/// Errors that can be thrown by AuthRetryHelper
enum AuthRetryError: Error, LocalizedError {
    case authorizationTimeout

    var errorDescription: String? {
        switch self {
        case .authorizationTimeout:
            return "Timeout waiting for NSDK session authorization"
        }
    }
}
