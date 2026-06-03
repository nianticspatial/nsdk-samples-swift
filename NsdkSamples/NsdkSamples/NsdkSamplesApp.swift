// Copyright 2026 Niantic Spatial.

import SwiftUI
import ARKit

@main
struct NsdkSamplesApp: App {
    init() {
        guard ARWorldTrackingConfiguration.isSupported else {
            fatalError("ARKit is not available on this device.")
        }
    }
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
