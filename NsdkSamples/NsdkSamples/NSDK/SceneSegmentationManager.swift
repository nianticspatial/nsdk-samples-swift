//
//  SceneSegmentationManager.swift
//
//  Provides a thin wrapper around NsdkSemanticsSession,
//  exposing simple lifecycle control and safe accessors.
//

import Foundation
import SwiftyNsdk
import ARKit
import Metal

final class SceneSegmentationManager {

    // MARK: - Properties

    private let session: NsdkSemanticsSession

    // MARK: - Initialization

    /// Creates a new semantics manager attached to the provided NSDK session.
    init(nsdk: NsdkSession) {
        self.session = nsdk.createSemanticsSession()
    }

    // MARK: - Lifecycle Control

    /// Starts the semantic segmentation inference session using the default configuration.
    /// Default NSDK config runs at ~10 FPS.
    func start() {
        let config = NsdkSemanticsSession.Configuration()

        do {
            try session.configure(with: config)
            session.start()
        } catch {
            print("❌ [SemanticsManager] Failed to configure semantics session: \(error)")
        }
    }

    /// Stops semantic segmentation inference.
    func stop() {
        session.stop()
    }

    // MARK: - Confidence Retrieval

    /// Retrieves the most recent semantic confidence result for a given channel.
    ///
    /// - Parameter channelIndex: Index of the semantic class inside the model.
    /// - Returns: A `SemanticsResult` on success, otherwise `nil`.
    func latestConfidence(for channel: SemanticsChannelName) -> SemanticsResult? {

        // Ensure semantic inference is functioning correctly.
        let status = session.featureStatus()
        guard status.isOk() else {
            print("⚠️ [SemanticsManager] Semantics feature status error: \(status)")
            return nil
        }

        let resultState: NsdkAsyncState<SemanticsResult, AwarenessError>
        do {
            resultState = try session.latestConfidence(channel: channel)
        } catch {
            print("❌ [SemanticsManager] Failed to fetch latest confidence: \(error)")
            return nil
        }

        switch resultState {
        case .success(let result):
            return result

        case .inProgress, .notReady:
            return nil

        case .failure(let error):
            print("❌ [SemanticsManager] Confidence retrieval error: \(error)")
            return nil

        @unknown default:
            print("⚠️ [SemanticsManager] Unexpected result state in latestConfidence.")
            return nil
        }
    }
}
