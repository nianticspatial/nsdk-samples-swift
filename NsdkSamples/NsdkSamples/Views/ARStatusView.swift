// Copyright 2026 Niantic Spatial.

import ARKit
import SwiftUI

/// Displays AR tracking status as an overlay bar at the top of the screen.
struct ARStatusView: View {
    let frameState: ARFrameState

    @State private var trackingState: ARCamera.TrackingState = .notAvailable
    @State private var anchorsIsEmpty: Bool = true

    private var message: String {
        switch trackingState {
        case .normal where anchorsIsEmpty:
            return "Move the device around to detect horizontal and vertical surfaces."
        case .notAvailable:
            return "Tracking unavailable."
        case .limited(.excessiveMotion):
            return "Tracking limited - Move the device more slowly."
        case .limited(.insufficientFeatures):
            return "Tracking limited - Point the device at an area with visible surface detail, or improve lighting conditions."
        case .limited(.initializing):
            return "Initializing AR session."
        default:
            return ""
        }
    }

    var body: some View {
        Group {
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
            }
        }
        .onReceive(frameState.$trackingState) { state in
            trackingState = state
        }
        .onReceive(frameState.$anchorsIsEmpty) { empty in
            anchorsIsEmpty = empty
        }
    }
}
