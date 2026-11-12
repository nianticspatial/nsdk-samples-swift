// Copyright 2026 Niantic Spatial.

import Foundation

/// Registry of samples contributed at runtime by the active build.
///
/// Empty by default: the app registers nothing here, so only the built-in samples appear in
/// `MainView`. A build can contribute additional samples by calling `register(_:)` from its entry
/// point before the UI renders, so they show up without `MainView` ever naming them.
final class SampleRegistry {
    static let shared = SampleRegistry()
    private init() {}

    private(set) var entries: [SampleEntry] = []

    /// Called by a build's entry point to contribute its samples. Registration happens once at
    /// app startup, before `MainView` reads `entries`.
    func register(_ entries: [SampleEntry]) {
        self.entries.append(contentsOf: entries)
    }
}
