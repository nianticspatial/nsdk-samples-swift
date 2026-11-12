// Copyright 2026 Niantic Spatial.

import SwiftUI

@main
struct NsdkSamplesApp: App {
    // ARKit availability is enforced in `ARManager.startSession()` (live path only), so the app
    // can also run in playback mode on the simulator / unsupported devices.
    //
    // The scene lives in the shared `RootScene` so this entry point stays a thin shell; the
    // internal build's entry point reuses the same `RootScene` and only adds sample registration.
    var body: some Scene {
        RootScene()
    }
}
