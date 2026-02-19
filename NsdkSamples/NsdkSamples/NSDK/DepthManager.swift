//
//  DepthManager.swift
//
//  Provides a thin wrapper around NsdkDepthSession,
//  exposing simple lifecycle control and safe accessors.
//

import Foundation
import ARKit
import Metal
import SwiftyNsdk

/// A lightweight controller that manages NSDK depth inference.
final class DepthManager: NSObject {

    // MARK: - Properties

    private let session: NsdkDepthSession

    // MARK: - Initialization

    /// Creates a new depth manager for the given NSDK session.
    init(nsdk: NsdkSession) {
        self.session = nsdk.createDepthSession()
    }

    // MARK: - Session Control

    /// Starts the depth inference session using the default configuration.
    /// The default depth configuration runs inference at ~10 FPS.
    func start() {
        let config = NsdkDepthSession.Configuration()
        do {
            try session.configure(with: config)
            session.start()
        } catch {
            print("❌ [DepthManager] Failed to configure depth session: \(error)")
        }
    }

    /// Stops depth inference.
    func stop() {
        session.stop()
    }

    // MARK: - Depth Retrieval

    /// Retrieves the most recent depth inference result.
    ///
    /// - Returns: A `DepthResult` if available, otherwise `nil`.
    func latestDepth() -> DepthResult? {

        // Ensure the depth feature is functioning properly.
        let status = session.featureStatus()
        guard status.isOk() else {
            print("⚠️ [DepthManager] Depth feature status error: \(status)")
            return nil
        }

        // Safely unwrap the latest depth result.
        switch session.latestDepth() {
        case .success(let result):
            return result

        case .notReady, .inProgress:
            return nil

        case .failure(let error):
            print("❌ [DepthManager] Depth inference error: \(error)")
            return nil

        @unknown default:
            print("⚠️ [DepthManager] Unexpected depth result state.")
            return nil
        }
    }
}
