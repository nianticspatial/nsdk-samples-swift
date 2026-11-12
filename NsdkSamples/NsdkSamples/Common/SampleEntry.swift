// Copyright 2026 Niantic Spatial.

import SwiftUI

/// A sample contributed at runtime by the active build (see `SampleRegistry`).
///
/// This type lives in shared code so `MainView`'s menu/navigation can render it. Entries are added
/// by calling `SampleRegistry.shared.register(_:)` at startup; the default build adds none. Shared
/// code only renders whatever the registry hands back — it never names a concrete sample.
///
/// `makeDestination` returns `AnyView` (not `some View`) because entries are stored in an array; it
/// receives the shared `ARManager` that `ARSessionHost` creates per navigation destination.
struct SampleEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let makeDestination: (ARManager) -> AnyView

    // Identity is the id; the closure does not participate in equality/hashing.
    static func == (lhs: SampleEntry, rhs: SampleEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
