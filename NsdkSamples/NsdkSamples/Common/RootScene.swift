// Copyright 2026 Niantic Spatial.

import SwiftUI

/// Shared app composition root used by every target's `@main` entry point.
///
/// Keeping the scene here means each target's `@main` stays a thin shell that differs only in
/// whether it registers internal samples — all real app-level composition lives in this single
/// shared type.
struct RootScene: Scene {
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
