// Copyright 2026 Niantic Spatial.

import CoreLocation
import simd
import UIKit

/// A user-placed marker: a dot on the map and a cube in AR, drawn in the same colour
/// so it is obvious which dot produced which cube.
struct VPS2PlacedMarker: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
    /// The marker's pose in AR space, recomputed each frame. `nil` while VPS2 cannot
    /// resolve one; the map dot still shows.
    var transform: simd_float4x4?
}

/// Colours handed to successive placed markers.
enum VPS2MarkerPalette {
    static let colors: [UIColor] = [
        .systemBlue,
        .systemPurple,
        .systemTeal,
        .systemPink
    ]

    static func color(at index: Int) -> UIColor {
        colors[index % colors.count]
    }
}
